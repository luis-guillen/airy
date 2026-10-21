import Testing
import Foundation
@testable import DiskMapCore

@Suite struct ScanIntensityTests {
    private func budget(_ intensity: ScanIntensity, cores: Int = 8, lowPower: Bool = false,
                        thermal: ProcessInfo.ThermalState = .nominal) -> ScanBudget {
        ScanBudget.resolve(intensity, performanceCores: cores, lowPowerMode: lowPower, thermalState: thermal)
    }

    @Test func backgroundIsTwoWorkersAtBackgroundQoS() {
        #expect(budget(.background) == ScanBudget(workers: 2, qos: .background))
        #expect(budget(.background, cores: 16) == ScanBudget(workers: 2, qos: .background))
        #expect(budget(.background, lowPower: true, thermal: .critical) == ScanBudget(workers: 2, qos: .background))
    }

    @Test func normalIsAtMostFourWorkersAtUtility() {
        #expect(budget(.normal, cores: 8) == ScanBudget(workers: 4, qos: .utility))
        #expect(budget(.normal, cores: 24) == ScanBudget(workers: 4, qos: .utility))
        #expect(budget(.normal, cores: 3) == ScanBudget(workers: 3, qos: .utility))
        #expect(budget(.normal, cores: 0).workers == 1)
    }

    @Test func normalDropsToTwoOnLowPowerOrHeat() {
        #expect(budget(.normal, lowPower: true) == ScanBudget(workers: 2, qos: .utility))
        #expect(budget(.normal, thermal: .serious).workers == 2)
        #expect(budget(.normal, thermal: .critical).workers == 2)
        #expect(budget(.normal, thermal: .fair).workers == 4)
        #expect(budget(.normal, cores: 1, lowPower: true).workers == 1)
    }

    @Test func currentNeverExceedsTheCap() {
        #expect(ScanBudget.current(.normal).workers <= ScanBudget.maxWorkers)
        #expect(ScanBudget.current(.normal).workers >= 1)
        #expect(ScanBudget.current(.background).workers == 2)
    }

    // MARK: - When to rescan

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshIndexIsNotRescannedAutomatically() {
        let oneHourAgo = now.addingTimeInterval(-3600)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: oneHourAgo, now: now) == .skip)
        let almostSix = now.addingTimeInterval(-(6 * 3600 - 1))
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: almostSix, now: now) == .skip)
    }

    @Test func staleOrUndatedIndexRescansInBackground() {
        let sixHoursAgo = now.addingTimeInterval(-6 * 3600)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: sixHoursAgo, now: now) == .scan(.background))
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: nil, now: now) == .scan(.background))
        let future = now.addingTimeInterval(3600)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: future, now: now) == .scan(.background))
    }

    @Test func noIndexScansAtNormalIntensity() {
        #expect(ScanSchedule.plan(.automatic, hasIndex: false, indexDate: nil, now: now) == .scan(.normal))
    }

    @Test func settingsDecideTheAutomaticRescan() {
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        // 1 h: a two-hour-old index is rescanned; 24 h: it isn't.
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: twoHoursAgo, now: now,
                                  maxAge: RescanAge.oneHour.interval) == .scan(.background))
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: twoHoursAgo, now: now,
                                  maxAge: RescanAge.oneDay.interval) == .skip)
        // "Never" and the switch off: a saved index is never rescanned by itself, not even an undated one.
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: old, now: now, maxAge: nil) == .skip)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: nil, now: now, autoRescan: false) == .skip)
        // Without an index there is nothing to show: Airy still scans. User and agent scans are unaffected.
        #expect(ScanSchedule.plan(.automatic, hasIndex: false, indexDate: nil, now: now, autoRescan: false) == .scan(.normal))
        #expect(ScanSchedule.plan(.user, hasIndex: true, indexDate: now, now: now, autoRescan: false) == .scan(.normal))
        #expect(ScanSchedule.plan(.agent, hasIndex: true, indexDate: now, now: now, maxAge: nil) == .scan(.background))
    }

    @Test func userAndAgentAlwaysScan() {
        let fresh = now.addingTimeInterval(-60)
        #expect(ScanSchedule.plan(.user, hasIndex: true, indexDate: fresh, now: now) == .scan(.normal))
        #expect(ScanSchedule.plan(.user, hasIndex: false, indexDate: nil, now: now) == .scan(.normal))
        #expect(ScanSchedule.plan(.agent, hasIndex: true, indexDate: fresh, now: now) == .scan(.background))
        #expect(ScanSchedule.plan(.agent, hasIndex: false, indexDate: nil, now: now) == .scan(.background))
    }

    // MARK: - AIRY_SCAN_ROOTS

    #if DEBUG
    @Test func scanRootsOverrideParsesColonSeparatedPaths() {
        let home = NSHomeDirectory()
        let roots = ScanRootsOverride.roots(from: ["AIRY_SCAN_ROOTS": "/tmp/a: ~/Library ::/usr/share/"])
        #expect(roots?.map(\.path) == ["/tmp/a", home + "/Library", "/usr/share"])
    }

    @Test func scanRootsOverrideAbsentOrEmptyMeansWholeDisk() {
        #expect(ScanRootsOverride.roots(from: [:]) == nil)
        #expect(ScanRootsOverride.roots(from: ["AIRY_SCAN_ROOTS": ""]) == nil)
        #expect(ScanRootsOverride.roots(from: ["AIRY_SCAN_ROOTS": " : "]) == nil)
    }

    @Test func scanRootsOverrideSavesOnlyToATempSupportDir() {
        #expect(ScanRootsOverride.allowsSaving(environment: [:]))
        #expect(ScanRootsOverride.allowsSaving(environment: ["AIRY_SUPPORT_DIR": "/tmp/s"]))
        #expect(!ScanRootsOverride.allowsSaving(environment: ["AIRY_SCAN_ROOTS": "/tmp/a"]))
        #expect(!ScanRootsOverride.allowsSaving(environment: ["AIRY_SCAN_ROOTS": "/tmp/a", "AIRY_SUPPORT_DIR": ""]))
        #expect(ScanRootsOverride.allowsSaving(environment: ["AIRY_SCAN_ROOTS": "/tmp/a", "AIRY_SUPPORT_DIR": "/tmp/s"]))
    }
    #endif
}
