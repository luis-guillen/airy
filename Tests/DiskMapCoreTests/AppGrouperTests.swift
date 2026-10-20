import Foundation
import Testing
@testable import DiskMapCore

@Suite struct AppGrouperTests {
    static let mb: Int64 = 1 << 20
    static let chromeApp = "/Applications/Google Chrome.app"
    static let chromeExe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

    static let catalog = AppCatalog(entries: [
        AppCatalogEntry(id: "chrome", title: "Google Chrome",
                        explanation: "Navegador de Google; cada pestaña y extensión es un proceso aparte, por eso suma tanto.",
                        bundleIDs: ["com.google.Chrome"], processNames: []),
        AppCatalogEntry(id: "node", title: "Node.js", explanation: "Programa de JavaScript.",
                        bundleIDs: [], processNames: ["node"]),
    ])

    func raw(_ processes: [OwnProcess], apps: [RunningAppInfo] = [], cores: Int = 4, total: Int64 = 16 << 30) -> RawSample {
        RawSample(date: Date(timeIntervalSince1970: 1_000), uptimeNs: 1,
                  memory: MemoryStats(total: total),
                  cores: Array(repeating: CoreTicks(user: 0, system: 0, idle: 0), count: cores),
                  processes: processes, apps: apps)
    }

    func chromeRaw() -> RawSample {
        raw([OwnProcess(pid: 10, name: "Google Chrome", executablePath: Self.chromeExe, footprint: 300 * Self.mb),
             OwnProcess(pid: 11, ppid: 10, name: "Google Chrome Helper", executablePath: Self.chromeHelper, footprint: 700 * Self.mb)],
            apps: [RunningAppInfo(pid: 10, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: Self.chromeApp, policy: .regular)])
    }

    @Test func helpersCountAsTheirApp() {
        let g = AppGrouper.group(chromeRaw(), cpu: [10: 5, 11: 20], energy: [:], catalog: Self.catalog)
        #expect(g.count == 1 && g[0].name == "Google Chrome" && g[0].memory == 1_000 << 20)
        #expect(g[0].cpuPercent == 25 && g[0].leadPID == 10 && g[0].pids.sorted() == [10, 11])
        #expect(g[0].kind == .app && g[0].bundleID == "com.google.Chrome" && g[0].id == "com.google.Chrome")
        #expect(g[0].explanation?.hasPrefix("Navegador de Google") == true)
        #expect(g[0].energy == nil)
    }

    @Test func outermostBundleOfNestedHelper() {
        #expect(AppGrouper.outermostBundle(Self.chromeHelper) == Self.chromeApp)
        #expect(AppGrouper.outermostBundle(Self.chromeExe) == Self.chromeApp)
        #expect(AppGrouper.outermostBundle("/opt/homebrew/bin/node") == nil)
        #expect(AppGrouper.outermostBundle(nil) == nil)
    }

    @Test func looseNodeShowsProjectFolder() {
        let p = OwnProcess(pid: 50, name: "node", executablePath: "/opt/homebrew/bin/node", footprint: 80 * Self.mb,
                           workingDirectory: "/Users/x/Proyectos/mi-api")
        let g = AppGrouper.group(raw([p]), cpu: [:], energy: [:], catalog: Self.catalog)
        #expect(g.count == 1 && g[0].kind == .looseProcess && g[0].detail == "mi-api")
        #expect(g[0].id == "pid:50:0" && g[0].explanation == "Programa de JavaScript.")
    }

    @Test func looseInHomeOrRootHasNoDetail() {
        let inHome = OwnProcess(pid: 51, name: "tool", executablePath: "/opt/homebrew/bin/tool", workingDirectory: NSHomeDirectory())
        let inRoot = OwnProcess(pid: 52, name: "tool", executablePath: "/opt/homebrew/bin/tool", workingDirectory: "/")
        let g = AppGrouper.group(raw([inHome, inRoot]), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 2)
        #expect(g.allSatisfy { $0.kind == .looseProcess && $0.detail == nil })
    }

    @Test func systemPathsAreSystem() {
        let a = OwnProcess(pid: 60, name: "x", executablePath: "/usr/libexec/x", footprint: 10 * Self.mb)
        let b = OwnProcess(pid: 61, name: "mds", executablePath: "/System/Library/Frameworks/CoreServices.framework/mds", footprint: 20 * Self.mb)
        let c = OwnProcess(pid: 62, name: "mds", executablePath: "/System/Library/Frameworks/CoreServices.framework/mds", footprint: 30 * Self.mb)
        let g = AppGrouper.group(raw([a, b, c]), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 2 && g.allSatisfy { $0.kind == .system })
        #expect(g.first { $0.name == "mds" }?.pids.sorted() == [61, 62])
    }

