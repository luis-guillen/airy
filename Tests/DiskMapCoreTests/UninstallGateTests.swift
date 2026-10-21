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

/// `.app` falso con su `Contents/Info.plist` y un ejecutable.
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

    // MARK: - El `.app` exacto

    @Test func bundlePassesOnlyWithItsOwnWaiver() throws {
        let gate = gate()
        makeBundle(apps + "/Other.app", id: "com.example.other")
        #expect(gate.validate(foo, waiver: nil).failure != nil)
        #expect(gate.validate(foo).failure != nil)                                  // validate(_:) == waiver nil
        let waiver = try #require(fooWaiver)
        let validated = try gate.validate(foo, waiver: waiver).get()
        #expect(validated.path == foo)
        #expect(gate.confirmUnchanged(validated) == nil)
        // Otra app, la carpeta de apps y lo de dentro del `.app`: nunca cuentan como el `.app`.
        for path in [apps + "/Other.app", apps, foo + "/Contents", foo + "/Contents/Info.plist",
                     foo + "/Contents/MacOS/Foo"] {
            #expect(gate.validate(path, waiver: waiver).failure != nil, "\(path)")
        }
        // La dispensa de la otra app tampoco abre Foo.
        let other = try #require(ProtectionWaiver.uninstall(record("com.example.other", "Other", apps + "/Other.app"),
                                                            appRoots: [apps]))
        #expect(gate.validate(foo, waiver: other).failure != nil)
        #expect(gate.validate(apps + "/Other.app", waiver: other).failure == nil)
    }

    @Test func caseVariantsAndTraversalOfTheBundleRefused() throws {
        let gate = gate()
        let waiver = try #require(fooWaiver)
        // En APFS sin mayúsculas son el mismo archivo, pero no es la ruta elegida: se aplica la lista dura entera.
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
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
        writeInfoPlist(foo, id: "COM.EXAMPLE.FOO")                                  // ni en otra caja
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
        try FileManager.default.removeItem(atPath: foo + "/Contents/Info.plist")    // sin Info.plist
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
        try Data("no es un plist".utf8).write(to: URL(fileURLWithPath: foo + "/Contents/Info.plist"))
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
    }

    @Test func symlinkBundleRefused() throws {
        let gate = gate()
        // Un enlace con forma de `.app` que apunta a la app de verdad.
        try FileManager.default.createSymbolicLink(atPath: apps + "/Link.app", withDestinationPath: foo)
        let linkWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.foo", "Foo Bar", apps + "/Link.app"),
                                                                appRoots: [apps]))
        #expect(gate.validate(apps + "/Link.app", waiver: linkWaiver).failure?.reason == "Ya no es la app que elegiste.")
        // Un enlace a otra carpeta protegida, con un Info.plist falso dentro del destino.
        let keychains = h + "/Library/Keychains/Evil.app"
        makeBundle(keychains, id: "com.example.evil")
        try FileManager.default.createSymbolicLink(atPath: apps + "/Evil.app", withDestinationPath: keychains)
        let evil = try #require(ProtectionWaiver.uninstall(record("com.example.evil", "Evil", apps + "/Evil.app"),
                                                          appRoots: [apps]))
        #expect(gate.validate(apps + "/Evil.app", waiver: evil).failure != nil)
        // La app elegida se cambia por un enlace después de crear la dispensa.
        let waiver = try #require(fooWaiver)
        try FileManager.default.moveItem(atPath: foo, toPath: apps + "/Real.app")
        try FileManager.default.createSymbolicLink(atPath: foo, withDestinationPath: apps + "/Real.app")
        #expect(gate.validate(foo, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
    }

    @Test func onlyTheAppRootSealIsWaived() throws {
        // Una raíz de apps dentro de otra ubicación sellada: el sello de fuera no se dispensa.
        let system = tmp + "/System"
        let inner = system + "/Applications/Calc.app"
        makeBundle(inner, id: "com.example.calc")
        let gate = PathGate(home: h, catalog: nil, userProtected: ProtectList(patterns: [], home: h),
                            protections: HardProtections(criticalRoots: [], sealedSystemLocations: [apps, system]))
        let waiver = try #require(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", inner),
                                                            appRoots: [system + "/Applications"]))
        #expect(gate.validate(inner, waiver: waiver).failure?.reason == "Ubicación protegida por Airy: \(system).")
        // Y la raíz «/» nunca vale como raíz de apps.
        #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo", foo), appRoots: ["/"]) == nil)
    }

    @Test func onlyApplicationsRootsAccepted() {
        // Una raíz que no se llama «Applications» nunca da dispensa, aunque la app cuelgue de ella.
        for (root, path) in [("/Library", "/Library/X.app"), ("/usr", "/usr/X.app"), ("/opt/homebrew", "/opt/homebrew/X.app"),
                             ("/private", "/private/X.app"), ("/System", "/System/X.app"), ("/", "/X.app"),
                             (h + "/Library/Keychains", h + "/Library/Keychains/X.app"), (tmp + "/Apps", tmp + "/Apps/X.app"),
                             ("/Applications/Utilities", "/Applications/Utilities/A/B/X.app")] {
            #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", path), appRoots: [root]) == nil, "\(root)")
        }
        // Mayúsculas aparte, «Applications» sí vale (y la de producción).
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", tmp + "/APPLICATIONS/Foo.app"),
                                           appRoots: [tmp + "/APPLICATIONS"]) != nil)
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", foo),
                                           appRoots: ["/Library", "/usr", apps]) != nil)
    }

    @Test func libraryRootNeverOpensItsSeal() throws {
        // Aunque alguien llamara «Applications» a una carpeta dentro de un sello del sistema, solo el sello
        // cuyo patrón es la raíz de apps se dispensa; el de fuera sigue rechazando.
        let lib = tmp + "/Library"
        let inner = lib + "/Applications/X.app"
        makeBundle(inner, id: "com.example.x")
        let gate = PathGate(home: h, catalog: nil, userProtected: ProtectList(patterns: [], home: h),
                            protections: HardProtections(criticalRoots: [], sealedSystemLocations: [lib]))
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", inner), appRoots: [lib]) == nil)
        let waiver = try #require(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", inner),
                                                            appRoots: [lib + "/Applications"]))
        #expect(gate.validate(inner, waiver: waiver).failure?.reason == "Ubicación protegida por Airy: \(lib).")
    }

    @Test func systemnessRecomputedNotTrusted() throws {
        // `isSystem: false` del llamante no basta: un enlace hacia /System se resuelve y se rechaza.
        let calculator = "/System/Applications/Calculator.app"
        if FileManager.default.fileExists(atPath: calculator) {
            try FileManager.default.createSymbolicLink(atPath: apps + "/Calc.app", withDestinationPath: calculator)
            #expect(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", apps + "/Calc.app"), appRoots: [apps]) == nil)
        } else {
            Issue.record("No hay \(calculator) para probar el enlace hacia /System.")
        }
        // Carpeta de apps enlazada dentro de /System.
        try FileManager.default.createSymbolicLink(atPath: tmp + "/SysLink", withDestinationPath: "/System")
        #expect(ProtectionWaiver.uninstall(record("com.example.calc", "Calc", tmp + "/SysLink/Applications/Calculator.app"),
                                           appRoots: [tmp + "/SysLink/Applications"]) == nil)
        // Identificador imprescindible del sistema, en el registro o en el disco.
        #expect(ProtectionWaiver.uninstall(record("com.apple.Finder", "Finder", apps + "/Finder.app"), appRoots: [apps]) == nil)
        makeBundle(apps + "/Fake.app", id: "com.apple.Safari")
        #expect(ProtectionWaiver.uninstall(record("com.example.fake", "Fake", apps + "/Fake.app"), appRoots: [apps]) == nil)
        makeBundle(apps + "/Falcon.app", id: "com.crowdstrike.falcon")
        #expect(ProtectionWaiver.uninstall(record("com.example.falcon", "Falcon", apps + "/Falcon.app"), appRoots: [apps]) == nil)
        // Ni sin carpeta padre resoluble.
        #expect(ProtectionWaiver.uninstall(record("com.example.x", "Xenon", tmp + "/Nada/Applications/X.app"),
                                           appRoots: [tmp + "/Nada/Applications"]) == nil)
    }

    @Test func wrappedIOSAppPassesWithItsWaiver() throws {
        // App de iOS/iPadOS: sin Contents/Info.plist; el identificador está en Wrapper/<nombre>.app/Info.plist.
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
        #expect(gate.validate(wrapped, waiver: waiver).failure?.reason == "Ya no es la app que elegiste.")
    }

    @Test func criticalRootNeverWaived() throws {
        let waiver = try #require(fooWaiver)
        #expect(gate(criticalRoots: [foo]).validate(foo, waiver: waiver).failure != nil)
        // Solo por el texto (la raíz no existía al crear el embudo, así que su inodo no está registrado).
        let late = apps + "/Late.app"
        let lateGate = gate(criticalRoots: [late])
        makeBundle(late, id: "com.example.late")
        let lateWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.late", "Late", late), appRoots: [apps]))
        #expect(lateGate.validate(late, waiver: lateWaiver).failure?.reason == "Carpeta crítica del sistema.")
        // Una «raíz de apps» dentro de una ubicación sellada del home: el sello del home no se dispensa.
        let keychainApp = h + "/Library/Keychains/Applications/Evil.app"
        makeBundle(keychainApp, id: "com.example.evil")
        let keychainWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.evil", "Evil", keychainApp),
                                                                    appRoots: [h + "/Library/Keychains/Applications"]))
        #expect(gate().validate(keychainApp, waiver: keychainWaiver).failure?.reason
            == "Ubicación protegida por Airy: Llaveros.")
        // La lista dura real: /Applications/Safari.app es raíz crítica, con o sin dispensa.
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
        // El nombre del `.app` contiene un fragmento (1password): se puede desinstalar con su dispensa.
        let onePassword = apps + "/1Password.app"
        makeBundle(onePassword, id: "com.1password.1password")
        let opWaiver = try #require(ProtectionWaiver.uninstall(record("com.1password.1password", "1Password", onePassword),
                                                              appRoots: [apps]))
        #expect(gate.validate(onePassword, waiver: nil).failure != nil)
        #expect(gate.validate(onePassword, waiver: opWaiver).failure == nil)
        // El fragmento en una carpeta superior no se dispensa (aunque el nombre del `.app` también lo tenga).
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

    // MARK: - Quién puede tener dispensa

    @Test func noWaiverForSystemOfficialUninstallerOrAiry() {
        #expect(ProtectionWaiver.uninstall(record("com.example.foo", "Foo Bar", foo, system: true), appRoots: [apps]) == nil)
        for id in ["com.crowdstrike.falcon", "COM.CrowdStrike.Falcon", "com.jamf.protect", "com.cisco.secureclient.ui",
                   "local.airy.Airy", "LOCAL.AIRY.Airy", ""] {
            #expect(ProtectionWaiver.uninstall(record(id, "Foo Bar", foo), appRoots: [apps]) == nil, "\(id)")
        }
        // Profundidad 1 y 2 sí; 0, 3 o fuera de las raíces, no.
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
        // Lo que guarda la dispensa.
        let waiver = ProtectionWaiver.uninstall(
            record("com.Example.Foo", "Foo Bar", foo, helpers: ["com.Example.Foo.Helper"]), appRoots: [apps])
        #expect(waiver?.bundlePath == RiskPolicy.canonical(foo))
        #expect(waiver?.bundleID == "com.Example.Foo")
        #expect(waiver?.ownedNames == ["com.example.foo", "com.example.foo.helper", "foo bar", "foobar", "foo_bar", "foo-bar"])
    }

    // MARK: - Datos de la app

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
        #expect(gate.validate(slackFolder, waiver: nil).failure?.reason == "Datos de una app sensible (Slack).")
        #expect(gate.validate(slackFolder, waiver: slack).failure == nil)
        #expect(gate.validate(container, waiver: slack).failure == nil)
        #expect(gate.validate(slackFolder, waiver: discord).failure != nil)
        #expect(gate.validate(container, waiver: discord).failure != nil)
        // Solo la carpeta de datos en sí; lo de dentro y sus superiores siguen protegidos.
        #expect(gate.validate(slackFolder + "/data", waiver: slack).failure != nil)
        #expect(gate.validate(container + "/Data/Documents/x", waiver: slack).failure != nil)
        touch(slackFolder + "/Slack/x")                                             // dentro, con el mismo nombre
        touch(container + "/Data/com.tinyspeck.slackmacgap/x")
        #expect(gate.validate(slackFolder + "/Slack", waiver: slack).failure != nil)
        #expect(gate.validate(container + "/Data/com.tinyspeck.slackmacgap", waiver: slack).failure != nil)
        #expect(gate.validate(support, waiver: slack).failure != nil)
        // Una carpeta sensible de otra app con un nombre que solo se parece.
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
            #expect(gate.validate(path, waiver: nil).failure?.reason == "Datos de una app sensible (\(name)).", "\(path)")
            #expect(gate.validate(path + "/Default/Cookies", waiver: nil).failure != nil, "\(path)")
        }
        touch(support + "/Google/Chrome/Default/Login Data")
        touch(support + "/Firefox/Profiles/abc.default/logins.json")
        touch(support + "/BraveSoftware/Brave-Browser/Default/Cookies")
        for path in [support + "/Google/Chrome", support + "/Google/Chrome/Default/Login Data",
                     support + "/Firefox/Profiles/abc.default", support + "/BraveSoftware/Brave-Browser"] {
            #expect(gate.validate(path, waiver: nil).failure != nil, "\(path)")
        }
        // Solo con la dispensa de su propia app, y solo la carpeta en sí.
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
        // Las cachés de los navegadores (fuera de las raíces de datos, y la que declara el catálogo) siguen limpiables.
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

    /// M5: con el catálogo incluido, los datos de perfil nunca pasan aunque haya fichas con comodín al lado.
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

    /// I2: Safari, Arc, Opera y Chromium, igual que Chrome, Brave, Firefox, Vivaldi, Edge y Signal.
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
            #expect(gate.validate(path, waiver: nil).failure?.reason == "Datos de una app sensible (\(name)).", "\(path)")
        }
        // History.db: nunca a la Papelera (es de un comando oficial y está en ~/Library/Safari).
        touch(h + "/Library/Safari/History.db")
        #expect(gate.validate(h + "/Library/Safari/History.db", waiver: nil).failure != nil)
        // Pero sí como `{target}` de su propia ficha (`sqlite3 … VACUUM`), y solo esa ruta.
        let bundled = try Catalog.bundled()
        let compact = try #require(bundled.entry(id: "safari-compact"))
        let targetGate = PathGate(home: h, catalog: Catalog(entries: bundled.entries.filter { $0.id != compact.id }),
                                  userProtected: ProtectList(patterns: [], home: h),
                                  protections: HardProtections(criticalRoots: [], sealedSystemLocations: [apps]),
                                  commandTarget: compact)
        #expect(targetGate.validate(h + "/Library/Safari/History.db").failure == nil)
        #expect(targetGate.validate(h + "/Library/Safari/Bookmarks.plist").failure != nil)
        #expect(targetGate.validate(h + "/Library/Safari").failure != nil)
        // Las cachés que declara el catálogo (literales y por perfil) siguen limpiables.
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
        // Ni con una app que diga llamarse como la carpeta.
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
        #expect(gate.validate(foo, waiver: waiver).failure?.reason.hasPrefix("Lo has protegido tú") == true)
        #expect(gate.validate(slackFolder, waiver: slack).failure?.reason.hasPrefix("Lo has protegido tú") == true)
        // Proteger la carpeta de apps entera también protege la app.
        #expect(self.gate(protected: [apps]).validate(foo, waiver: waiver).failure?.reason.hasPrefix("Lo has protegido tú") == true)
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
