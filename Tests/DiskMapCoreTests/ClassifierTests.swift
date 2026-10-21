import Foundation
import Testing
@testable import DiskMapCore

private let home = "/Users/ana"
private let cache = home + "/Library/Caches/foo"

private func entry(
    _ id: String = "foo", risk: Risk = .safe, aggressiveRisk: Risk? = nil, regenerates: Bool = true,
    paths: [String] = ["~/Library/Caches/foo"], cleanup: CleanupMethod = .trash,
    preselectInAggressive: Bool = false, profiles: [UsageProfile] = []
) -> CatalogEntry {
    CatalogEntry(
        id: id, title: "Prueba \(id)", explanation: "", whoCreatesIt: "", regenerates: regenerates,
        risk: risk, kind: .caches, paths: paths, cleanup: cleanup,
        aggressiveRisk: aggressiveRisk, preselectInAggressive: preselectInAggressive, profiles: profiles)
}

extension CatalogEntry {
    fileprivate func with(regenerates: Bool) -> CatalogEntry {
        var copy = self
        copy.regenerates = regenerates
        return copy
    }
}

private func settings(_ mode: CleanupMode, profiles: Set<UsageProfile> = [], protected: [String] = []) -> AirySettings {
    var s = AirySettings()
    s.mode = mode
    s.profiles = profiles
    s.protectedPaths = protected
    return s
}

private func classifier(
    _ mode: CleanupMode, profiles: Set<UsageProfile> = [], protected: [String] = [], entries: [CatalogEntry] = [],
    home: String = home
) -> RiskClassifier {
    RiskClassifier(catalog: Catalog(entries: entries), settings: settings(mode, profiles: profiles, protected: protected),
                   home: home)
}

private func makeTempDir() -> String {
    let url = TestTemp.url("airy-classifier")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func writeFile(_ path: String, bytes: Int = 10_000) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
}

@Suite struct ClassifierTests {
    @Test func prudentUsesCatalogRisk() {
        let c = classifier(.prudent)
        #expect(c.classify(entry: entry(risk: .yourCall, aggressiveRisk: .safe), paths: [cache]).risk == .yourCall)
        #expect(c.classify(entry: entry(risk: .safe), paths: [cache]).risk == .safe)
        #expect(c.baseRisk(of: entry(risk: .safe, aggressiveRisk: .doNotTouch)) == .safe)
    }

    @Test func riskLabels() {
        #expect(Risk.safe.label == "Safe to remove")
        #expect(Risk.yourCall.label == "Your call")
        #expect(Risk.doNotTouch.label == "Don't delete")
    }

    @Test func aggressiveLowersOnlyRegenerableEntries() {
        let e = entry(risk: .yourCall, aggressiveRisk: .safe, regenerates: true)
        #expect(classifier(.aggressive).classify(entry: e, paths: [cache]).risk == .safe)
        #expect(classifier(.prudent).classify(entry: e, paths: [cache]).risk == .yourCall)
        #expect(classifier(.aggressive).classify(entry: e.with(regenerates: false), paths: [cache]).risk == .yourCall)
        // Raising is always allowed, even if it does not regenerate.
        let up = entry(risk: .safe, aggressiveRisk: .yourCall, regenerates: false)
        #expect(classifier(.aggressive).classify(entry: up, paths: [cache]).risk == .yourCall)
    }

    @Test func aggressiveNeverUnlocksDoNotTouch() {
        let e = entry(risk: .doNotTouch, aggressiveRisk: .safe, regenerates: true)
        let c = classifier(.aggressive)
        #expect(c.baseRisk(of: e) == .doNotTouch)
        #expect(c.classify(entry: e, paths: [cache]).risk == .doNotTouch)
        #expect(c.classify(entry: entry(risk: .doNotTouch, aggressiveRisk: .yourCall), paths: [cache]).risk == .doNotTouch)
        #expect(c.classify(entry: e, paths: [cache]).preselected == false)
    }

