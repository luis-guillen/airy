import Testing
import Foundation
@testable import DiskMapCore

@Suite struct ScanIntensityTests {
    private func budget(_ intensity: ScanIntensity, cores: Int = 8, lowPower: Bool = false,
                        thermal: ProcessInfo.ThermalState = .nominal) -> ScanBudget {
        ScanBudget.resolve(intensity, performanceCores: cores, lowPowerMode: lowPower, thermalState: thermal)
    }

    @Test func backgroundIsTwoUtilityWorkers() {
        #expect(budget(.background) == ScanBudget(workers: 2, qos: .utility))
        #expect(budget(.background, cores: 16) == ScanBudget(workers: 2, qos: .utility))
        #expect(budget(.background, lowPower: true, thermal: .critical) == ScanBudget(workers: 2, qos: .utility))
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

    // MARK: - Cuándo reanalizar

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
    #endif
}
