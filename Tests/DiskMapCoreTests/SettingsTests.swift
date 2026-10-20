import Foundation
import Testing
@testable import DiskMapCore

@Suite struct SettingsTests {
    let h = "/Users/test"

    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("airy-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func defaultsAreAggressiveAgentsOnEmptyLists() {
        let s = AirySettings.defaults
        #expect(s.mode == .aggressive && s.agentsEnabled && s.profiles.isEmpty && s.protectedPaths.isEmpty)
    }

    @Test func missingFileAllowsAgentsWithDefaults() {
        let load = SettingsStore(file: tempFile()).load()
        #expect(load == .missing)
        #expect(load.allowsAgentActions && load.effective == .defaults)
    }

    @Test func roundTripsAndFillsMissingKeys() throws {
        let file = tempFile()
        try write(#"{"version":1}"#, to: file)
        let store = SettingsStore(file: file)
        #expect(store.load() == .loaded(.defaults))
        var s = AirySettings.defaults
        s.mode = .prudent
        s.profiles = [.developer, .music]
        s.agentsEnabled = false
        let added = s.protect("~/Models/*.gguf", home: h)
        #expect(added)
        try store.save(s)
        #expect(store.load() == .loaded(s))
        #expect(!store.load().allowsAgentActions)
    }

    @Test func saveCreatesFolderAndSortsKeys() throws {
        let file = tempFile()
        try SettingsStore(file: file).save(.defaults)
        let text = try String(contentsOf: file, encoding: .utf8)
        let keys = ["agentsEnabled", "mode", "profiles", "protectedPaths", "version"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == keys.count && positions == positions.sorted())
    }

    @Test func corruptSettingsDisallowAgents() throws {
        let file = tempFile()
        try write("{no json", to: file)
        let load = SettingsStore(file: file).load()
        guard case .unreadable = load else { Issue.record("expected unreadable"); return }
        #expect(load.allowsAgentActions == false)
        #expect(load.effective.agentsEnabled == false)
    }

    @Test func futureVersionIsUnreadable() throws {
        let file = tempFile()
        try write(#"{"version":2}"#, to: file)
        guard case .unreadable = SettingsStore(file: file).load() else { Issue.record("expected unreadable"); return }
    }

    @Test func unknownProfileIgnoredUnknownModeUnreadable() throws {
        let file = tempFile()
        try write(#"{"version":1,"profiles":["developer","time-traveller"]}"#, to: file)
        let store = SettingsStore(file: file)
        guard case .loaded(let s) = store.load() else { Issue.record("expected loaded"); return }
        #expect(s.profiles == [.developer])
        try write(#"{"version":1,"mode":"reckless"}"#, to: file)
        guard case .unreadable = store.load() else { Issue.record("expected unreadable"); return }
    }

    @Test func resetUnreadableKeepsBadFileAside() throws {
        let file = tempFile()
        try write("{no json", to: file)
        let store = SettingsStore(file: file)
        let fresh = try store.resetUnreadable()
        #expect(fresh == .defaults && store.load() == .loaded(.defaults))
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.unreadable-") && $0.hasSuffix(".json") }
        #expect(aside.count == 1)
        let kept = try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(aside[0]))
        #expect(kept == Data("{no json".utf8))
    }

    @Test func normaliseRules() {
        #expect(ProtectList.normalise(" ~/Library/Caches/foo/ ", home: h) == "~/Library/Caches/foo")
        #expect(ProtectList.normalise(h + "//a///b/", home: h) == "~/a/b")
        #expect(ProtectList.normalise("/opt//x/", home: h) == "/opt/x")
        #expect(ProtectList.normalise("relativa/x", home: h) == nil)
        #expect(ProtectList.normalise("/a/../b", home: h) == nil)
        #expect(ProtectList.normalise("/a/./b", home: h) == nil)
        #expect(ProtectList.normalise("/a\u{7}b", home: h) == nil)
        #expect(ProtectList.normalise("   ", home: h) == nil)
    }

    @Test func matchInsideAncestorCaseAndWildcard() {
        let list = ProtectList(patterns: ["~/Library/Caches/Foo", "~/Models/*.gguf"], home: h)
        #expect(list.match(h + "/library/caches/foo/x") == "~/Library/Caches/Foo")
        #expect(list.match(h + "/Library/Caches") == "~/Library/Caches/Foo")
        #expect(list.match(h + "/Models/llama.gguf") != nil)
        #expect(list.match(h + "/Library/Caches/Bar") == nil)
        #expect(list.match(h + "/Library/Caches/FooBar") == nil)
    }

    @Test func onlyStarIsAWildcard() {
        let list = ProtectList(patterns: ["~/Photos [2024]", "~/a?b", "~/c\\d"], home: h)
        #expect(list.match(h + "/photos [2024]/x") == "~/Photos [2024]")
        #expect(list.match(h + "/Photos 2") == nil)
        #expect(list.match(h + "/a?b") != nil)
        #expect(list.match(h + "/axb") == nil)
        #expect(list.match(h + "/c\\d") != nil)
    }

    @Test func protectDeduplicates() {
        var s = AirySettings.defaults
        let first = s.protect("~/Work/", home: h)
        let again = s.protect("~/work", home: h)
        let invalid = s.protect("nope", home: h)
        #expect(first && !again && !invalid)
        #expect(s.protectedPaths == ["~/Work"])
        s.unprotect("~/Work")
        #expect(s.protectedPaths.isEmpty)
    }
}
