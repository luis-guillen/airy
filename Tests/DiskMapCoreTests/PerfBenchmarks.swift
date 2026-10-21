import Foundation
import Testing
@testable import DiskMapCore

/// Opt-in benchmarks over a big synthetic tree. They never run in the normal suite: set `AIRY_BENCH_ROOT` to a
/// generated folder (never the real disk) and run them on their own, ideally in release:
///
///     AIRY_BENCH_ROOT=/tmp/tree swift test -c release -Xswiftc -enable-testing --filter PerfBenchmarks
///
/// Each line printed starts with `BENCH` so it can be grepped out of the test log.
private let benchRoot = ProcessInfo.processInfo.environment["AIRY_BENCH_ROOT"]

@Suite(.serialized, .enabled(if: benchRoot != nil))
struct PerfBenchmarks {
    static var root: String? { benchRoot }
    /// Extra passes for profiling (`AIRY_BENCH_REPEAT`).
    static var repeats: Int { Int(ProcessInfo.processInfo.environment["AIRY_BENCH_REPEAT"] ?? "") ?? 3 }
    static var filter: String { ProcessInfo.processInfo.environment["AIRY_BENCH_ONLY"] ?? "" }

    // MARK: Measuring helpers

    struct Sample {
        var wall: Double
        var cpu: Double
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    /// Physical footprint now (what Activity Monitor shows as "Memory").
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Bytes allocated with `malloc` and still alive (all zones).
    static func liveHeapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    static func measure<T>(_ body: () async throws -> T) async rethrows -> (T, Sample) {
        let cpu0 = cpuSeconds()
        let t0 = ContinuousClock.now
        let value = try await body()
        let elapsed = ContinuousClock.now - t0
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (value, Sample(wall: wall, cpu: cpuSeconds() - cpu0))
    }

    static func log(_ line: String) {
        print("BENCH " + line)
        fflush(stdout)
    }

    static func scan(_ budget: ScanBudget, prune: Int64 = 1_048_576) async throws -> ScanResult {
        let options = ScanOptions(roots: [URL(fileURLWithPath: CleanupTargets.realPath(root!)!)], excludedPrefixes: [], pruneThreshold: prune)
        return try await DiskScanner(options: options, budget: budget).scan { _ in }
    }

    static func nodeCount(_ node: FileNode) -> Int {
        var count = 0
        var stack = [node]
        while let next = stack.popLast() {
            count += 1
            stack.append(contentsOf: next.children)
        }
        return count
    }

    static func busiestFolder(_ root: FileNode) -> FileNode {
        var best = root
        var stack = [root]
        while let node = stack.popLast() {
            if node.isDirectory, node.children.count > best.children.count { best = node }
            stack.append(contentsOf: node.children.filter(\.isDirectory))
        }
        return best
    }

    static func enabled(_ name: String) -> Bool { filter.isEmpty || filter.split(separator: ",").contains { name.hasPrefix($0) } }

    // MARK: Scanner

    @Test func scanUserPath() async throws {
        guard Self.enabled("scanUser") else { return }
        // Warm the metadata cache once, so every run reads the same way.
        _ = try await Self.scan(ScanBudget(workers: 4, qos: .utility))
        var walls: [Double] = [], cpus: [Double] = []
        var nodes = 0, files = 0
        for _ in 0..<3 {
            let (result, sample) = try await Self.measure { try await Self.scan(ScanBudget(workers: 4, qos: .utility)) }
            walls.append(sample.wall); cpus.append(sample.cpu)
            nodes = Self.nodeCount(result.root); files = result.root.descendantCount
        }
        Self.log(String(format: "scan.user workers=4 qos=utility wall_min=%.3fs wall_med=%.3fs cpu_med=%.3fs nodes=%d items=%d peakRSS=%.1fMB footprint=%.1fMB",
                        walls.min()!, walls.sorted()[1], cpus.sorted()[1], nodes, files, Self.peakRSSMB(), Self.footprintMB()))
    }

