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
        let keychainApp = h + "/Library/Keychains/Evil.app"
        makeBundle(keychainApp, id: "com.example.evil")
        let keychainWaiver = try #require(ProtectionWaiver.uninstall(record("com.example.evil", "Evil", keychainApp),
                                                                    appRoots: [h + "/Library/Keychains"]))
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
