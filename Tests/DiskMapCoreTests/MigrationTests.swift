import Foundation
import Testing
@testable import DiskMapCore

@Suite struct MigrationTests {
    private func makeRoot() -> URL {
        TestTemp.url("airy-migration")
    }

    private func makePaths(_ root: URL, withLegacy: Bool = true) throws -> (AppPaths, Data) {
        let paths = AppPaths(support: root.appendingPathComponent("Airy"), legacySupport: root.appendingPathComponent("DiskMap"))
        let history = Data("[1,2,3]".utf8)
        if withLegacy, let legacy = paths.legacySupport {
            let vol = legacy.appendingPathComponent("Volumes/_Volumes_X")
            try FileManager.default.createDirectory(at: vol, withIntermediateDirectories: true)
            try Data("plist".utf8).write(to: legacy.appendingPathComponent("scan.plist"))
            try history.write(to: legacy.appendingPathComponent("history.json"))
            try Data("vol".utf8).write(to: vol.appendingPathComponent("scan.plist"))
            try Data("x".utf8).write(to: legacy.appendingPathComponent(".DS_Store"))
        }
        return (paths, history)
    }

    /// Relative path → (bytes, mtime) of everything under `dir`.
    private func snapshot(_ dir: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for case let url as URL in try #require(fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let rel = String(url.path.dropFirst(dir.path.count))
            let bytes = values.isDirectory == true ? "dir" : (try Data(contentsOf: url)).base64EncodedString()
            result[rel] = "\(bytes)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
        return result
    }

    @Test func copiesIndexHistoryAndVolumesLeavingLegacyIntact() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, history) = try makePaths(root)
        let legacy = try #require(paths.legacySupport)
        let before = try snapshot(legacy)
        let r = DataMigration.migrateIfNeeded(paths)
        #expect(r == .migrated(copied: ["Volumes", "history.json", "scan.plist"]))
        #expect(try Data(contentsOf: paths.support.appendingPathComponent("history.json")) == history)
        #expect(FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("Volumes/_Volumes_X/scan.plist").path))
        #expect(!FileManager.default.fileExists(atPath: paths.support.appendingPathComponent(".DS_Store").path))
        #expect(try snapshot(legacy) == before)
        #expect(FileManager.default.fileExists(atPath: paths.migrationMarker.path))
    }

    @Test func doesNotOverwriteExistingAiryData() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, _) = try makePaths(root)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let existing = Data("mine".utf8)
        try existing.write(to: paths.support.appendingPathComponent("history.json"))
        let r = DataMigration.migrateIfNeeded(paths)
        #expect(r == .migrated(copied: ["Volumes", "scan.plist"]))
        #expect(try Data(contentsOf: paths.support.appendingPathComponent("history.json")) == existing)
    }

    @Test func secondRunIsNoOp() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, _) = try makePaths(root)
        _ = DataMigration.migrateIfNeeded(paths)
        #expect(DataMigration.migrateIfNeeded(paths) == .notNeeded)
    }

    @Test func noLegacyFolderWritesMarker() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, _) = try makePaths(root, withLegacy: false)
        #expect(DataMigration.migrateIfNeeded(paths) == .notNeeded)
        #expect(FileManager.default.fileExists(atPath: paths.migrationMarker.path))
    }

    @Test func interruptedMigrationResumes() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, _) = try makePaths(root)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let partial = paths.support.appendingPathComponent(".scan.plist.partial-ABC")
        try Data("half".utf8).write(to: partial)
        let r = DataMigration.migrateIfNeeded(paths)
        #expect(r == .migrated(copied: ["Volumes", "history.json", "scan.plist"]))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: paths.support.appendingPathComponent("scan.plist")) == Data("plist".utf8))
    }

    @Test func concurrentMigrationsCopyOnce() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, history) = try makePaths(root)
        async let a = Task.detached { DataMigration.migrateIfNeeded(paths) }.value
        async let b = Task.detached { DataMigration.migrateIfNeeded(paths) }.value
        let results = await [a, b]
        #expect(results.filter { if case .migrated = $0 { true } else { false } }.count == 1)
        #expect(results.filter { $0 == .notNeeded }.count == 1)
        #expect(try Data(contentsOf: paths.support.appendingPathComponent("history.json")) == history)
    }

    @Test func defaultsMigrationCopiesOnlyMissingKeys() throws {
        let legacyName = TestTemp.defaultsSuiteName("legacy"), currentName = TestTemp.defaultsSuiteName("current")
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let current = try #require(UserDefaults(suiteName: currentName))
        legacy.set("/old/claude", forKey: "claudePath")
        legacy.set("/old/other", forKey: "other")
        #expect(DataMigration.migrateDefaults(from: legacy, to: current, keys: ["claudePath", "absent"]) == ["claudePath"])
        #expect(current.string(forKey: "claudePath") == "/old/claude")
        current.set("/new/claude", forKey: "claudePath")
        #expect(DataMigration.migrateDefaults(from: legacy, to: current, keys: ["claudePath"]) == [])
        #expect(current.string(forKey: "claudePath") == "/new/claude")
        #expect(DataMigration.migrateDefaults(from: nil, to: current, keys: ["claudePath"]) == [])
    }
}
