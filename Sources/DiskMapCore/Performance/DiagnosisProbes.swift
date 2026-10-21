import Foundation

/// Extra readings for the diagnosis. They only read (fixed arguments, with a time limit): they never act on anything.
public struct DiagnosisProbes: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// Running containers (`docker ps -q`, 3 s). Docker missing, time limit exhausted or status ≠ 0 ⇒ nil.
    public func dockerRunningContainers() async -> Int? {
        guard let docker = await runner.resolve("docker"),
              let out = try? await runner.run(docker, ["ps", "-q"], timeout: 3), out.status == 0 else { return nil }
        return out.stdout.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Mounted disk images (`hdiutil info -plist`, 5 s): last component of each `image-path`,
    /// without the system's. Failure or unreadable output ⇒ nil.
    public func mountedDiskImages() async -> [String]? {
        guard let out = try? await runner.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 5),
              out.status == 0 else { return nil }
        return Self.parseImages(out.stdout)
    }

    static func parseImages(_ plist: String) -> [String]? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let images = root["images"] as? [[String: Any]] ?? []
        return images.compactMap { $0["image-path"] as? String }
            .filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/Library/Apple/") }
            .map { ($0 as NSString).lastPathComponent }
            .filter { !$0.isEmpty }
    }
}
