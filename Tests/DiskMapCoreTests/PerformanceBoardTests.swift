import Foundation
import Testing
@testable import DiskMapCore

@Suite struct PerformanceBoardTests {
    let policy = QuitPolicy(currentUID: 501, ownPIDs: [4242])

    func group(_ id: String, name: String? = nil, bundle: String? = nil, kind: AppGroupKind = .app, pid: Int32 = 10,
               memory: Int64 = 1 << 20, cpu: Double? = nil, energy: Double? = nil) -> AppGroup {
        AppGroup(id: id, name: name ?? id, bundleID: bundle, kind: kind, uid: 501, leadPID: pid,
                 leadStart: Date(timeIntervalSince1970: 0), pids: [pid], processNames: [name ?? id],
                 memory: memory, cpuPercent: cpu, energy: energy)
    }

    func snapshot(_ groups: [AppGroup]) -> PerformanceSnapshot {
        let raw = RawSample(date: Date(timeIntervalSince1970: 1_000), uptimeNs: 1, memory: MemoryStats(total: 16 << 30),
                            cores: Array(repeating: CoreTicks(user: 0, system: 0, idle: 0), count: 4),
                            processes: [], apps: [])
        return PerformanceSnapshot(date: raw.date, memory: raw.memory, thermal: ThermalReading(), raw: raw, groups: groups)
    }

    @Test func rowsSortedAndLimited() {
        var groups = (1...15).map { group("app\($0)", pid: Int32($0), memory: Int64($0) << 20) }
        groups.append(group("system:mds", name: "mds", kind: .system, pid: 99, memory: 1 << 34))
        groups.append(group("bg", kind: .background, pid: 98, memory: 100 << 20))
        let board = PerformanceBoard(snapshot: snapshot(groups.shuffled()), policy: policy)
        #expect(board.rows.count == 12)
        #expect(board.rows.first?.id == "bg")
        #expect(Array(board.rows.map(\.id).dropFirst().prefix(3)) == ["app15", "app14", "app13"])
        #expect(!board.rows.contains { $0.group.kind == .system })
        #expect(board.rows.first { $0.id == "bg" }.map(PerformanceBoard.canSelect) == false)
        #expect(PerformanceBoard(snapshot: snapshot(groups), policy: policy, limit: 3).rows.count == 3)
    }

    @Test func neverRowsHaveNoCheckbox() {
        let board = PerformanceBoard(snapshot: snapshot([group("finder-id", name: "Finder", bundle: "com.apple.finder"),
                                                         group("spotify", bundle: "com.spotify.client", pid: 20)]),
                                     policy: policy)
        let finder = board.rows.first { $0.id == "finder-id" }!
        #expect(!PerformanceBoard.canSelect(finder))
        #expect(board.selected(["finder-id"]).isEmpty)
        #expect(board.selected(["finder-id", "spotify"]).map(\.id) == ["spotify"])
    }

    @Test func selectionDropsVanishedRows() {
        let board = PerformanceBoard(snapshot: snapshot([group("a")]), policy: policy)
        #expect(board.selected(["a", "gone"]).map(\.id) == ["a"])
        #expect(PerformanceBoard(snapshot: nil, policy: policy).selected(["a"]).isEmpty)
    }

    @Test func topByCPUSkipsUnknown() {
        let groups = [group("a", cpu: 10, energy: 1), group("b", pid: 11, cpu: nil, energy: 3),
                      group("c", pid: 12, cpu: 50), group("s", kind: .system, pid: 13, cpu: 90)]
        let board = PerformanceBoard(snapshot: snapshot(groups), policy: policy)
        #expect(board.topByCPU.map(\.id) == ["s", "c", "a"])
        #expect(board.topByEnergy.map(\.id) == ["b", "a"])
        let many = (1...8).map { group("g\($0)", pid: Int32($0), cpu: Double($0)) }
        #expect(PerformanceBoard(snapshot: snapshot(many), policy: policy).topByCPU.count == 5)
    }

    @Test func boardResolvesProposalOnlyWithSnapshot() {
        #expect(PerformanceBoard(snapshot: nil, policy: policy).row(matching: "com.spotify.client") == nil)
        let groups = [group("com.spotify.client", name: "Spotify", bundle: "com.spotify.client", memory: 5 << 20),
                      group("pid:1", name: "node", kind: .looseProcess, pid: 30, memory: 1 << 20),
                      group("pid:2", name: "node", kind: .looseProcess, pid: 31, memory: 9 << 20)]
        let board = PerformanceBoard(snapshot: snapshot(groups), policy: policy)
        #expect(board.row(matching: "COM.SPOTIFY.CLIENT")?.id == "com.spotify.client")
        #expect(board.row(matching: "spotify")?.id == "com.spotify.client")
        #expect(board.row(matching: "node")?.id == "pid:2")
        #expect(board.row(matching: "NoExiste") == nil)
    }

    @Test func thermalLevelMapsToProcessInfo() {
        #expect(ThermalLevel.nominal.processInfoState == .nominal)
        #expect(ThermalLevel.fair.processInfoState == .fair)
        #expect(ThermalLevel.serious.processInfoState == .serious)
        #expect(ThermalLevel.critical.processInfoState == .critical)
    }
}
