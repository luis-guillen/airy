import Foundation

public enum SpotlightDiagnosis: Sendable, Equatable {
    case fine(seconds: Double), slow(seconds: Double), disabled, unknown
}

/// Measures whether Spotlight responds slowly. Reads only (`mdutil -s`, `mdfind`); the user launches it with a button.
public struct SpotlightCheck: Sendable {
    public static let slowSeconds = 3.0
    static let statusTimeout: TimeInterval = 5
    static let queryTimeout: TimeInterval = 10
    static let query = "kMDItemFSName == 'Applications'"

    private let runner: any CommandRunning
    private let threshold: Double
    private let queryTimeout: TimeInterval

    public init(runner: any CommandRunning) {
        self.init(runner: runner, threshold: Self.slowSeconds, queryTimeout: Self.queryTimeout)
    }

    /// Tests: threshold and time limit scaled down.
    init(runner: any CommandRunning, threshold: Double, queryTimeout: TimeInterval) {
        self.runner = runner; self.threshold = threshold; self.queryTimeout = queryTimeout
    }

    public func run() async -> SpotlightDiagnosis {
        do {
            let status = try await runner.run("/usr/bin/mdutil", ["-s", "/"], timeout: Self.statusTimeout)
            if (status.stdout + status.stderr).lowercased().contains("disabled") { return .disabled }
        } catch {
            return .unknown
        }
        var times: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<2 {
            let start = clock.now
            do {
                _ = try await runner.run("/usr/bin/mdfind", [Self.query], timeout: queryTimeout)
                let elapsed = start.duration(to: clock.now)
                times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            } catch CommandError.timedOut {
                times.append(queryTimeout)
            } catch {
                return .unknown
            }
        }
        let worst = times.max() ?? 0
        return times.allSatisfy({ $0 > threshold }) ? .slow(seconds: worst) : .fine(seconds: worst)
    }
}
