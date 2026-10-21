import Foundation
import Testing
@testable import DiskMapCore

private func makeDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func mkdir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func touch(_ path: String) {
    mkdir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
}

/// Fake `.app` with its `Contents/Info.plist` and an executable.
private func makeBundle(_ path: String, id: String) {
    mkdir(path + "/Contents/MacOS")
    touch(path + "/Contents/MacOS/" + ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
    writeInfoPlist(path, id: id)
}

private func writeInfoPlist(_ path: String, id: String) {
    let data = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
}

private func record(_ id: String, _ name: String, _ path: String, helpers: [String] = [], system: Bool = false) -> AppRecord {
    AppRecord(bundleID: id, name: name, version: "1.0", path: path, helperBundleIDs: helpers, isSystem: system,
              isAppStore: false, caskToken: nil, lastUsed: nil)
}

@Suite struct UninstallGateTests {
    let tmp = makeDir("airy-uninstall-gate")
    var apps: String { tmp + "/Applications" }
    var h: String { tmp + "/home" }
    var foo: String { apps + "/Foo.app" }
    var fooApp: AppRecord { record("com.example.foo", "Foo Bar", foo) }
    var fooWaiver: ProtectionWaiver? { .uninstall(fooApp, appRoots: [apps]) }
    var support: String { h + "/Library/Application Support" }

    init() {
        mkdir(tmp + "/home/Library/Caches")
        makeBundle(tmp + "/Applications/Foo.app", id: "com.example.foo")
    }

    func gate(protected patterns: [String] = [], criticalRoots: [String] = []) -> PathGate {
        PathGate(home: h, catalog: try? Catalog.bundled(), userProtected: ProtectList(patterns: patterns, home: h),
                 protections: HardProtections(criticalRoots: criticalRoots, sealedSystemLocations: [apps]))
    }

    // MARK: - The exact `.app`

    @Test func bundlePassesOnlyWithItsOwnWaiver() throws {
        let gate = gate()
        makeBundle(apps + "/Other.app", id: "com.example.other")
        #expect(gate.validate(foo, waiver: nil).failure != nil)
        #expect(gate.validate(foo).failure != nil)                                  // validate(_:) == waiver nil
        let waiver = try #require(fooWaiver)
        let validated = try gate.validate(foo, waiver: waiver).get()
        #expect(validated.path == foo)
        #expect(gate.confirmUnchanged(validated) == nil)
        // Another app, the apps folder and what is inside the `.app`: they never count as the `.app`.
        for path in [apps + "/Other.app", apps, foo + "/Contents", foo + "/Contents/Info.plist",
                     foo + "/Contents/MacOS/Foo"] {
            #expect(gate.validate(path, waiver: waiver).failure != nil, "\(path)")
        }
        // The other app's waiver does not open Foo either.
        let other = try #require(ProtectionWaiver.uninstall(record("com.example.other", "Other", apps + "/Other.app"),
                                                            appRoots: [apps]))
        #expect(gate.validate(foo, waiver: other).failure != nil)
        #expect(gate.validate(apps + "/Other.app", waiver: other).failure == nil)
    }

    @Test func caseVariantsAndTraversalOfTheBundleRefused() throws {
        let gate = gate()
        let waiver = try #require(fooWaiver)
        // On case-insensitive APFS they are the same file, but it is not the chosen path: the whole hard list applies.
        for path in [apps + "/foo.app", apps + "/FOO.APP", apps + "/Foo.App", foo + "/", foo + "/.",
                     foo + "/Contents/..", apps + "/./Foo.app", apps + "//Foo.app", apps + "/Other/../Foo.app"] {
            #expect(gate.validate(path, waiver: waiver).failure != nil, "\(path)")
        }
    }

    @Test func waiverRefusesWhenBundleIDChanged() throws {
        let gate = gate()
        let waiver = try #require(fooWaiver)
        #expect(gate.validate(foo, waiver: waiver).failure == nil)
        writeInfoPlist(foo, id: "com.example.impostor")
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
        writeInfoPlist(foo, id: "COM.EXAMPLE.FOO")                                  // not in another case either
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
        try FileManager.default.removeItem(atPath: foo + "/Contents/Info.plist")    // without Info.plist
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: foo + "/Contents/Info.plist"))
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
    }

    @Test func symlinkBundleRefused() throws {
        let gate = gate()
        // A link shaped like an `.app` that points to the real app.
        try FileManager.default.createSymbolicLink(atPath: apps + "/Link.app", withDestinationPath: foo)
        let linkWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.foo", "Foo Bar", apps + "/Link.app"),
                                                                appRoots: [apps]))
        #expect(gate.validate(apps + "/Link.app", waiver: linkWaiver).failure?.reason == "It is no longer the app you chose.")
        // A link to another protected folder, with a fake Info.plist inside the target.
        let keychains = h + "/Library/Keychains/Evil.app"
        makeBundle(keychains, id: "com.example.evil")
        try FileManager.default.createSymbolicLink(atPath: apps + "/Evil.app", withDestinationPath: keychains)
        let evil = try #require(ProtectionWaiver.uninstall(record("com.example.evil", "Evil", apps + "/Evil.app"),
                                                          appRoots: [apps]))
        #expect(gate.validate(apps + "/Evil.app", waiver: evil).failure != nil)
        // The chosen app is swapped for a link after the waiver is created.
        let waiver = try #require(fooWaiver)
        try FileManager.default.moveItem(atPath: foo, toPath: apps + "/Real.app")
        try FileManager.default.createSymbolicLink(atPath: foo, withDestinationPath: apps + "/Real.app")
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
    }

    @Test func onlyTheAppRootSealIsWaived() throws {
        // An apps root inside another sealed location: the outer seal is not waived.
        let system = tmp + "/System"
        let inner = system + "/Applications/Calc.app"
        makeBundle(inner, id: "com.example.calc")
        let gate = PathGate(home: h, catalog: nil, userProtected: ProtectList(patterns: [], home: h),
                            protections: HardProtections(criticalRoots: [], sealedSystemLocations: [apps, system]))
        let waiver = try #require(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", inner),
                                                            appRoots: [system + "/Applications"]))
        #expect(gate.validate(inner, waiver: waiver).failure?.reason == "Location protected by Airy: \(system).")
        // And the "/" root never counts as an apps root.
        #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo", foo), appRoots: ["/"]) == nil)
    }

    @Test func onlyApplicationsRootsAccepted() {
        // A root not called "Applications" never gives a waiver, even if the app hangs from it.
        for (root, path) in [("/Library", "/Library/X.app"), ("/usr", "/usr/X.app"), ("/opt/homebrew", "/opt/homebrew/X.app"),
                             ("/private", "/private/X.app"), ("/System", "/System/X.app"), ("/", "/X.app"),
                             (h + "/Library/Keychains", h + "/Library/Keychains/X.app"), (tmp + "/Apps", tmp + "/Apps/X.app"),
                             ("/Applications/Utilities", "/Applications/Utilities/A/B/X.app")] {
            #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", path), appRoots: [root]) == nil, "\(root)")
        }
        // Case aside, "Applications" does count (and so does the production one).
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", tmp + "/APPLICATIONS/Foo.app"),
                                           appRoots: [tmp + "/APPLICATIONS"]) != nil)
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", foo),
                                           appRoots: ["/Library", "/usr", apps]) != nil)
    }

    @Test func libraryRootNeverOpensItsSeal() throws {
        // Even if someone named a folder inside a system seal "Applications", only the seal
        // whose pattern is the apps root is waived; the outer one still rejects.
        let lib = tmp + "/Library"
        let inner = lib + "/Applications/X.app"
        makeBundle(inner, id: "com.example.x")
        let gate = PathGate(home: h, catalog: nil, userProtected: ProtectList(patterns: [], home: h),
                            protections: HardProtections(criticalRoots: [], sealedSystemLocations: [lib]))
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", inner), appRoots: [lib]) == nil)
        let waiver = try #require(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", inner),
                                                            appRoots: [lib + "/Applications"]))
        #expect(gate.validate(inner, waiver: waiver).failure?.reason == "Location protected by Airy: \(lib).")
    }

    @Test func systemnessRecomputedNotTrusted() throws {
        // The caller's `isSystem: false` is not enough: a link towards /System is resolved and rejected.
        let calculator = "/System/Applications/Calculator.app"
        if FileManager.default.fileExists(atPath: calculator) {
            try FileManager.default.createSymbolicLink(atPath: apps + "/Calc.app", withDestinationPath: calculator)
            #expect(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", apps + "/Calc.app"), appRoots: [apps]) == nil)
        } else {
            Issue.record("There is no \(calculator) to test the link towards /System.")
        }
        // An apps folder linked inside /System.
        try FileManager.default.createSymbolicLink(atPath: tmp + "/SysLink", withDestinationPath: "/System")
        #expect(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", tmp + "/SysLink/Applications/Calculator.app"),
                                           appRoots: [tmp + "/SysLink/Applications"]) == nil)
        // An essential system identifier, in the record or on disk.
        #expect(ProtectionWaiver.uninstall(record("com.apple.Finder", "Finder", apps + "/Finder.app"), appRoots: [apps]) == nil)
        makeBundle(apps + "/Fake.app", id: "com.apple.Safari")
        #expect(ProtectionWaiver.uninstall(record("com.example.fake", "Fake", apps + "/Fake.app"), appRoots: [apps]) == nil)
        makeBundle(apps + "/Falcon.app", id: "com.crowdstrike.falcon")
        #expect(ProtectionWaiver.uninstall(record("com.example.falcon", "Falcon", apps + "/Falcon.app"), appRoots: [apps]) == nil)
        // Nor without a resolvable parent folder.
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", tmp + "/Nada/Applications/X.app"),
                                           appRoots: [tmp + "/Nada/Applications"]) == nil)
    }

    @Test func wrappedIOSAppPassesWithItsWaiver() throws {
        // iOS/iPadOS app: without Contents/Info.plist; the identifier is in Wrapper/<name>.app/Info.plist.
        let wrapped = apps + "/Juego.app"
        mkdir(wrapped + "/Wrapper/Juego.app")
        func writeWrapped(_ id: String) {
            let data = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try! data.write(to: URL(fileURLWithPath: wrapped + "/Wrapper/Juego.app/Info.plist"))
        }
        writeWrapped("com.example.juego")
        #expect(AppInventory.bundleIdentifier(ofApp: wrapped) == "com.example.juego")
        let waiver = try #require(ProtectionWaiver.uninstall(record("com.example.juego", "Juego", wrapped), appRoots: [apps]))
        let gate = gate()
        #expect(gate.validate(wrapped, waiver: nil).failure != nil)
        #expect(gate.validate(wrapped, waiver: waiver).failure == nil)
        #expect(gate.validate(wrapped + "/Wrapper/Juego.app", waiver: waiver).failure != nil)
        writeWrapped("com.example.otro")
        #expect(gate.validate(wrapped, waiver: waiver).failure?.reason == "It is no longer the app you chose.")
    }

    @Test func criticalRootNeverWaived() throws {
        let waiver = try #require(fooWaiver)
        #expect(gate(criticalRoots: [foo]).validate(foo, waiver: waiver).failure != nil)
        // Only by the text (the root did not exist when the funnel was created, so its inode is not registered).
        let late = apps + "/Late.app"
        let lateGate = gate(criticalRoots: [late])
        makeBundle(late, id: "com.example.late")
        let lateWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.late", "Late", late), appRoots: [apps]))
        #expect(lateGate.validate(late, waiver: lateWaiver).failure?.reason == "Critical system folder.")
        // An "apps root" inside a sealed home location: the home seal is not waived.
        let keychainApp = h + "/Library/Keychains/Applications/Evil.app"
        makeBundle(keychainApp, id: "com.example.evil")
        let keychainWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.evil", "Evil", keychainApp),
                                                                    appRoots: [h + "/Library/Keychains/Applications"]))
        #expect(gate().validate(keychainApp, waiver: keychainWaiver).failure?.reason
            == "Location protected by Airy: Keychains.")
        // The real hard list: /Applications/Safari.app is a critical root, with or without a waiver.
        let safari = ProtectionWaiver.uninstall(record("com.apple.Safari", "Safari", "/Applications/Safari.app"),
                                                appRoots: ProtectionWaiver.productionAppRoots(home: h))
        let real = PathGate(home: h, catalog: nil, userProtected: ProtectList(patterns: [], home: h))
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            #expect(real.validate("/Applications/Safari.app", waiver: safari).failure != nil)
        }
        #expect(HardProtections.standard.matches(canonicalPath: "/applications/safari.app", home: h, catalog: nil)
            .contains { $0.rule == .critical })
    }

    @Test func bundleFragmentWaivedOnlyInItsOwnName() throws {
        let gate = gate()
        // The `.app` name contains a fragment (1password): it can be uninstalled with its waiver.
        let onePassword = apps + "/1Password.app"
        makeBundle(onePassword, id: "com.1password.1password")
        let opWaiver = try #require(ProtectionWaiver.uninstall(record("com.1password.1password", "1Password", onePassword),
                                                              appRoots: [apps]))
        #expect(gate.validate(onePassword, waiver: nil).failure != nil)
        #expect(gate.validate(onePassword, waiver: opWaiver).failure == nil)
        // The fragment in a parent folder is not waived (even if the `.app` name has it too).
        let nested = apps + "/Keychain Tools/Keychain Foo.app"
        makeBundle(nested, id: "com.example.foo")
        let sibling = apps + "/Keychain Foo.app"
        makeBundle(sibling, id: "com.example.foo")
        let siblingWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.foo", "Keychain Foo", sibling),
                                                                   appRoots: [apps]))
        #expect(gate.validate(sibling, waiver: siblingWaiver).failure == nil)
        let nestedWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.foo", "Keychain Foo", nested),
                                                                  appRoots: [apps]))
        #expect(gate.validate(nested, waiver: nestedWaiver).failure != nil)
    }

    // MARK: - Who can have a waiver

    @Test func noWaiverForSystemOfficialUninstallerOrAiry() {
        #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo Bar", foo, system: true), appRoots: [apps]) == nil)
        for id in ["com.crowdstrike.falcon", "COM.CrowdStrike.Falcon", "com.jamf.protect", "com.cisco.secureclient.ui",
                   "local.airy.Airy", "LOCAL.AIRY.Airy", ""] {
            #expect(ProtectionWaiver.uninstall(record(id, "Foo Bar", foo), appRoots: [apps]) == nil, "\(id)")
        }
        // Depth 1 and 2 yes; 0, 3 or outside the roots, no.
        mkdir(apps + "/Utilidades")
        #expect(ProtectionWaiver.uninstall(fooApp, appRoots: [apps]) != nil)
        #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo", apps + "/Utilidades/Foo.app"),
                                           appRoots: [apps]) != nil)
        for path in [apps, apps + "/A/B/Foo.app", tmp + "/Otra/Foo.app", tmp + "/ApplicationsX/Foo.app",
                     apps + "/../Foo.app", apps + "/A/../../Foo.app", apps + "/./Foo.app", apps + "/Foo.app/",
                     apps + "/Foo", "Applications/Foo.app", h + "/Library/Application Support/Setapp/Applications/Foo.app"] {
            #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo", path), appRoots: [apps]) == nil, "\(path)")
        }
        #expect(ProtectionWaiver.productionAppRoots(home: "/Users/ana") == ["/Applications", "/Users/ana/Applications"])
        // What the waiver keeps.
        let waiver = ProtectionWaiver.uninstall(
            record("com.Example.Foo", "Foo Bar", foo, helpers: ["com.Example.Foo.Helper"]), appRoots: [apps])
        #expect(waiver?.bundlePath == RiskPolicy.canonical(foo))
        #expect(waiver?.bundleID == "com.Example.Foo")
        #expect(waiver?.ownedNames == ["com.example.foo", "com.example.foo.helper", "foo bar", "foobar", "foo_bar", "foo-bar"])
    }

    // MARK: - The app's data

    @Test func sensitiveDataWaivedOnlyForOwner() throws {
        let gate = gate()
        let slackFolder = support + "/Slack"
        let container = h + "/Library/Containers/com.tinyspeck.slackmacgap"
        touch(slackFolder + "/data")
        touch(container + "/Data/Documents/x")
        let slackPath = apps + "/Slack.app"
        makeBundle(slackPath, id: "com.tinyspeck.slackmacgap")
        let slack = try #require(ProtectionWaiver.uninstall(record("com.tinyspeck.slackmacgap", "Slack", slackPath),
                                                           appRoots: [apps]))
        let discord = try #require(ProtectionWaiver.uninstall(record("com.hnc.Discord", "Discord", apps + "/Discord.app"),
                                                             appRoots: [apps]))
        #expect(gate.validate(slackFolder, waiver: nil).failure?.reason == "Data of a sensitive app (Slack).")
        #expect(gate.validate(slackFolder, waiver: slack).failure == nil)
        #expect(gate.validate(container, waiver: slack).failure == nil)
        #expect(gate.validate(slackFolder, waiver: discord).failure != nil)
        #expect(gate.validate(container, waiver: discord).failure != nil)
        // Only the data folder itself; what is inside and its parents stay protected.
        #expect(gate.validate(slackFolder + "/data", waiver: slack).failure != nil)
        #expect(gate.validate(container + "/Data/Documents/x", waiver: slack).failure != nil)
        touch(slackFolder + "/Slack/x")                                             // inside, with the same name
        touch(container + "/Data/com.tinyspeck.slackmacgap/x")
        #expect(gate.validate(slackFolder + "/Slack", waiver: slack).failure != nil)
        #expect(gate.validate(container + "/Data/com.tinyspeck.slackmacgap", waiver: slack).failure != nil)
        #expect(gate.validate(support, waiver: slack).failure != nil)
        // A sensitive folder of another app with a name that only looks similar.
        touch(support + "/SlackHelperTool/x")
        #expect(gate.validate(support + "/SlackHelperTool", waiver: slack).failure != nil)
    }

    @Test func browserAndSignalProfilesProtected() throws {
        let gate = gate()
        let expected: [(String, String)] = [
            (support + "/Signal", "Signal"), (support + "/Firefox", "Firefox"), (support + "/Mozilla", "Mozilla"),
            (support + "/Vivaldi", "Vivaldi"), (support + "/Microsoft Edge", "Microsoft Edge"),
            (support + "/BraveSoftware", "Brave"), (support + "/Google", "Google"),
            (h + "/Library/Containers/org.mozilla.firefox", "Firefox"),
            (h + "/Library/Containers/com.microsoft.edgemac", "Microsoft Edge"),
            (h + "/Library/Containers/com.brave.Browser", "Brave"),
            (h + "/Library/Group Containers/group.org.whispersystems.signal-desktop", "Signal"),
        ]
        for (path, name) in expected {
            touch(path + "/Default/Cookies")
            #expect(gate.validate(path, waiver: nil).failure?.reason == "Data of a sensitive app (\(name)).", "\(path)")
            #expect(gate.validate(path + "/Default/Cookies", waiver: nil).failure != nil, "\(path)")
        }
        touch(support + "/Google/Chrome/Default/Login Data")
        touch(support + "/Firefox/Profiles/abc.default/logins.json")
        touch(support + "/BraveSoftware/Brave-Browser/Default/Cookies")
        for path in [support + "/Google/Chrome", support + "/Google/Chrome/Default/Login Data",
                     support + "/Firefox/Profiles/abc.default", support + "/BraveSoftware/Brave-Browser"] {
            #expect(gate.validate(path, waiver: nil).failure != nil, "\(path)")
        }
        // Only with its own app's waiver, and only the folder itself.
        let signal = try #require(ProtectionWaiver.uninstall(
            record("org.whispersystems.signal-desktop", "Signal", apps + "/Signal.app"), appRoots: [apps]))
        let firefox = try #require(ProtectionWaiver.uninstall(record("org.mozilla.firefox", "Firefox", apps + "/Firefox.app"),
                                                             appRoots: [apps]))
        let edge = try #require(ProtectionWaiver.uninstall(record("com.microsoft.edgemac", "Microsoft Edge",
                                                                  apps + "/Microsoft Edge.app"), appRoots: [apps]))
        #expect(gate.validate(support + "/Signal", waiver: signal).failure == nil)
        #expect(gate.validate(support + "/Firefox", waiver: firefox).failure == nil)
        #expect(gate.validate(support + "/Microsoft Edge", waiver: edge).failure == nil)
        #expect(gate.validate(h + "/Library/Containers/com.microsoft.edgemac", waiver: edge).failure == nil)
        #expect(gate.validate(support + "/Signal", waiver: firefox).failure != nil)
        #expect(gate.validate(support + "/Firefox", waiver: signal).failure != nil)
        #expect(gate.validate(support + "/Firefox/Profiles/abc.default", waiver: firefox).failure != nil)
        #expect(gate.validate(support + "/Mozilla", waiver: firefox).failure != nil)
        // The browsers' caches (outside the data roots, and the one the catalog declares) stay cleanable.
        for path in [h + "/Library/Caches/Google/Chrome/Default/Cache/data_0",
                     h + "/Library/Caches/Google/Chrome/Default/Code Cache/js/x",
                     h + "/Library/Caches/Google/Chrome/Default/GPUCache/x",
                     h + "/Library/Caches/BraveSoftware/Brave-Browser/Default/Cache/x",
                     h + "/Library/Caches/Firefox/Profiles/abc.default/cache2/x",
                     h + "/Library/Caches/com.microsoft.edgemac/x",
                     h + "/Library/Containers/com.microsoft.edgemac/Data/Library/Caches/x"] {
            touch(path)
            #expect(gate.validate(path, waiver: nil).failure == nil, "\(path)")
        }
        #expect(gate.validate(h + "/Library/Caches/Google/Chrome", waiver: nil).failure == nil)
    }

    /// M5: with the bundled catalog, profile data never gets through even if there are wildcard entries next to it.
    @Test func bundledCatalogNeverOpensProfileData() throws {
        let gate = gate()
        let paths = [support + "/Google/Chrome/Default", support + "/Google/Chrome/Default/Service Worker",
                     support + "/Google/Chrome/Default/History", support + "/Google/Chrome/Profile 1/Cookies",
                     support + "/BraveSoftware/Brave-Browser/Profile 1/Cookies",
                     support + "/BraveSoftware/Brave-Browser/Default/Login Data"]
        for path in paths {
            touch(path + "/x")
            #expect(gate.validate(path, waiver: nil).failure != nil, "\(path)")
        }
    }

    /// I2: Safari, Arc, Opera and Chromium, just like Chrome, Brave, Firefox, Vivaldi, Edge and Signal.
    @Test func moreBrowserProfilesProtectedAndTheirCachesStillAllowed() throws {
        let gate = gate()
        let containers = h + "/Library/Containers"
        let protected: [(String, String)] = [
            (h + "/Library/Safari", "Safari"), (h + "/Library/Safari/Bookmarks.plist", "Safari"),
            (h + "/Library/Safari/LastSession.plist", "Safari"),
            (containers + "/com.apple.Safari", "Safari"), (containers + "/com.apple.Safari/Data/Library/Safari", "Safari"),
            (support + "/Arc", "Arc"), (support + "/Arc/User Data", "Arc"), (support + "/Arc/User Data/Default", "Arc"),
            (support + "/Arc/User Data/Default/Cookies", "Arc"), (support + "/Arc/User Data/Profile 1/History", "Arc"),
            (containers + "/company.thebrowser.Browser", "Arc"),
            (support + "/com.operasoftware.Opera", "Opera"), (support + "/com.operasoftware.Opera/Cookies", "Opera"),
            (support + "/com.operasoftware.Opera/Login Data", "Opera"),
            (support + "/Chromium", "Chromium"), (support + "/Chromium/Default", "Chromium"),
            (support + "/Chromium/Default/Login Data", "Chromium"),
            (support + "/Chromium/Default/Service Worker", "Chromium"),
        ]
        for (path, name) in protected {
            touch(path + "/x")
            #expect(gate.validate(path, waiver: nil).failure?.reason == "Data of a sensitive app (\(name)).", "\(path)")
        }
        // History.db: never to the Trash (it belongs to an official command and lives in ~/Library/Safari).
        touch(h + "/Library/Safari/History.db")
        #expect(gate.validate(h + "/Library/Safari/History.db", waiver: nil).failure != nil)
        // But it does as the `{target}` of its own entry (`sqlite3 … VACUUM`), and only that path.
        let bundled = try Catalog.bundled()
        let compact = try #require(bundled.entry(id: "safari-compact"))
        let targetGate = PathGate(home: h, catalog: Catalog(entries: bundled.entries.filter { $0.id != compact.id }),
                                  userProtected: ProtectList(patterns: [], home: h),
                                  protections: HardProtections(criticalRoots: [], sealedSystemLocations: [apps]),
                                  commandTarget: compact)
        #expect(targetGate.validate(h + "/Library/Safari/History.db").failure == nil)
        #expect(targetGate.validate(h + "/Library/Safari/Bookmarks.plist").failure != nil)
        #expect(targetGate.validate(h + "/Library/Safari").failure != nil)
        // The caches the catalog declares (literal and per profile) stay cleanable.
        for path in [support + "/Arc/User Data/Cache/x", support + "/Arc/User Data/Default/Cache/x",
                     support + "/Arc/User Data/Profile 1/Code Cache/js/x",
                     support + "/Arc/User Data/Default/Service Worker/CacheStorage/x",
                     support + "/com.operasoftware.Opera/Cache/x", support + "/com.operasoftware.Opera/GPUCache/x",
                     support + "/com.operasoftware.Opera/Profile 2/Code Cache/x",
                     support + "/Chromium/Default/GPUCache/x", support + "/Chromium/Profile 1/Cache/x",
                     support + "/Chromium/ShaderCache/x",
                     containers + "/com.apple.Safari/Data/Library/Caches/x",
                     containers + "/company.thebrowser.Browser/Data/Library/Caches/x",
                     h + "/Library/Caches/com.apple.Safari/x", h + "/Library/Caches/company.thebrowser.Browser/x",
                     h + "/Library/Caches/com.operasoftware.Opera/x", h + "/Library/Caches/Chromium/x"] {
            touch(path)
            #expect(gate.validate(path, waiver: nil).failure == nil, "\(path)")
        }
    }

    @Test func sealedHomeNeverWaived() throws {
        let gate = gate()
        let docker = h + "/Library/Containers/com.docker.docker"
        let group = h + "/Library/Group Containers/group.com.docker"
        touch(docker + "/Data/x")
        touch(group + "/x")
        touch(h + "/.ssh/id_ed25519")
        let waiver = try #require(ProtectionWaiver.uninstall(
            record("com.docker.docker", "Docker", apps + "/Docker.app", helpers: ["group.com.docker"]), appRoots: [apps]))
        #expect(waiver.ownedNames.contains("com.docker.docker"))
        mkdir(h + "/Applications")
        for path in [docker, group, h + "/.ssh", h + "/Library/Containers", h, h + "/Applications"] {
            #expect(gate.validate(path, waiver: waiver).failure != nil, "\(path)")
        }
        // Not even with an app that claims to be named like the folder.
        let ssh = try #require(ProtectionWaiver.uninstall(record(".ssh", ".ssh tool", apps + "/SSH.app"), appRoots: [apps]))
        #expect(gate.validate(h + "/.ssh", waiver: ssh).failure != nil)
    }

    @Test func fragmentDataNeverWaived() throws {
        let gate = gate()
        let data = support + "/1Password"
        touch(data + "/x")
        touch(h + "/Library/Group Containers/2BUA8C4S2C.com.1password/x")
        touch(support + "/KeychainSync/x")
        let waiver = try #require(ProtectionWaiver.uninstall(
            record("com.1password.1password", "1Password", apps + "/1Password.app",
                   helpers: ["2BUA8C4S2C.com.1password"]), appRoots: [apps]))
        #expect(gate.validate(data, waiver: waiver).failure != nil)
        #expect(gate.validate(h + "/Library/Group Containers/2BUA8C4S2C.com.1password", waiver: waiver).failure != nil)
        let keychain = try #require(ProtectionWaiver.uninstall(record("com.example.keychainsync", "KeychainSync",
                                                                     apps + "/KeychainSync.app"), appRoots: [apps]))
        #expect(gate.validate(support + "/KeychainSync", waiver: keychain).failure != nil)
    }

    @Test func userProtectedNeverWaived() throws {
        let slackFolder = support + "/Slack"
        touch(slackFolder + "/x")
        let slack = try #require(ProtectionWaiver.uninstall(record("com.tinyspeck.slackmacgap", "Slack", apps + "/Slack.app"),
                                                           appRoots: [apps]))
        let waiver = try #require(fooWaiver)
        let gate = gate(protected: [foo, "~/Library/Application Support/Slack"])
        #expect(gate.validate(foo, waiver: waiver).failure?.reason.hasPrefix("You protected it") == true)
        #expect(gate.validate(slackFolder, waiver: slack).failure?.reason.hasPrefix("You protected it") == true)
        // Protecting the whole apps folder also protects the app.
        #expect(self.gate(protected: [apps]).validate(foo, waiver: waiver).failure?.reason.hasPrefix("You protected it") == true)
    }

    @Test func plainLeftoversUnaffectedByWaiver() throws {
        let gate = gate()
        let cache = h + "/Library/Caches/com.example.foo"
        mkdir(cache)
        let waiver = try #require(fooWaiver)
        #expect(gate.validate(cache, waiver: nil).failure == nil)
        #expect(gate.validate(cache, waiver: waiver).failure == nil)
        #expect(gate.validate(h + "/Library/Caches", waiver: waiver).failure != nil)
    }

    // MARK: - match == matches.first

    @Test func matchIsFirstOfMatches() {
        let home = "/Users/ana"
        let a = home + "/Library/Application Support"
        let paths = [
            "/", "/usr", "/USR/bin", "/applications", "/Applications/Foo.app", "/System/Library", "/private/var/folders",
            "/Users", "/Users/Shared", home, home + "/Library/Mail/x", home + "/Library/Keychains/x", home + "/.ssh/id",
            a + "/1Password/data", a + "/Claude/vm_bundles", a + "/Claude/otra", a + "/Code/User/x", a + "/Normal App/x",
            home + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x",
            home + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Documents/x",
            home + "/Library/Caches/com.apple.FontRegistry", home + "/Library/Caches/com.crowdstrike.x",
            home + "/Library/Containers/com.agilebits.onepassword7/Data/x", home + "/Documents", home + "/Library",
            home + "/.cache/codex-runtimes", home + "/Library/Caches/com.example.app",
        ]
        let catalog = try? Catalog.bundled()
        for protections in [HardProtections.standard, HardProtections(criticalRoots: [], sealedSystemLocations: ["/Applications"])] {
            for path in paths {
                let all = protections.matches(canonicalPath: path, home: home, catalog: catalog)
                let first = protections.match(canonicalPath: path, home: home, catalog: catalog)
                #expect(first == all.first, "\(path)")
                #expect(first?.rule == all.first?.rule, "\(path)")
            }
        }
        let rules: (String) -> [ProtectionMatch.Rule] = { path in
            HardProtections.standard.matches(canonicalPath: path, home: home, catalog: catalog).map(\.rule)
        }
        #expect(rules("/usr") == [.critical, .sealedSystem])
        #expect(rules("/Applications/Foo.app") == [.sealedSystem])
        #expect(rules("/Applications/1Password.app") == [.sealedSystem, .fragment])
        #expect(rules(home + "/Library/Mail/x") == [.sealedHome])
        #expect(rules(home + "/Documents") == [.upward])
        #expect(rules(a + "/1Password/data") == [.sensitiveAppData, .fragment])
        #expect(rules(a + "/Slack") == [.sensitiveAppData])
        #expect(rules(home + "/Library/Caches/com.example.app").isEmpty)
    }
}
