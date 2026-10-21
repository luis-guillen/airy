import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private let GB: Int64 = 1_000_000_000
private let lsof = "/usr/sbin/lsof"

/// Free space read from a list (the last value repeats).
private final class FakeFreeProbe: FreeSpaceProbing, Sendable {
    private let values: Mutex<[Int64?]>
    init(_ values: [Int64?]) { self.values = Mutex(values) }
    func freeBytes() -> Int64? { values.withLock { v in v.count > 1 ? v.removeFirst() : (v.first ?? nil) } }
}

private final class FakeWrites: DiskWriteSampling, Sendable {
    private let samples: Mutex<[[Int32: (name: String, bytes: UInt64)]]>
    init(_ samples: [[Int32: (name: String, bytes: UInt64)]]) { self.samples = Mutex(samples) }
    func bytesWritten() -> [Int32: (name: String, bytes: UInt64)]? {
        samples.withLock { s in s.count > 1 ? s.removeFirst() : s.first }
    }
}

private struct NamedProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [RunningProcess(pid: 42, name: "Docker", executablePath: nil)] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private let lsofOutput = """
    COMMAND     PID USER   FD   TYPE DEVICE     SIZE/OFF NLINK     NODE NAME
    com.docke    42 ana    12u   REG   1,18  12000000000     0   555 /Users/ana/Library/Containers/x/disk.raw
    com.docke    42 ana    13u   REG   1,18  12000000000     0   555 /Users/ana/Library/Containers/x/disk.raw
    my\\x20tool   77 ana     4w   REG   1,18   3000000000     0   777 /private/var/folders/T/big file.tmp
    linked       90 ana     5r   REG   1,18   9000000000     1   888 /tmp/still-linked
    pipey        91 ana     6u  PIPE  0x123        16384         999 ->0x456
    """

@Suite struct SpaceDropTests {
    @Test func detectorFiresOnceForADropWithinTheWindow() {
        var detector = SpaceDropDetector()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(detector.observe(100 * GB, at: t0) == nil)
        #expect(detector.observe(95 * GB, at: t0.addingTimeInterval(60)) == nil)
        let drop = detector.observe(82 * GB, at: t0.addingTimeInterval(360))
        #expect(drop?.dropped == 18 * GB && drop?.seconds == 360 && drop?.freeBefore == 100 * GB)
        // Cooldown: a further drop right after does not fire again.
        #expect(detector.observe(60 * GB, at: t0.addingTimeInterval(420)) == nil)
    }

    @Test func slowDropsAndSmallDropsDoNotFire() {
        var detector = SpaceDropDetector()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // 12 GB, but over more than 10 minutes (one sample per minute).
        for minute in 0...12 {
            let free = 100 * GB - Int64(minute) * GB
            #expect(detector.observe(free, at: t0.addingTimeInterval(Double(minute) * 60)) == nil)
        }
        var small = SpaceDropDetector()
        #expect(small.observe(50 * GB, at: t0) == nil)
        #expect(small.observe(41 * GB, at: t0.addingTimeInterval(60)) == nil)
    }

    @Test func parsesDeletedOpenFiles() {
        let files = SpaceDropMonitor.parseLsof(lsofOutput, names: [42: "Docker"])
        #expect(files.map(\.pid) == [42, 77])
        #expect(files[0] == DeletedOpenFile(process: "Docker", pid: 42, bytes: 12 * GB,
                                            path: "/Users/ana/Library/Containers/x/disk.raw"))
        #expect(files[1].process == "my tool" && files[1].path == "/private/var/folders/T/big file.tmp")
    }

    @Test func checkTakesOneSnapshotAndStoresIt() async throws {
        let directory = TestTemp.url("space-drop")
        let store = SpaceDropStore(directory: directory)
        let runner = FakeRunner(resolved: ["lsof": lsof],
                                outputs: ["\(lsof) -nP +L1": CommandOutput(status: 0, stdout: lsofOutput, stderr: "")])
        let writes = FakeWrites([[42: ("Docker", 1_000), 7: ("mds", 10)], [42: ("Docker", 9_000), 7: ("mds", 20)]])
        let monitor = SpaceDropMonitor(probe: FakeFreeProbe([100 * GB, 82 * GB, nil]), runner: runner,
                                       processListing: NamedProcesses(), writes: writes, writeWindow: .zero,
                                       store: store)
        let t0 = Date()
        #expect(await monitor.check(now: t0.addingTimeInterval(-360)) == nil)
        let snapshot = try #require(await monitor.check(now: t0))
        #expect(snapshot.droppedBytes == 18 * GB && snapshot.minutes == 6 && snapshot.filesKnown)
        #expect(snapshot.deletedOpenFiles.first?.process == "Docker")
        #expect(snapshot.topWriters.map(\.pid) == [42, 7] && snapshot.topWriters[0].bytesWritten == 8_000)
        #expect(snapshot.message == "Free space dropped 18 GB in 6 min — biggest open deleted file: Docker (12 GB)")
        // Read-only: lsof is the only command run, once, with its time limit.
        #expect(runner.calls.map(\.arguments) == [["-nP", "+L1"]])
        #expect(runner.calls.allSatisfy { $0.timeout <= SpaceDropMonitor.lsofTimeout })
        let stored = try #require(store.load())
        #expect(stored.deletedOpenFiles == snapshot.deletedOpenFiles && stored.droppedBytes == snapshot.droppedBytes)
        #expect(abs(stored.detectedAt.timeIntervalSince(snapshot.detectedAt)) < 1)
        // An unreadable probe never fires.
        #expect(await monitor.check(now: t0.addingTimeInterval(60)) == nil)

        // The MCP summary reports it while it is recent.
        let paths = AppPaths(support: directory, legacySupport: nil)
        let env = AiryEnvironment(
            home: "/Users/ana", paths: paths, catalog: Catalog(entries: []), catalogError: nil,
            settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: directory),
            log: OperationLog(file: paths.operationsFile), runner: FakeRunner(), probes: FakeProbes(),
            processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: FakeOpener(),
            capacity: { nil })
        try env.index.saveScan(ScanResult(root: FileNode(name: "/", isDirectory: true, allocatedSize: 1),
                                          inaccessible: [], duration: 1, scannedAt: Date()))
        let summary = await GetDiskSummaryTool().call([:], context: MCPCallContext(environment: env, client: "test"))
        let drop = try #require(summary.structured?["recent_space_drop"])
        #expect(drop["dropped_bytes"]?.intValue == Int(18 * GB))
        #expect(drop["minutes"]?.intValue == 6)
        #expect(SpaceDropFormat.recent(env, now: t0.addingTimeInterval(2 * 86_400)) == .null)
    }

    @Test func missingOrFailingLsofKeepsTheDropWithoutFiles() async throws {
        let monitor = SpaceDropMonitor(probe: FakeFreeProbe([100 * GB, 80 * GB]), runner: FakeRunner(),
                                       processListing: NamedProcesses(), writes: nil, store: nil)
        let t0 = Date()
        _ = await monitor.check(now: t0)
        let snapshot = try #require(await monitor.check(now: t0.addingTimeInterval(120)))
        #expect(!snapshot.filesKnown && snapshot.deletedOpenFiles.isEmpty && snapshot.topWriters.isEmpty)
        #expect(snapshot.message == "Free space dropped 20 GB in 2 min.")
    }
}
