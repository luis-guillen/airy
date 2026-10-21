import Testing
import Foundation
@testable import DiskMapCore

private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func repoPlist(_ relative: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent(relative))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

/// Files under `under` with some string literal matching `pattern` (line comments and the files in
/// `allow` are ignored). Returns "file:line".
private func stringLiteralHits(pattern: Regex<Substring>, under: String, allow: Set<String>) throws -> [String] {
    let literal = #/"(?:[^"\\]|\\.)*"/#
    var hits: [String] = []
    let root = repoRoot.appendingPathComponent(under)
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in files where url.pathExtension == "swift" && !allow.contains(url.lastPathComponent) {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            for match in line.matches(of: literal) where match.output.contains(pattern) {
                hits.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
    }
    return hits.sorted()
}

@Suite struct IdentityTests {
    @Test func resourceBundleNameIsAirys() { #expect(Catalog.bundleName == "Airy_DiskMapCore.bundle") }

    @Test func infoPlistHasAiryIdentity() throws {
        let plist = try repoPlist("Resources/Info.plist")
        #expect(plist["CFBundleIdentifier"] as? String == "local.airy.Airy")
        #expect(plist["CFBundleExecutable"] as? String == "Airy")
        let types = plist["CFBundleURLTypes"] as? [[String: Any]]
        #expect(types?.first?["CFBundleURLSchemes"] as? [String] == ["airy"])
    }

    /// No string literal in Sources/ contains "DiskMap" (except "DiskMapCore") or "DISKMAP_",
    /// except Persistence/AppPaths.swift and Persistence/DataMigration.swift (legacy, Task 2).
    @Test func noDiskMapLeftInStringLiterals() throws {
        #expect(try stringLiteralHits(pattern: #/DiskMap(?!Core)|DISKMAP_/#, under: "Sources",
                                      allow: ["AppPaths.swift", "DataMigration.swift"]) == [])
    }
}
