import Foundation
import Testing
@testable import DiskMapCore

private func makeDir(_ label: String) -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func mkdir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func write(_ path: String, bytes: Int = 1) {
    mkdir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x78, count: bytes))
}

private func writePlist(_ path: String, _ object: [String: Any]) {
    mkdir((path as NSString).deletingLastPathComponent)
    let data = try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: path))
}

private func makeBundle(_ path: String, id: String) {
    write(path + "/Contents/MacOS/main", bytes: 10_000)
    writePlist(path + "/Contents/Info.plist", ["CFBundleIdentifier": id])
}

private func record(_ id: String, _ name: String, _ path: String, helpers: [String] = [],
                    system: Bool = false) -> AppRecord {
    AppRecord(bundleID: id, name: name, version: "1.0", path: path, helperBundleIDs: helpers, isSystem: system,
              isAppStore: false, caskToken: nil, lastUsed: nil)
}

@Suite final class LeftoverTests {
    let tmp = makeDir("airy-leftovers")
    var apps: String { tmp + "/Applications" }
    var h: String { tmp + "/home" }
    var lib: String { h + "/Library" }
    var sysLib: String { tmp + "/Library" }
    var fooPath: String { apps + "/Foo.app" }
    var foo: AppRecord { record("com.example.foo", "Foo Bar", fooPath, helpers: ["com.example.foo.helper"]) }
    let id = "com.example.foo"

    init() {
        mkdir(tmp + "/home/Library")
        mkdir(tmp + "/Library")
        makeBundle(tmp + "/Applications/Foo.app", id: "com.example.foo")
    }

    deinit { try? FileManager.default.removeItem(atPath: tmp) }

    func finder(protected patterns: [String] = [], runner: FakeRunner? = nil) -> LeftoverFinder {
        let gate = PathGate(home: h, catalog: try? Catalog.bundled(),
                            userProtected: ProtectList(patterns: patterns, home: h))
        let runner = runner ?? FakeRunner(outputs: [
            "/usr/sbin/pkgutil --file-info \(fooPath)":
                CommandOutput(status: 0, stdout: "volume: /\npath: \(fooPath)\n\npkgid: com.example.foo.pkg\npkg-version: 1\n",
                              stderr: ""),
        ])
        return LeftoverFinder(home: h, gate: gate, runner: runner, appRoots: [apps], systemLibrary: sysLib)
    }

    func inventory(_ records: [AppRecord]) -> AppInventorySnapshot {
        AppInventorySnapshot(apps: records, complete: true, problems: [])
    }

    func plan(_ app: AppRecord? = nil, protected: [String] = [], runner: FakeRunner? = nil,
              others: [AppRecord] = []) async -> UninstallPlan {
        let app = app ?? foo
        return await finder(protected: protected, runner: runner).plan(for: app, inventory: inventory([app] + others))
    }

    /// One leftover in each home location, by identifier.
    func makeHomeLeftovers() {
        write(lib + "/Application Support/\(id)/data", bytes: 3000)
        write(lib + "/Caches/\(id)/blob", bytes: 5000)
        write(lib + "/Containers/\(id)/Data/x")
        write(lib + "/Preferences/\(id).plist")
        write(lib + "/Preferences/ByHost/\(id).0000-1111.plist")
        write(lib + "/Saved Application State/\(id).savedState/windows.plist")
        write(lib + "/HTTPStorages/\(id)/x")
        write(lib + "/HTTPStorages/\(id).binarycookies")
        write(lib + "/Logs/\(id)/log.txt")
        writePlist(lib + "/LaunchAgents/\(id).agent.plist", ["Label": "\(id).agent", "Program": "/usr/bin/true"])
        write(lib + "/WebKit/\(id)/x")
        write(lib + "/WebKit/com.apple.WebKit.WebContent/\(id)/x")
        write(lib + "/Cookies/\(id).binarycookies")
        write(lib + "/Application Scripts/\(id)/s.scpt")
        write(lib + "/Autosave Information/\(id)/doc")
        write(lib + "/SyncedPreferences/\(id).plist")
        write(lib + "/Caches/com.example.foo.helper/x")              // by helper
        write(lib + "/Caches/com.example.foobar/x")                  // another app: no
        write(lib + "/Preferences/com.example.foo.other.plist")      // another preference: no
    }