    @Test func systemBundleWithoutRegularAppIsSystem() {
        let p = OwnProcess(pid: 63, name: "Dock", executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
        let g = AppGrouper.group(raw([p], apps: [RunningAppInfo(pid: 63, bundleID: "com.apple.dock", name: "Dock",
                                                               bundlePath: "/System/Library/CoreServices/Dock.app", policy: .accessory)]),
                                 cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 1 && g[0].kind == .system)
    }

    @Test func backgroundAgentIsNotAnApp() {
        let path = "/Users/x/Library/Application Support/Foo/Helper.app"
        let p = OwnProcess(pid: 70, name: "Helper", executablePath: path + "/Contents/MacOS/Helper", footprint: 5 * Self.mb)
        let withApp = AppGrouper.group(
            raw([p], apps: [RunningAppInfo(pid: 70, bundleID: "com.foo.helper", name: "Foo Helper", bundlePath: path, policy: .prohibited)]),
            cpu: [:], energy: [:], catalog: nil)
        #expect(withApp[0].kind == .background && withApp[0].name == "Foo Helper")
        let noApp = AppGrouper.group(raw([p]), cpu: [:], energy: [:], catalog: nil)
        #expect(noApp[0].kind == .background && noApp[0].name == "Helper" && noApp[0].id == "bundle:" + path)
    }

    @Test func zombiesAreNotGrouped() {
        let z = OwnProcess(pid: 80, name: "zzz", executablePath: "/opt/homebrew/bin/zzz", isZombie: true)
        #expect(AppGrouper.group(raw([z]), cpu: [:], energy: [:], catalog: nil).isEmpty)
    }

    @Test func sortedByImpact() {
        let big = OwnProcess(pid: 90, name: "big", executablePath: "/opt/big", footprint: 2 << 30)
        let busy = OwnProcess(pid: 91, name: "busy", executablePath: "/opt/busy", footprint: 100 * Self.mb)
        let g = AppGrouper.group(raw([big, busy], cores: 4), cpu: [91: 400], energy: [:], catalog: nil)
        #expect(g.map(\.name) == ["busy", "big"])
    }

    @Test func twoInstancesOfOneBundleAreSeparateGroups() {
        let app = "/Applications/TextEdit.app"
        let exe = app + "/Contents/MacOS/TextEdit"
        let helper = app + "/Contents/XPCServices/H.xpc/Contents/MacOS/H"
        let procs = [OwnProcess(pid: 200, name: "TextEdit", executablePath: exe, footprint: 10 * Self.mb),
                     OwnProcess(pid: 300, name: "TextEdit", executablePath: exe, footprint: 20 * Self.mb),
                     OwnProcess(pid: 301, name: "H", executablePath: helper, footprint: 5 * Self.mb)]
        let apps = [RunningAppInfo(pid: 200, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: app),
                    RunningAppInfo(pid: 300, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: app)]
        let g = AppGrouper.group(raw(procs, apps: apps), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 2)
        #expect(Set(g.map(\.id)) == ["com.apple.TextEdit#200", "com.apple.TextEdit#300"])
        #expect(g.first { $0.leadPID == 200 }?.pids.sorted() == [200, 301])
        #expect(g.first { $0.leadPID == 300 }?.pids == [300])
    }

    @Test func sameBundleIDFromTwoPathsGetsDistinctIDs() {
        let a = "/Applications/TextEdit.app", b = "/Users/x/Downloads/TextEdit.app"
        let procs = [OwnProcess(pid: 400, name: "TextEdit", executablePath: a + "/Contents/MacOS/TextEdit"),
                     OwnProcess(pid: 500, name: "TextEdit", executablePath: b + "/Contents/MacOS/TextEdit")]
        let apps = [RunningAppInfo(pid: 400, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: a),
                    RunningAppInfo(pid: 500, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: b)]
        let g = AppGrouper.group(raw(procs, apps: apps), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 2)
        #expect(Set(g.map(\.id)) == ["com.apple.TextEdit#400", "com.apple.TextEdit#500"])
        #expect(g.first { $0.leadPID == 400 }?.bundlePath == a)
        // Una sola instancia conserva el id sin calificar.
        let one = AppGrouper.group(raw([procs[0]], apps: [apps[0]]), cpu: [:], energy: [:], catalog: nil)
        #expect(one.map(\.id) == ["com.apple.TextEdit"])
    }

    @Test func unknownExecutablePathIsNeverLoose() {
        let p = OwnProcess(pid: 600, name: "misterio", executablePath: nil, footprint: 50 * Self.mb)
        let g = AppGrouper.group(raw([p]), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 1 && g[0].kind == .system)
        #expect(!QuitPolicy(currentUID: g[0].uid, ownPIDs: []).eligibility(g[0]).isAllowed)
    }

    @Test func bundledAppCatalogHasRequiredIDs() throws {
        let catalog = try AppCatalog.bundled(executableURL: nil, searchProcessBundles: true)
        let ids = ["chrome", "safari", "firefox", "brave", "edge", "arc", "slack", "discord", "teams", "zoom", "spotify",
                   "docker-desktop", "vscode", "cursor", "xcode", "simulator", "figma", "photoshop", "premiere",
                   "final-cut", "notion", "whatsapp", "telegram", "claude", "chatgpt", "ollama", "lm-studio", "node",
                   "python", "ruby", "java", "bun", "deno", "postgres", "redis", "webkit-content", "windowserver",
                   "spotlight", "syspolicyd", "kernel-task"]
        #expect(ids.count == 40)
        for id in ids {
            let e = catalog.entries.first { $0.id == id }
            #expect(e != nil, "falta \(id)")
            #expect(e.map { !$0.explanation.isEmpty && !$0.explanation.contains("\n") } == true, "explicación de \(id)")
        }
        #expect(catalog.entry(bundleID: "com.google.Chrome", processName: "x")?.id == "chrome")
        #expect(catalog.entry(bundleID: "com.docker.docker", processName: "x")?.id == "docker-desktop")
        #expect(catalog.entry(bundleID: nil, processName: "Python3")?.id == "python")
        #expect(catalog.entry(bundleID: nil, processName: "mdworker_shared")?.id == "spotlight")
        #expect(catalog.entry(bundleID: nil, processName: "redis-server")?.id == "redis")
        #expect(catalog.entry(bundleID: nil, processName: "nada") == nil)
        #expect(catalog.entry(bundleID: nil, processName: "node")?.explanation.hasPrefix("Programa de JavaScript") == true)
    }
}