    @Test func personalFolderNeverGreenEvenInAggressive() {
        let e = entry("node-modules", risk: .yourCall, aggressiveRisk: .safe, regenerates: true,
                      paths: ["~/Projects/*/node_modules"], preselectInAggressive: true)
        let result = classifier(.aggressive).classify(entry: e, paths: [home + "/Projects/app/node_modules"])
        #expect(result.risk == .yourCall)
        #expect(result.keptPaths == [home + "/Projects/app/node_modules"])
    }

    @Test func profilesNeverChangeRisk() {
        let entries = [
            entry("a", risk: .safe, profiles: [.developer]),
            entry("b", risk: .yourCall, aggressiveRisk: .safe, profiles: [.localAI, .creative]),
            entry("c", risk: .yourCall, aggressiveRisk: .doNotTouch, profiles: [.gaming]),
            entry("d", risk: .doNotTouch, profiles: UsageProfile.allCases),
        ]
        let all = UsageProfile.allCases
        #expect(all.count == 6)
        for mode in CleanupMode.allCases {
            let baseline = entries.map { classifier(mode).classify(entry: $0, paths: [cache]) }
            for mask in 0..<(1 << all.count) {
                let chosen = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                let c = classifier(mode, profiles: chosen)
                for (e, base) in zip(entries, baseline) {
                    let result = c.classify(entry: e, paths: [cache])
                    #expect(result.risk == base.risk)
                    #expect(result.preselected == base.preselected)
                    #expect(result.highlighted == !Set(e.profiles).isDisjoint(with: chosen))
                }
            }
        }
    }

    @Test func aiCanOnlyRaise() {
        let c = classifier(.aggressive)
        let e = entry(risk: .yourCall)
        #expect(c.classify(entry: e, paths: [cache], ai: .safe).risk == .yourCall)
        #expect(c.classify(entry: e, paths: [cache], ai: .doNotTouch).risk == .doNotTouch)
        #expect(c.classify(entry: entry(risk: .safe), paths: [cache], ai: .yourCall).risk == .yourCall)
        // A path without an entry: at least "Your call", even if the AI says "safe".
        #expect(c.classify(path: home + "/random/thing", ai: .safe).risk == .yourCall)
        #expect(c.classify(path: home + "/random/thing", ai: .doNotTouch).risk == .doNotTouch)
    }

    @Test func userProtectedMakesItemRed() {
        let c = classifier(.aggressive, protected: ["~/Library/Caches/foo", "~/Work/keep/data"],
                           entries: [entry(risk: .safe)])
        let red = c.classify(entry: entry(risk: .safe), paths: [cache])
        #expect(red.risk == .doNotTouch)
        #expect(red.protection?.source == .user)
        #expect(red.keptPaths.isEmpty)
        #expect(red.preselected == false)
        // By path: the path itself, something inside, or a parent folder of something protected.
        #expect(c.classify(path: cache).risk == .doNotTouch)
        #expect(c.classify(path: cache + "/sub/file").protection?.source == .user)
        #expect(c.classify(path: home + "/Work/keep").risk == .doNotTouch)
        #expect(c.classify(path: home + "/Work/other").risk == .yourCall)
        // Command entries: any related protection leaves them red.
        let command = entry("cmd", risk: .safe, paths: ["~/Work"],
                            cleanup: .command(executable: "tool", arguments: ["clean"], sizeProbe: nil))
        let commandResult = c.classify(entry: command, paths: [home + "/Work"])
        #expect(commandResult.risk == .doNotTouch)
        #expect(commandResult.protection?.source == .user)
    }

    @Test func protectedChildIsDroppedFromAggregateItem() {
        let logs = entry("user-logs", risk: .safe, paths: ["~/Library/Logs/*"])
        let a = home + "/Library/Logs/app"
        let cloud = home + "/Library/Logs/com.apple.CloudKit"
        let result = classifier(.aggressive).classify(entry: logs, paths: [a, cloud])
        #expect(result.keptPaths == [a])
        #expect(result.risk == .safe)
        #expect(result.protection == nil)
        #expect(result.preselected)
        // The same with a protection from the user.
        let user = classifier(.prudent, protected: ["~/Library/Logs/app"]).classify(entry: logs, paths: [a, cloud])
        #expect(user.keptPaths.isEmpty)
        #expect(user.risk == .doNotTouch)
        #expect(user.protection != nil)
    }