    @Test func findsLeftoversByBundleIDInEveryHomeLocation() async {
        makeHomeLeftovers()
        let plan = await plan()
        let kinds = Set(plan.leftovers.map(\.kind))
        let expected = Set(Leftover.Kind.allCases).subtracting([.receipt, .systemLocation, .plugin])
        #expect(kinds.isSuperset(of: expected), "faltan \(expected.subtracting(kinds))")
        let paths = Set(plan.leftovers.map(\.path))
        #expect(paths.contains(lib + "/Caches/com.example.foo.helper"))
        #expect(paths.contains(lib + "/HTTPStorages/\(id)"))
        #expect(paths.contains(lib + "/HTTPStorages/\(id).binarycookies"))
        #expect(paths.contains(lib + "/WebKit/com.apple.WebKit.WebContent/\(id)"))
        #expect(!paths.contains(lib + "/Caches/com.example.foobar"))
        #expect(!paths.contains(lib + "/Preferences/com.example.foo.other.plist"))
        #expect(plan.leftovers.allSatisfy { !$0.matchedByName })
        #expect(plan.refusal == nil && plan.sharedWith == nil && plan.sizeComplete)
        #expect(plan.id == fooPath)
        // Order: ascending risk, then descending bytes, then path.
        let sorted = plan.leftovers.sorted {
            ($0.risk, -$0.bytes, $0.path) < ($1.risk, -$1.bytes, $1.path)
        }
        #expect(plan.leftovers == sorted)
        #expect(plan.leftovers.first { $0.kind == .caches && $0.path.hasSuffix(id) }?.bytes ?? 0 >= 5000)
    }