    @Test func scanAutomaticPath() async throws {
        guard Self.enabled("scanAuto") else { return }
        _ = try await Self.scan(ScanBudget(workers: 2, qos: .background))
        var walls: [Double] = [], cpus: [Double] = []
        for _ in 0..<3 {
            let (_, sample) = try await Self.measure { try await Self.scan(ScanBudget(workers: 2, qos: .background)) }
            walls.append(sample.wall); cpus.append(sample.cpu)
        }
        Self.log(String(format: "scan.automatic workers=2 qos=background wall_min=%.3fs wall_med=%.3fs cpu_med=%.3fs peakRSS=%.1fMB",
                        walls.min()!, walls.sorted()[1], cpus.sorted()[1], Self.peakRSSMB()))
    }

    /// The bulk reader and `readdir` + `fstatat` describe the synthetic tree identically.
    @Test func scanReadersAgree() async throws {
        guard Self.enabled("scanReaders") else { return }
        for prune in [Int64(1_048_576), 0] {
            var options = ScanOptions(roots: [URL(fileURLWithPath: CleanupTargets.realPath(Self.root!)!)],
                                      excludedPrefixes: [], pruneThreshold: prune)
            let bulk = try await DiskScanner(options: options, budget: ScanBudget(workers: 4, qos: .utility)).scan { _ in }
            options.usesBulkReader = false
            let (legacy, sample) = try await Self.measure {
                try await DiskScanner(options: options, budget: ScanBudget(workers: 4, qos: .utility)).scan { _ in }
            }
            let same = canonicalDump(bulk.root) == canonicalDump(legacy.root)
            #expect(same)
            Self.log(String(format: "scan.readers prune=%lld identical=%@ legacy_wall=%.3fs legacy_cpu=%.3fs", prune,
                            same ? "yes" : "NO", sample.wall, sample.cpu))
        }
    }

    /// Without pruning every file is a node: the worst case for allocations and for the index.
    @Test func scanUnpruned() async throws {
        guard Self.enabled("scanUnpruned") else { return }
        _ = try await Self.scan(ScanBudget(workers: 4, qos: .utility), prune: 0)
        let before = Self.liveHeapBytes()
        let (result, sample) = try await Self.measure { try await Self.scan(ScanBudget(workers: 4, qos: .utility), prune: 0) }
        let after = Self.liveHeapBytes()
        let nodes = Self.nodeCount(result.root)
        Self.log(String(format: "scan.unpruned wall=%.3fs cpu=%.3fs nodes=%d tree_heap=%.1fMB (%.0f B/node) peakRSS=%.1fMB",
                        sample.wall, sample.cpu, nodes, Double(after - before) / 1_048_576,
                        Double(after - before) / Double(nodes), Self.peakRSSMB()))
    }

    // MARK: Index

    @Test func indexSaveLoad() async throws {
        guard Self.enabled("index") else { return }
        for prune in [Int64(1_048_576), 0] {
            let result = try await Self.scan(ScanBudget(workers: 4, qos: .utility), prune: prune)
            let directory = URL(fileURLWithPath: TestTemp.directory("bench-index"))
            let store = IndexStore(directory: directory)
            var saves: [Double] = [], loads: [Double] = []
            try store.saveScan(result)
            let heapBefore = Self.liveHeapBytes()
            let kept = try store.loadScan()
            let loadedHeap = Self.liveHeapBytes() - heapBefore
            withExtendedLifetime(kept) {}
            for _ in 0..<5 {
                let (_, save) = try await Self.measure { try store.saveScan(result) }
                let (loaded, load) = try await Self.measure { try store.loadScan() }
                #expect(loaded?.root.descendantCount == result.root.descendantCount)
                saves.append(save.wall); loads.append(load.wall)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("scan.plist").path)[.size] as? Int) ?? 0
            Self.log(String(format: "index prune=%lld nodes=%d save_med=%.1fms load_med=%.1fms size=%.2fMB loaded_tree_heap=%.1fMB",
                            prune, Self.nodeCount(result.root), saves.sorted()[2] * 1000, loads.sorted()[2] * 1000,
                            Double(size) / 1_048_576, Double(loadedHeap) / 1_048_576))
        }
    }