    @Test func hardProtectionBeatsUserSettings() {
        let keychains = entry("keys", risk: .safe, aggressiveRisk: .safe, paths: ["~/Library/Keychains"],
                              preselectInAggressive: true, profiles: [.developer])
        for mode in CleanupMode.allCases {
            let c = classifier(mode, profiles: [.developer])
            let result = c.classify(entry: keychains, paths: [home + "/Library/Keychains"], ai: .safe)
            #expect(result.risk == .doNotTouch)
            #expect(result.protection?.source == .airy)
            #expect(result.preselected == false)
            #expect(c.classify(path: home + "/Library/Keychains/login.keychain-db", ai: .safe).risk == .doNotTouch)
            // Parent folder of something protected.
            #expect(c.classify(path: home + "/Library").risk == .doNotTouch)
        }
        let command = entry("cmd", risk: .safe, paths: ["~/Library/Mobile Documents"],
                            cleanup: .command(executable: "tool", arguments: ["clean"], sizeProbe: nil))
        #expect(classifier(.aggressive).classify(entry: command, paths: [home + "/Library/Mobile Documents/x"]).risk
                == .doNotTouch)
    }

    @Test func preselection() {
        let flagged = entry(risk: .yourCall, preselectInAggressive: true)
        #expect(classifier(.aggressive).classify(entry: flagged, paths: [cache]).preselected)
        #expect(!classifier(.prudent).classify(entry: flagged, paths: [cache]).preselected)
        #expect(!classifier(.aggressive).classify(entry: entry(risk: .yourCall), paths: [cache]).preselected)
        #expect(classifier(.prudent).classify(entry: entry(risk: .safe), paths: [cache]).preselected)
        #expect(!classifier(.aggressive).classify(entry: flagged, paths: [cache], ai: .doNotTouch).preselected)
        #expect(!classifier(.aggressive).classify(
            entry: entry(risk: .doNotTouch, preselectInAggressive: true), paths: [cache]).preselected)
    }

    @Test func scannerRiskEqualsClassifier() async {
        let home = makeTempDir()
        writeFile(home + "/Library/Caches/foo/a", bytes: 20_000)
        writeFile(home + "/Library/Logs/app/x.log", bytes: 20_000)
        writeFile(home + "/Library/Logs/com.apple.CloudKit/y.log", bytes: 50_000)
        let foo = entry(risk: .yourCall, aggressiveRisk: .safe, profiles: [.developer])
        let logs = entry("user-logs", risk: .safe, paths: ["~/Library/Logs/*"])
        let catalog = Catalog(entries: [foo, logs])
        let classifier = RiskClassifier(catalog: catalog, settings: settings(.aggressive, profiles: [.developer]),
                                        home: home)
        let items = await CleanupScanner(
            catalog: catalog, runner: FakeRunner(), probes: FakeProbes(), references: ReferenceChecker(roots: []),
            home: home, classifier: classifier
        ).findItems(scan: nil)
        let fooItem = try! #require(items.first { $0.id == "foo" })
        let expected = classifier.classify(entry: foo, paths: [home + "/Library/Caches/foo"])
        #expect(fooItem.risk == expected.risk)
        #expect(fooItem.risk == .safe)
        #expect(fooItem.preselected && fooItem.highlighted && fooItem.protection == nil)
        let logsItem = try! #require(items.first { $0.id == "user-logs" })
        #expect(logsItem.paths == [home + "/Library/Logs/app"])
        #expect(logsItem.bytes == (AllocatedSize.of(home + "/Library/Logs/app") ?? -1))
        #expect(logsItem.risk == .safe)

        // Without a classifier: default settings (Aggressive), same as the default classifier.
        let defaults = await CleanupScanner(
            catalog: catalog, runner: FakeRunner(), probes: FakeProbes(), references: ReferenceChecker(roots: []),
            home: home
        ).findItems(scan: nil)
        let byDefault = RiskClassifier(catalog: catalog, settings: .defaults, home: home)
        #expect(defaults.first { $0.id == "foo" }?.risk == byDefault.classify(entry: foo, paths: [home + "/Library/Caches/foo"]).risk)
        #expect(defaults.first { $0.id == "foo" }?.highlighted == false)
    }

    @Test func bundledCatalogDecodesWithDefaults() throws {
        let catalog = try Catalog.bundled()
        #expect(!catalog.entries.isEmpty)
        // The process names of task 6 are only filled in for entries with their own tool.
        #expect(catalog.entries.first { $0.id == "pip" }?.processNames == ["pip", "pip3"])
        #expect(catalog.entries.first { $0.id == "docker-volumes" }?.processNames == [])
        let json = """
        {"entries":[{"id":"x","title":"X","explanation":"","whoCreatesIt":"","regenerates":true,"risk":"yourCall",
        "kind":"caches","paths":["~/x"],"cleanup":{"type":"trash"},"aggressiveRisk":"safe",
        "preselectInAggressive":true,"profiles":["developer","futureProfile"],"processNames":["x-agent"],
        "shortReason":"It regenerates.","perMatch":true,"except":[".DS_Store"],"staleAfterDays":90,"minimumBytes":1000,
        "retention":{"keepNewest":1},"reviewHint":"Look at it yourself."}]}
        """
        let decoded = try #require(try Catalog.decode(Data(json.utf8)).entries.first)
        #expect(decoded.aggressiveRisk == .safe)
        #expect(decoded.preselectInAggressive)
        #expect(decoded.profiles == [.developer])
        #expect(decoded.processNames == ["x-agent"])
        let again = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(decoded))
        #expect(again.aggressiveRisk == .safe && again.preselectInAggressive && again.profiles == [.developer]
                && again.processNames == ["x-agent"])
        #expect(again.shortReason == "It regenerates." && again.perMatch && again.except == [".DS_Store"]
                && again.staleAfterDays == 90 && again.minimumBytes == 1000
                && again.retention == RetentionRule(keepNewest: 1) && again.discovery == nil
                && again.reviewHint == "Look at it yourself.")
        let bad = json.replacingOccurrences(of: "\"aggressiveRisk\":\"safe\"", with: "\"aggressiveRisk\":\"meh\"")
        #expect(throws: DecodingError.self) { try Catalog.decode(Data(bad.utf8)) }
    }

    /// After the hard protections, no entry of the bundled catalog is less strict than in
    /// phase 1 (`RiskPolicy.effectiveRisk` with the entry's risk), in any mode. The ones that become
    /// "Do not touch" or lose paths are the expected ones (fixed list: if it changes, it has to be reviewed).
    @Test func bundledCatalogIsNeverLessStrictThanPhaseOne() throws {
        let catalog = try Catalog.bundled()
        var becameRed: Set<String> = [], dropped: Set<String> = [], lowered: Set<String> = []
        // Plan 3: Aggressive mode deliberately lowers what regenerates (`aggressiveRisk`); fixed list.
        let expectedAggressiveLowerings: Set<String> = ["docker-images", "go-mod-cache", "app-support-caches"]
        for mode in CleanupMode.allCases {
            let c = RiskClassifier(catalog: catalog, settings: settings(mode), home: home)
            for e in catalog.entries {
                let paths = e.paths.map { p in
                    (p.hasPrefix("~/") ? home + p.dropFirst() : p).replacingOccurrences(of: "*", with: "muestra")
                }
                let phaseOne = paths.reduce(e.risk) {
                    .strictest($0, RiskPolicy.effectiveRisk(path: $1, home: home, catalog: e.risk, ai: nil))
                }
                let now = c.classify(entry: e, paths: paths)
                if mode == .aggressive, now.risk < phaseOne, e.regenerates, e.aggressiveRisk == now.risk {
                    lowered.insert(e.id)
                } else {
                    #expect(now.risk >= phaseOne, "\(e.id) en modo \(mode): \(now.risk) < \(phaseOne)")
                }
                if now.risk == .doNotTouch && phaseOne != .doNotTouch { becameRed.insert(e.id) }
                if now.keptPaths.count < paths.count, case .trash = e.cleanup { dropped.insert(e.id) }
            }
        }
        #expect(lowered == expectedAggressiveLowerings, "Bajadas en Agresivo: \(lowered.sorted())")
        #expect(becameRed == expectedRedAfterHardProtections, "Nuevas en rojo: \(becameRed.sorted())")
        #expect(dropped == expectedDroppedAfterHardProtections, "With paths removed: \(dropped.sorted())")
    }

    @Test func retiredProfileNoLongerReordersGroups() {
        func item(_ id: String, bytes: Int64, highlighted: Bool = false, risk: Risk = .safe) -> CleanupItem {
            CleanupItem(id: id, entry: entry(id, risk: risk), paths: [cache], bytes: bytes, risk: risk,
                        blockedByOpenApps: [], usedBy: [], highlighted: highlighted)
        }
        let board = CleanupBoard(items: [
            item("big", bytes: 1_000), item("small-hi", bytes: 10, highlighted: true),
            item("mid-hi", bytes: 100, highlighted: true), item("amber", bytes: 5, risk: .yourCall),
        ])
        #expect(board.groups.map { $0.items.map(\.id) } == [["big", "mid-hi", "small-hi"], ["amber"]])
    }

    @Test func protectedOrBlockedItemsCannotBeSelected() {
        var it = CleanupItem(id: "foo", entry: entry(), paths: [cache], bytes: 1, risk: .safe,
                             blockedByOpenApps: [], usedBy: [])
        #expect(CleanupBoard.canSelect(it))
        it.blockedReason = "Spotify is open"
        #expect(!CleanupBoard.canSelect(it) && CleanupBoard.showsCheckbox(it))
        it.blockedReason = nil
        it.protection = ProtectionMatch(source: .user, pattern: "~/x", reason: "Protected by you.")
        #expect(!CleanupBoard.canSelect(it) && !CleanupBoard.showsCheckbox(it))
    }

    @Test func aiAssistantUsesClassifier() {
        let foo = entry(risk: .safe)
        let catalog = Catalog(entries: [foo])
        let node = FileNode(name: "foo", isDirectory: true, allocatedSize: 5_000, kind: .caches)
        let caches = FileNode(name: "Caches", isDirectory: true, allocatedSize: 5_000, children: [node])
        let library = FileNode(name: "Library", isDirectory: true, allocatedSize: 5_000, children: [caches])
        let tree = FileNode(name: home, isDirectory: true, allocatedSize: 5_000, children: [library])
        let context = AIContextBuilder.context(scan: tree, items: [], catalog: catalog, home: home)
        let raw = AIReport(summary: "", recommendations: [
            AIRecommendation(id: cache, path: cache, verdict: .safe, reason: "cache", bytes: 0,
                             action: .trash(path: cache)),
        ], reclaimableBytes: 0)
        let plain = AIAssistant(claudePath: "/opt/claude", runner: FakeRunner(), catalog: catalog, home: home)
        #expect(plain.validate(raw, context: context).recommendations.first?.verdict == .safe)
        let protected = RiskClassifier(catalog: catalog, settings: settings(.aggressive, protected: ["~/Library/Caches/foo"]),
                                       home: home)
        let guarded = AIAssistant(claudePath: "/opt/claude", runner: FakeRunner(), catalog: catalog, home: home,
                                  classifier: protected)
        let rec = guarded.validate(raw, context: context).recommendations.first
        #expect(rec?.verdict == .doNotTouch)
        #expect(rec?.action == nil)
    }
}

/// Entries of the bundled catalog that the hard protections leave as "Do not touch" (they were not before).
/// The "Review only" ones under `/Library`, `/private` and `/Applications` (plan 3, task 5): informational, without an action.
private let expectedRedAfterHardProtections: Set<String> = [
    "system-diagnostic-reports", "system-logs", "system-caches", "macos-installers", "chrome-old-frameworks",
    "brave-old-frameworks", "edge-old-frameworks", "music-sound-libraries",
]
/// Trash entries from which the hard protections remove some path.
private let expectedDroppedAfterHardProtections: Set<String> = []