    @Test func riskTableAndPreselection() async {
        makeHomeLeftovers()
        write(lib + "/Services/Foo Bar.workflow/x")
        write(lib + "/QuickLook/FooBar.qlgenerator/x")
        write(lib + "/Audio/Plug-Ins/VST3/Foo Bar.vst3/x")
        write(lib + "/Audio/Plug-Ins/Components/Other.component/x")
        let plan = await plan()
        func one(_ kind: Leftover.Kind) -> Leftover? { plan.leftovers.first { $0.kind == kind } }
        let caches = try! #require(one(.caches))
        #expect(caches.risk == .safe && caches.preselected && caches.reason == "Cache: it regenerates.")
        let support = try! #require(one(.appSupport))
        #expect(support.risk == .yourCall && support.preselected)
        #expect(support.reason == "App data and settings; if you reinstall it, it will start from scratch.")
        let autosave = try! #require(one(.autosave))
        #expect(autosave.risk == .yourCall && !autosave.preselected)
        #expect(autosave.reason == "It may hold unsaved documents.")
        let plugins = plan.leftovers.filter { $0.kind == .plugin }
        #expect(Set(plugins.map(\.path)) == [lib + "/Services/Foo Bar.workflow", lib + "/QuickLook/FooBar.qlgenerator",
                                            lib + "/Audio/Plug-Ins/VST3/Foo Bar.vst3"])
        #expect(plugins.allSatisfy {
            $0.risk == .yourCall && !$0.preselected && $0.reason == "Other apps may use this plug-in."
        })
        #expect(one(.savedState)?.risk == .safe)
        #expect(one(.preferences)?.risk == .yourCall)
        #expect(one(.launchAgent)?.launchLabel == "\(id).agent")
        #expect(plan.leftovers.filter { $0.kind != .launchAgent }.allSatisfy { $0.launchLabel == nil })
        #expect(!plan.defaultSelection.contains(autosave.id))
        #expect(plan.defaultSelection.contains(caches.id))
        #expect(caches.id == "caches:" + caches.path)
    }

    @Test func nameOnlyMatchIsYourCallUnselected() async {
        write(lib + "/Application Support/FooBar/x")
        write(lib + "/Caches/foo bar/x")
        write(lib + "/Containers/FooBar/x")                           // Containers: by id only
        let plan = await plan()
        let byName = plan.leftovers.filter(\.matchedByName)
        #expect(Set(byName.map(\.path)) == [lib + "/Application Support/FooBar", lib + "/Caches/foo bar"])
        #expect(byName.allSatisfy {
            $0.risk == .yourCall && !$0.preselected && $0.reason == "Matches by name: check that it belongs to “Foo Bar”."
        })
        #expect(plan.defaultSelection == Set(plan.leftovers.filter { $0.kind == .receipt }.map(\.id)))
    }

    @Test func shortOrGenericNamesDoNotMatch() async {
        write(lib + "/Application Support/Notes/x")
        write(lib + "/Caches/Abc/x")
        write(lib + "/Logs/notes/x")
        for (name, path) in [("Notes", apps + "/Notes.app"), ("Abc", apps + "/Abc.app")] {
            makeBundle(path, id: "com.example.\(name.lowercased())")
            let app = record("com.example.\(name.lowercased())", name, path)
            let plan = await plan(app)
            #expect(plan.leftovers.filter { $0.kind != .receipt }.isEmpty, "\(name): \(plan.leftovers)")
        }
    }

    @Test func launchAgentOwnedByLabelOrProgram() async {
        let agents = lib + "/LaunchAgents"
        writePlist(agents + "/a.plist", ["Label": "com.example.foo.helper"])                 // the helper's id
        writePlist(agents + "/b.plist", ["Label": "com.example.foo.updater.daily"])          // starts with id.
        writePlist(agents + "/c.plist", ["Label": "org.misc.thing",
                                         "ProgramArguments": [fooPath + "/Contents/MacOS/agent", "--x"]])
        writePlist(agents + "/d.plist", ["Label": "org.other", "Program": "/usr/bin/true"])  // someone else's
        writePlist(agents + "/e.plist", ["Label": "com.example.foobar"])                     // another id
        writePlist(agents + "/f.plist", ["Label": "x", "Program": apps + "/Foo.app2/x"])      // not inside
        write(agents + "/broken.plist")                                                       // unreadable
        let plan = await plan()
        let found = plan.leftovers.filter { $0.kind == .launchAgent }
        #expect(Set(found.map(\.path)) == [agents + "/a.plist", agents + "/b.plist", agents + "/c.plist"])
        #expect(Set(found.compactMap(\.launchLabel)) == ["com.example.foo.helper", "com.example.foo.updater.daily",
                                                         "org.misc.thing"])
        #expect(found.allSatisfy {
            $0.risk == .yourCall && $0.preselected && $0.reason == "It runs at login; it is stopped first."
        })
    }

    @Test func receiptsFromPkgutil() async {
        let runner = FakeRunner(outputs: [
            "/usr/sbin/pkgutil --file-info \(fooPath)": CommandOutput(
                status: 0,
                stdout: "volume: /\npath: x\n\npkgid: com.example.foo.pkg\npkg-version: 1\n\npkgid: com.example.foo.extras\npkgid: bad id; rm -rf\npkgid: com.apple.pkg.Core\n",
                stderr: ""),
        ])
        let plan = await plan(runner: runner)
        #expect(runner.calls.contains { $0.executable == "/usr/sbin/pkgutil" && $0.arguments == ["--file-info", fooPath] })
        #expect(runner.calls.allSatisfy { $0.timeout == 10 })
        let receipts = plan.leftovers.filter { $0.kind == .receipt }
        #expect(Set(receipts.map(\.path)) == ["com.example.foo.pkg", "com.example.foo.extras", "com.apple.pkg.Core"])
        let own = receipts.filter { !$0.path.hasPrefix("com.apple.") }
        #expect(own.allSatisfy {
            $0.risk == .safe && $0.preselected && $0.bytes == 0
                && $0.reason == "Install receipt; it asks for an administrator password."
        })
        #expect(receipts.first { $0.path == "com.apple.pkg.Core" }?.risk == .doNotTouch)
        // If pkgutil fails, there are no receipts.
        let failing = FakeRunner(outputs: [
            "/usr/sbin/pkgutil --file-info \(fooPath)": CommandOutput(status: 1, stdout: "pkgid: x.y", stderr: ""),
        ])
        #expect(await self.plan(runner: failing).leftovers.allSatisfy { $0.kind != .receipt })
    }

    @Test func systemLibraryRowsAreRedInfo() async {
        write(sysLib + "/Caches/com.example.foo/x")
        write(sysLib + "/LaunchDaemons/com.example.foo.helper.plist")
        write(sysLib + "/PrivilegedHelperTools/com.example.foo.helper")
        write(sysLib + "/Application Support/Foo Bar/x")
        write(sysLib + "/Logs/Unrelated/x")
        write(sysLib + "/Caches/com.example.foobar/x")                    // another id that starts the same: no
        write(sysLib + "/Application Support/Foo Barista/x")              // another name that starts the same: no
        let plan = await plan()
        let system = plan.leftovers.filter { $0.kind == .systemLocation }
        #expect(Set(system.map(\.path)) == [sysLib + "/Caches/com.example.foo",
                                            sysLib + "/LaunchDaemons/com.example.foo.helper.plist",
                                            sysLib + "/PrivilegedHelperTools/com.example.foo.helper",
                                            sysLib + "/Application Support/Foo Bar"])
        #expect(system.allSatisfy {
            $0.risk == .doNotTouch && !$0.preselected && !$0.canSelect
                && $0.reason == "Outside your home folder: Airy does not delete it."
        })
        #expect(plan.leftoverBytes == plan.leftovers.filter { $0.kind == .receipt }.reduce(0) { $0 + $1.bytes })
    }

    @Test func sensitiveDataIsAmberUnselected() async {
        let slackPath = apps + "/Slack.app"
        makeBundle(slackPath, id: "com.tinyspeck.slackmacgap")
        write(lib + "/Application Support/Slack/x")
        write(lib + "/Caches/com.tinyspeck.slackmacgap/x")
        let slack = record("com.tinyspeck.slackmacgap", "Slack", slackPath)
        let plan = await plan(slack)
        let data = try! #require(plan.leftovers.first { $0.path == lib + "/Application Support/Slack" })
        #expect(data.risk == .yourCall && !data.preselected && data.canSelect)
        #expect(data.reason == "Account data of “Slack”: if you reinstall it you will have to set it up again.")
        #expect(!plan.defaultSelection.contains(data.id))
    }

    @Test func protectedLeftoverIsRed() async {
        write(lib + "/Caches/\(id)/x")
        write(lib + "/Logs/\(id)/x")
        // Docker: its containers are sealed and stay red even though it is its own app.
        let dockerPath = apps + "/Docker.app"
        makeBundle(dockerPath, id: "com.docker.docker")
        write(lib + "/Containers/com.docker.docker/Data/x")
        let plan = await plan(protected: [lib + "/Caches/\(id)"])
        let cache = try! #require(plan.leftovers.first { $0.path == lib + "/Caches/\(id)" })
        #expect(cache.risk == .doNotTouch && !cache.canSelect && cache.reason.hasPrefix("You protected it"))
        #expect(plan.leftovers.first { $0.path == lib + "/Logs/\(id)" }?.risk == .safe)
        #expect(!plan.defaultSelection.contains(cache.id))
        let docker = await self.plan(record("com.docker.docker", "Docker", dockerPath))
        let containers = try! #require(docker.leftovers.first { $0.kind == .containers })
        #expect(containers.risk == .doNotTouch && !containers.canSelect)
    }

    @Test func secondCopyMakesLeftoversInformational() async {
        makeHomeLeftovers()
        let copy = tmp + "/home/Applications/Foo.app"
        makeBundle(copy, id: id)
        let plan = await plan(others: [record(id, "Foo Bar", copy)])
        #expect(plan.sharedWith == copy)
        #expect(!plan.leftovers.isEmpty)
        #expect(plan.leftovers.allSatisfy {
            $0.risk == .doNotTouch && !$0.preselected && $0.reason == "Another copy installed at \(copy) uses them."
        })
        #expect(plan.defaultSelection.isEmpty)
        #expect(plan.leftoverBytes == 0 && plan.realBytes == plan.appBytes)
        // Same receipt (same path): it is not another copy.
        #expect(await self.plan(others: [foo]).sharedWith == nil)
        // Without an identifier there is no "other copy" from matching on empty.
        let blank = record("", "Blank", apps + "/Blank.app")
        #expect(await self.plan(blank, others: [record("", "Other", apps + "/Other.app")]).sharedWith == nil)
    }

    @Test func linkedAppOutsideAppRootsIsInformational() async {
        write(lib + "/Caches/\(id)/x")
        let real = tmp + "/Elsewhere/Foo.app"
        makeBundle(real, id: id)
        let link = apps + "/Linked.app"
        try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let plan = await plan(record(id, "Foo Bar", link))
        #expect(!plan.leftovers.isEmpty)
        #expect(plan.leftovers.allSatisfy { $0.risk == .doNotTouch && !$0.preselected })
        #expect(plan.defaultSelection.isEmpty)
    }

    @Test func refusalTexts() async {
        let cases: [(AppRecord, String)] = [
            (record("com.apple.Safari", "Safari", "/Applications/Safari.app", system: true), "It is part of macOS."),
            (record("com.crowdstrike.falcon.App", "Falcon", apps + "/Falcon.app"),
             "Use the official uninstaller of “Falcon”."),
            (record("local.airy.app", "Airy", apps + "/Airy.app"), "It is Airy."),
            (record("com.setapp.thing", "Thing", lib + "/Application Support/Setapp/Applications/Thing.app"),
             "Uninstall it from Setapp."),
            (record("com.example.loose", "Loose", tmp + "/Downloads/Loose.app"),
             "Only apps in Applications are uninstalled."),
        ]
        for (app, text) in cases {
            let plan = await plan(app)
            #expect(plan.refusal == text, "\(app.path)")
        }
        #expect(await plan().refusal == nil)
    }

    @Test func realSizeAddsAppAndSelectableLeftovers() async {
        makeHomeLeftovers()
        write(sysLib + "/Caches/com.example.foo/x", bytes: 9000)
        let plan = await plan(protected: [lib + "/Logs/\(id)"])
        #expect(plan.appBytes >= 10_000)
        let selectable = plan.leftovers.filter(\.canSelect).reduce(Int64(0)) { $0 + $1.bytes }
        #expect(plan.leftoverBytes == selectable && selectable > 0)
        #expect(plan.realBytes == plan.appBytes + plan.leftoverBytes)
        let red = plan.leftovers.filter { !$0.canSelect }
        #expect(!red.isEmpty)
        // Red selected by hand does not count; the selectable ones do.
        let caches = plan.leftovers.first { $0.kind == .caches }!
        #expect(plan.bytes(selected: Set(red.map(\.id)).union([caches.id])) == plan.appBytes + caches.bytes)
        #expect(plan.bytes(selected: []) == plan.appBytes)
        #expect(plan.defaultSelection == Set(plan.leftovers.filter { $0.preselected && $0.canSelect }.map(\.id)))
    }

    @Test func sizeBudgetExhaustedMarksIncomplete() async {
        makeHomeLeftovers()
        let gate = PathGate(home: h, catalog: try? Catalog.bundled(), userProtected: ProtectList(patterns: [], home: h))
        let finder = LeftoverFinder(home: h, gate: gate, runner: FakeRunner(), appRoots: [apps],
                                    systemLibrary: sysLib, budget: .zero)
        let plan = await finder.plan(for: foo, inventory: inventory([foo]))
        #expect(!plan.sizeComplete)
        #expect(plan.appBytes == 0 && plan.leftovers.allSatisfy { $0.bytes == 0 })
    }

    // MARK: - Data of other installed apps

    @Test func sharedHelperWithAnotherInstalledAppIsRed() async {
        // Foo and Suite share the helper com.example.foo.helper; also, Foo's id is a helper of Other.
        write(lib + "/Caches/com.example.foo.helper/x")
        write(lib + "/Containers/com.example.foo.helper/x")
        write(lib + "/Caches/\(id)/x")
        write(lib + "/Logs/\(id)/x")
        let suite = record("com.example.suite", "Suite", apps + "/Suite.app", helpers: ["com.example.foo.helper"])
        let shared = await plan(others: [suite])
        for path in [lib + "/Caches/com.example.foo.helper", lib + "/Containers/com.example.foo.helper"] {
            let leftover = try! #require(shared.leftovers.first { $0.path == path })
            #expect(leftover.risk == .doNotTouch && !leftover.preselected && !leftover.canSelect)
            #expect(leftover.reason == "Another installed app (“Suite”) also uses it.")
            #expect(!shared.defaultSelection.contains(leftover.id))
        }
        #expect(shared.leftovers.first { $0.path == lib + "/Caches/\(id)" }?.preselected == true)
        let host = record("com.example.host", "Host", apps + "/Host.app", helpers: [id])
        let owned = await plan(others: [host])
        for path in [lib + "/Caches/\(id)", lib + "/Logs/\(id)"] {
            let leftover = try! #require(owned.leftovers.first { $0.path == path })
            #expect(leftover.risk == .doNotTouch && leftover.reason == "Another installed app (“Host”) also uses it.")
        }
        // Our own helper (com.example.foo.helper) descends from one of Foo's ids: it still belongs to Foo.
        #expect(owned.leftovers.first { $0.path == lib + "/Caches/com.example.foo.helper" }?.risk == .safe)
        // An app whose id is an ancestor of ours does not claim Foo's leftovers.
        let vendor = record("com.example", "Example Vendor", apps + "/Vendor.app")
        let ancestor = await plan(others: [vendor])
        #expect(ancestor.leftovers.first { $0.path == lib + "/Caches/\(id)" }?.preselected == true)
    }

    @Test func prefixOfAnotherInstalledAppIsNotClaimed() async {
        write(lib + "/Preferences/ByHost/\(id).1111.plist")
        write(lib + "/Preferences/ByHost/\(id).pro.2222.plist")
        writePlist(lib + "/LaunchAgents/own.plist", ["Label": "\(id).agent"])
        writePlist(lib + "/LaunchAgents/pro.plist", ["Label": "\(id).pro.agent"])
        let pro = record("\(id).pro", "Foo Pro", apps + "/Foo Pro.app")
        let plan = await plan(others: [pro])
        let reason = "Another installed app (“Foo Pro”) also uses it."
        for path in [lib + "/Preferences/ByHost/\(id).pro.2222.plist", lib + "/LaunchAgents/pro.plist"] {
            let leftover = try! #require(plan.leftovers.first { $0.path == path })
            #expect(leftover.risk == .doNotTouch && !leftover.preselected && leftover.reason == reason)
        }
        for path in [lib + "/Preferences/ByHost/\(id).1111.plist", lib + "/LaunchAgents/own.plist"] {
            let leftover = try! #require(plan.leftovers.first { $0.path == path })
            #expect(leftover.risk == .yourCall && leftover.preselected)
        }
    }

    @Test func receiptSharedWithOtherAppIsNotSelected() async {
        let info = "/usr/sbin/pkgutil --file-info \(fooPath)"
        let ids = "pkgid: com.example.foo.pkg\npkgid: com.example.suite.pkg\npkgid: com.example.unknown.pkg\n"
        let runner = FakeRunner(outputs: [
            info: CommandOutput(status: 0, stdout: ids, stderr: ""),
            "/usr/sbin/pkgutil --files com.example.foo.pkg --only-dirs": CommandOutput(
                status: 0, stdout: "Applications\nApplications/Foo.app\nApplications/Foo.app/Contents/Helpers/H.app\n",
                stderr: ""),
            "/usr/sbin/pkgutil --files com.example.suite.pkg --only-dirs": CommandOutput(
                status: 0, stdout: "Applications/Foo.app\nApplications/Suite Tools/Bar.app/Contents\n", stderr: ""),
            "/usr/sbin/pkgutil --files com.example.unknown.pkg --only-dirs": CommandOutput(
                status: 1, stdout: "", stderr: "No receipt"),
        ])
        let plan = await plan(runner: runner)
        #expect(runner.calls.contains {
            $0.arguments == ["--files", "com.example.suite.pkg", "--only-dirs"] && $0.timeout == 10
        })
        func receipt(_ id: String) -> Leftover? { plan.leftovers.first { $0.kind == .receipt && $0.path == id } }
        #expect(receipt("com.example.foo.pkg")?.risk == .safe)
        #expect(receipt("com.example.foo.pkg")?.preselected == true)
        let suite = try! #require(receipt("com.example.suite.pkg"))
        #expect(suite.risk == .doNotTouch && !suite.preselected)
        #expect(suite.reason == "This receipt also includes other apps (Bar.app).")
        let unknown = try! #require(receipt("com.example.unknown.pkg"))
        #expect(unknown.risk == .yourCall && !unknown.preselected)
        #expect(unknown.reason == "Could not check whether this receipt includes other apps.")
        #expect(plan.defaultSelection.filter { $0.hasPrefix("receipt:") } == ["receipt:com.example.foo.pkg"])
    }

    @Test func moreAccountAppsNeedTheWaiver() async {
        // Besides Slack: Discord (Application Support) and WhatsApp (Containers).
        let cases: [(id: String, name: String, data: String)] = [
            ("com.hnc.Discord", "Discord", lib + "/Application Support/discord"),
            ("net.whatsapp.WhatsApp", "WhatsApp", lib + "/Containers/net.whatsapp.WhatsApp"),
            ("ru.keepcoder.Telegram", "Telegram", lib + "/Containers/ru.keepcoder.Telegram"),
        ]
        for item in cases {
            let path = apps + "/\(item.name).app"
            makeBundle(path, id: item.id)
            write(item.data + "/x")
            let plan = await plan(record(item.id, item.name, path))
            let data = try! #require(plan.leftovers.first { $0.path == item.data }, "\(item.name)")
            #expect(data.risk == .yourCall && !data.preselected, "\(item.name)")
            #expect(data.reason == "Account data of “\(item.name)”: if you reinstall it you will have to set it up again.",
                    "\(item.name)")
        }
    }
}
