import Foundation
import Testing
@testable import DiskMapCore

@Suite struct SettingsTests {
    let h = "/Users/test"

    func tempFile() -> URL {
        TestTemp.url("airy-settings")
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

    @Test func newPreferencesDefaultToTodaysBehaviour() {
        let s = AirySettings.defaults
        #expect(s.language == .system && s.motion == .system)
        #expect(s.autoRescanOnLaunch && s.rescanAge == .sixHours && s.rescanAge.interval == ScanSchedule.freshness)
        #expect(s.defaultVolume == nil && s.excludedPaths.isEmpty && s.aiEnabled)
    }

    @Test func decodesASettingsFileFromBeforeThePreferences() throws {
        let file = tempFile()
        // What Airy 0.2 wrote: no language, motion, scanning or AI keys.
        try write(#"{"agentsEnabled":false,"mode":"prudent","profiles":["developer"],"protectedPaths":["~/Work"],"version":1}"#, to: file)
        guard case .loaded(let s) = SettingsStore(file: file).load() else { Issue.record("expected loaded"); return }
        var expected = AirySettings.defaults
        expected.mode = .prudent
        expected.agentsEnabled = false
        expected.profiles = [.developer]
        expected.protectedPaths = ["~/Work"]
        #expect(s == expected)
        #expect(s.language == .system && s.autoRescanOnLaunch && s.rescanAge == .sixHours && s.aiEnabled)
    }

    @Test func roundTripsTheNewPreferences() throws {
        let file = tempFile()
        let store = SettingsStore(file: file)
        var s = AirySettings.defaults
        s.language = .es
        s.motion = .reduced
        s.autoRescanOnLaunch = false
        s.rescanAge = .oneDay
        s.defaultVolume = "/Volumes/Work"
        s.excludedPaths = ["/Users/test/Movies"]
        s.aiEnabled = false
        try store.save(s)
        #expect(store.load() == .loaded(s))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#""rescanAge" : "24h""#) && text.contains(#""language" : "es""#))
        // No default volume: the key is left out, and reading it back gives the startup disk again.
        s.defaultVolume = nil
        try store.save(s)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("defaultVolume"))
        #expect(store.load() == .loaded(s))
    }

    @Test func unknownPreferenceValuesFallBackButWrongTypesAreUnreadable() throws {
        let file = tempFile()
        let store = SettingsStore(file: file)
        try write(#"{"version":1,"language":"tlh","motion":"warp","rescanAge":"5m","defaultVolume":""}"#, to: file)
        #expect(store.load() == .loaded(.defaults))
        // A wrong type is a damaged file, like any other key: fail closed.
        try write(#"{"version":1,"aiEnabled":"yes"}"#, to: file)
        guard case .unreadable = store.load() else { Issue.record("expected unreadable"); return }
        try write(#"{"version":1,"excludedPaths":"/Users/test"}"#, to: file)
        guard case .unreadable = store.load() else { Issue.record("expected unreadable"); return }
        #expect(!store.load().allowsAgentActions && store.load().effective.agentsEnabled == false)
    }

    @Test func resettingPreferencesKeepsTheProtectList() {
        var s = AirySettings.defaults
        s.mode = .prudent
        s.agentsEnabled = false
        s.language = .es
        s.aiEnabled = false
        s.excludedPaths = ["/Users/test/Movies"]
        s.protectedPaths = ["~/Work"]
        var expected = AirySettings.defaults
        expected.protectedPaths = ["~/Work"]
        #expect(s.resettingPreferences() == expected)
    }

    @Test func motionPreferenceDecidesReduceMotion() {
        #expect(MotionPreference.system.reducesMotion(systemReduceMotion: true))
        #expect(!MotionPreference.system.reducesMotion(systemReduceMotion: false))
        #expect(MotionPreference.reduced.reducesMotion(systemReduceMotion: false))
        #expect(!MotionPreference.full.reducesMotion(systemReduceMotion: true))
        #expect(AppLanguage.system.code == nil && AppLanguage.es.code == "es")
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
        // Nothing salvageable: empty list and agents off (fail closed).
        var expected = AirySettings.defaults
        expected.agentsEnabled = false
        #expect(fresh.settings == expected && store.load() == .loaded(expected))
        #expect(fresh.salvage.recoveredProtectedPaths == false)
        #expect(fresh.message.contains("Your “Protect this” list could not be recovered"))
        #expect(fresh.message.contains("Agents stay disabled"))
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

    // MARK: Settings in the app

    @Test func unreadableSettingsBlockDestructiveActionsUntilReset() throws {
        let file = tempFile()
        try write("{ not json", to: file)
        var session = SettingsSession(store: SettingsStore(file: file))
        #expect(session.load.isUnreadable)
        #expect(session.destructiveRefusal != nil)
        #expect(session.unreadableNotice
                == "The settings could not be read (settings.json is not valid). Agents cannot clean until you reset them.")
        // With the file unreadable nothing is saved on top: the user decides with "Reset settings".
        #expect(throws: SettingsSession.Unreadable.self) { _ = try session.update { $0.mode = .prudent } }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        #expect(session.resetConfirmation()?.contains("cannot be recovered") == true)
        try session.reset()
        var expected = AirySettings.defaults
        expected.agentsEnabled = false
        #expect(session.load == .loaded(expected))
        #expect(session.destructiveRefusal == nil && session.unreadableNotice == nil)
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.unreadable-") }
        #expect(aside.count == 1)
    }

    @Test func resetKeepsProtectionsFromANewerVersionAndLeavesAgentsAsTheyWere() throws {
        let file = tempFile()
        // A newer Airy wrote version 2: it is not loaded, but its list and the switch are salvaged.
        try write(#"{"version":2,"mode":"prudent","agentsEnabled":false,"protectedPaths":["~/Work","~/Models/*.gguf"],"newThing":{"x":1}}"#, to: file)
        var session = SettingsSession(store: SettingsStore(file: file))
        #expect(session.load.isUnreadable)
        let maybeConfirmation = session.resetConfirmation()
        let confirmation = try #require(maybeConfirmation)
        #expect(confirmation.contains("Your “Protect this” list will be kept (2 paths)"))
        #expect(confirmation.contains("Agents will be disabled"))
        let maybeResult = try session.reset()
        let result = try #require(maybeResult)
        #expect(result.settings.protectedPaths == ["~/Work", "~/Models/*.gguf"])
        #expect(result.settings.agentsEnabled == false && result.settings.mode == .prudent)
        #expect(result.message.contains("Your “Protect this” list was kept (2 paths)"))
        #expect(result.backup.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(SettingsStore(file: file).load() == .loaded(result.settings))
    }

    @Test func resetSalvagesAgentsOnOnlyWithTheProtectList() throws {
        let file = tempFile()
        try write(#"{"version":9,"agentsEnabled":true,"protectedPaths":["~/Work"]}"#, to: file)
        let kept = try SettingsStore(file: file).resetUnreadable()
        #expect(kept.settings.agentsEnabled && kept.settings.protectedPaths == ["~/Work"])
        // Without a readable list, agents stay off even if the file said otherwise.
        try write(#"{"version":9,"agentsEnabled":true,"protectedPaths":"~/Work"}"#, to: file)
        let lost = try SettingsStore(file: file).resetUnreadable()
        #expect(!lost.settings.agentsEnabled && lost.settings.protectedPaths.isEmpty)
        #expect(SettingsSalvage(data: Data(#"{"agentsEnabled":1,"protectedPaths":[]}"#.utf8)).agentsEnabled == nil)
        #expect(SettingsSalvage(data: Data(#"{"protectedPaths":["a",3]}"#.utf8)).protectedPaths == nil)
    }

    @Test func resetDoesNothingIfTheFileBecameReadable() throws {
        let file = tempFile()
        try write("{ broken", to: file)
        var session = SettingsSession(store: SettingsStore(file: file))
        #expect(session.load.isUnreadable)
        // Meanwhile, another process (or the user by hand) fixes it.
        try write(#"{"version":1,"protectedPaths":["~/Work"]}"#, to: file)
        #expect(session.resetConfirmation() == nil)
        #expect(try session.reset() == nil)
        guard case .loaded(let s) = session.load else { Issue.record("expected loaded"); return }
        #expect(s.protectedPaths == ["~/Work"])
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.unreadable-") }
        #expect(aside.isEmpty)
    }

    @Test func settingsSessionSavesAndSaysWhenRiskInputsChange() throws {
        let file = tempFile()
        var session = SettingsSession(store: SettingsStore(file: file))
        #expect(session.load == .missing && session.destructiveRefusal == nil)
        #expect(try session.update { $0.agentsEnabled = false } == false)
        #expect(try session.update { $0.mode = .prudent } == true)
        #expect(try session.update { _ = $0.protect("~/Work", home: h) } == true)
        #expect(try session.update { $0.mode = .prudent } == false)
        var expected = AirySettings.defaults
        expected.agentsEnabled = false
        expected.mode = .prudent
        expected.protectedPaths = ["~/Work"]
        #expect(SettingsStore(file: file).load() == .loaded(expected))
        #expect(session.effective == expected)
        // Another process (or the user) breaks it: it is noticed when reading again and it blocks.
        try write("[]", to: file)
        #expect(session.reload() == true)
        #expect(session.destructiveRefusal != nil)
    }
}
