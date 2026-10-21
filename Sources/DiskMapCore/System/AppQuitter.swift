import AppKit
import Foundation

public enum QuitResult: Sendable, Equatable { case notRunning, quit, stillRunning, unknown }

/// Quits apps normally before uninstalling them. It never force-quits.
public protocol AppQuitting: Sendable {
    /// `nil` = unknown.
    func isRunning(bundleID: String) -> Bool?
    /// Normal quit (like "Quit"): the app may ask to save. It never force-quits.
    func quit(bundleID: String, timeout: Duration) async -> QuitResult
}

/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` and `terminate()`.
public struct WorkspaceQuitter: AppQuitting {
    public init() {}

    public func isRunning(bundleID: String) -> Bool? {
        guard !bundleID.isEmpty else { return nil }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func quit(bundleID: String, timeout: Duration) async -> QuitResult {
        guard !bundleID.isEmpty else { return .unknown }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return .notRunning }
        for app in apps where !app.isTerminated { _ = app.terminate() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if apps.allSatisfy(\.isTerminated) { return .quit }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return .unknown }
        }
        return apps.allSatisfy(\.isTerminated) ? .quit : .stillRunning
    }
}