    // MARK: Treemap

    @Test func treemapLayout() async throws {
        guard Self.enabled("treemap") else { return }
        let result = try await Self.scan(ScanBudget(workers: 4, qos: .utility), prune: 0)
        let busiest = Self.busiestFolder(result.root)
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        for (label, node) in [("root", result.root), ("busiest", busiest)] {
            let snapshot = Treemap.Snapshot(of: node)
            var times: [Double] = []
            var tiles = 0
            for _ in 0..<50 {
                let (made, sample) = await Self.measure { () -> Int in
                    let tiles = Treemap.tiles(for: snapshot, in: bounds)
                    let rects = tiles.map(\.rect)
                    _ = TileHitIndex(rects: rects, bounds: bounds)
                    _ = EntranceOrder.ranks(for: rects, in: bounds)
                    return tiles.count
                }
                times.append(sample.wall); tiles = made
            }
            Self.log(String(format: "treemap %@ children=%d tiles=%d layout_med=%.3fms",
                            label, node.children.count, tiles, times.sorted()[25] * 1000))
        }
        // Raw squarify on 100k values (complexity check).
        let values = (0..<100_000).map { Double(100_000 - $0) }
        let (_, sample) = await Self.measure { Treemap.squarify(values: values, in: bounds) }
        Self.log(String(format: "treemap squarify n=100000 %.2fms", sample.wall * 1000))
    }

    // MARK: Detection

    @Test func detectionPass() async throws {
        guard Self.enabled("detection") else { return }
        let home = CleanupTargets.realPath(Self.root!)!
        let result = try await Self.scan(ScanBudget(workers: 4, qos: .utility))
        let catalog = try Catalog.bundled()
        var settings = AirySettings()
        settings.mode = .aggressive
        let scanner = CleanupScanner(
            catalog: catalog, runner: FakeRunner(resolved: [:]), probes: FakeProbes(),
            references: ReferenceChecker(roots: []), home: home,
            classifier: RiskClassifier(catalog: catalog, settings: settings, home: home),
            processListing: BenchNoProcesses(), scope: DiskScope(roots: [home]))
        var times: [Double] = [], cpus: [Double] = []
        var count = 0
        for _ in 0..<max(3, Self.repeats) {
            let (items, sample) = await Self.measure { await scanner.findItems(scan: result.root) }
            times.append(sample.wall); cpus.append(sample.cpu); count = items.count
        }
        Self.log(String(format: "detection items=%d wall_med=%.1fms cpu_med=%.1fms", count,
                        times.sorted()[1] * 1000, cpus.sorted()[1] * 1000))
    }

    // MARK: Duplicates

    @Test func duplicates() async throws {
        guard Self.enabled("duplicates") else { return }
        let home = CleanupTargets.realPath(Self.root!)!
        let result = try await Self.scan(ScanBudget(workers: 4, qos: .utility))
        let catalog = Catalog(entries: [])
        let settings = AirySettings()
        let finder = DuplicateFinder(
            home: home, classifier: RiskClassifier(catalog: catalog, settings: settings, home: home),
            gate: PathGate(home: home, catalog: catalog, userProtected: ProtectList(patterns: [], home: home)))
        let search = DuplicateSearch(roots: [home])
        let candidates = DuplicateFinder.candidates(in: result.root, search: search)
        let (found, sample) = await Self.measure { await finder.find(search, candidates: candidates) }
        let bytes = found.groups.reduce(Int64(0)) { $0 + $1.size * Int64($1.copies.count) }
        Self.log(String(format: "duplicates candidates=%d groups=%d examined=%d wall=%.3fs cpu=%.3fs fully_hashed=%.1fMB throughput=%.0fMB/s",
                        candidates.count, found.groups.count, found.filesExamined, sample.wall, sample.cpu,
                        Double(bytes) / 1_048_576, Double(bytes) / 1_048_576 / sample.wall))
    }
}

private struct BenchNoProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}
