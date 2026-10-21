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
                        explanation: "Google's browser; each tab and extension is a separate process, which is why it adds up so much.",
                        bundleIDs: ["com.google.Chrome"], processNames: []),
        AppCatalogEntry(id: "node", title: "Node.js", explanation: "A JavaScript program.",
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
        #expect(g[0].explanation?.hasPrefix("Google's browser") == true)
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
        #expect(g[0].id == "pid:50:0" && g[0].explanation == "A JavaScript program.")
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
        // A single instance keeps the unqualified id.
        let one = AppGrouper.group(raw([procs[0]], apps: [apps[0]]), cpu: [:], energy: [:], catalog: nil)
        #expect(one.map(\.id) == ["com.apple.TextEdit"])
    }

    @Test func unknownExecutablePathIsNeverLoose() {
        let p = OwnProcess(pid: 600, name: "misterio", executablePath: nil, footprint: 50 * Self.mb)
        let g = AppGrouper.group(raw([p]), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 1 && g[0].kind == .system)
        #expect(!QuitPolicy(currentUID: g[0].uid, ownPIDs: []).eligibility(g[0]).isAllowed)
    }

    @Test func friendlyNamesForTruncatedVersionedAndDockerVM() {
        let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        let claude = OwnProcess(pid: 30, name: "2.1.304", executablePath: "/Users/u/.local/share/claude/versions/2.1.304")
        let catalog = AppCatalog(entries: [AppCatalogEntry(id: "claude-code", title: "Claude Code", explanation: "",
                                                           processNames: ["claude"])])
        #expect(AppGrouper.friendlyName(claude, catalog: catalog) == "Claude Code")
        #expect(AppGrouper.friendlyName(claude, catalog: nil) == "claude")
        let vm = OwnProcess(pid: 31, name: "com.apple.Virtualization.Virtua", executablePath: vmPath, footprint: 4 << 30)
        #expect(AppGrouper.friendlyName(vm, catalog: nil) == "com.apple.Virtualization.VirtualMachine")
        let node = OwnProcess(pid: 32, name: "node", executablePath: "/opt/homebrew/bin/node")
        #expect(AppGrouper.friendlyName(node, catalog: Self.catalog) == "node")

        let docker = OwnProcess(pid: 40, name: "Docker Desktop", executablePath: "/Applications/Docker.app/Contents/MacOS/Docker Desktop")
        let apps = [RunningAppInfo(pid: 40, bundleID: "com.docker.docker", name: "Docker Desktop",
                                   bundlePath: "/Applications/Docker.app", policy: .regular)]
        let withDocker = AppGrouper.group(raw([docker, vm], apps: apps), cpu: [:], energy: [:], catalog: nil)
        #expect(withDocker.contains { $0.kind == .system && $0.name == AppGrouper.dockerVMName })
        let alone = AppGrouper.group(raw([vm]), cpu: [:], energy: [:], catalog: nil)
        #expect(alone.first?.name == "com.apple.Virtualization.VirtualMachine")
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
            #expect(e.map { !$0.explanation.isEmpty && !$0.explanation.contains("\n") } == true, "explanation of \(id)")
        }
        #expect(catalog.entry(bundleID: "com.google.Chrome", processName: "x")?.id == "chrome")
        #expect(catalog.entry(bundleID: "com.docker.docker", processName: "x")?.id == "docker-desktop")
        #expect(catalog.entry(bundleID: nil, processName: "Python3")?.id == "python")
        #expect(catalog.entry(bundleID: nil, processName: "mdworker_shared")?.id == "spotlight")
        #expect(catalog.entry(bundleID: nil, processName: "redis-server")?.id == "redis")
        #expect(catalog.entry(bundleID: nil, processName: "nada") == nil)
        #expect(catalog.entry(bundleID: nil, processName: "node")?.explanation.hasPrefix("A JavaScript program") == true)
    }

    // MARK: - I1: apps opened after airy-mcp started

    static let spotifyApp = "/Applications/Spotify.app"
    static let spotifyProcs = [
        OwnProcess(pid: 70, name: "Spotify", executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
                   footprint: 400 << 20),
        OwnProcess(pid: 71, ppid: 70, name: "Spotify Helper",
                   executablePath: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper",
                   footprint: 200 << 20),
    ]

    /// Explicit decision: without app information (neither from NSWorkspace nor from LaunchServices) an `.app` is still
    /// "background" and quitting it is not offered. The fix is to fill in that information, not to guess.
    @Test func bundleWithoutAppInfoStaysBackground() {
        let g = AppGrouper.group(raw(Self.spotifyProcs), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 1 && g[0].kind == .background)
        #expect(!QuitPolicy(currentUID: 501, ownPIDs: []).eligibility(g[0]).isAllowed)
    }

    /// NSWorkspace without the app (stale list): LaunchServices is asked about the `.app`'s PIDs and the app
    /// is recognized as normal and can be quit.
    @Test func staleWorkspaceIsFilledFromFreshLookup() {
        var asked: [Int32] = []
        let apps = ProcessProbe.merge(workspace: [], processes: Self.spotifyProcs) { pid in
            asked.append(pid)
            return pid == 70 ? RunningAppInfo(pid: 70, bundleID: "com.spotify.client", name: "Spotify",
                                              bundlePath: Self.spotifyApp, policy: .regular) : nil
        }
        #expect(asked == [70])
        #expect(apps.map(\.bundleID) == ["com.spotify.client"])
        let g = AppGrouper.group(raw(Self.spotifyProcs, apps: apps), cpu: [:], energy: [:], catalog: nil)
        #expect(g.count == 1 && g[0].kind == .app && g[0].name == "Spotify" && g[0].leadPID == 70)
        #expect(QuitPolicy(currentUID: 501, ownPIDs: []).eligibility(g[0]) == .allowed(.safe))
    }

    @Test func freshLookupSkipsKnownBundlesAndInnerApps() {
        let known = RunningAppInfo(pid: 10, bundleID: "com.google.Chrome", name: "Google Chrome",
                                   bundlePath: Self.chromeApp, policy: .regular)
        let chrome = chromeRaw().processes
        var asked: [Int32] = []
        // Spotify's helper answers with its own inner `.app`: it does not count as Spotify.
        let apps = ProcessProbe.merge(workspace: [known], processes: chrome + Self.spotifyProcs) { pid in
            asked.append(pid)
            return pid == 71 ? RunningAppInfo(pid: 71, name: "Spotify Helper",
                                              bundlePath: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app",
                                              policy: .prohibited) : nil
        }
        #expect(asked == [70, 71])
        #expect(apps == [known])
    }

    // MARK: - M3: /usr/local and the user's temporary folders are not macOS

    @Test func userBinariesUnderSystemPrefixesAreLoose() {
        let brew = OwnProcess(pid: 80, name: "node", executablePath: "/usr/local/bin/node")
        let goRun = OwnProcess(pid: 81, name: "main", executablePath: "/private/var/folders/ab/T/go-build1/b001/exe/main")
        let tmp = OwnProcess(pid: 82, name: "tool", executablePath: "/private/tmp/tool")
        let system = OwnProcess(pid: 83, name: "cfprefsd", executablePath: "/usr/sbin/cfprefsd")
        let g = AppGrouper.group(raw([brew, goRun, tmp, system]), cpu: [:], energy: [:], catalog: nil)
        let kinds = Dictionary(g.map { ($0.leadPID, $0.kind) }, uniquingKeysWith: { a, _ in a })
        #expect(kinds[80] == .looseProcess && kinds[81] == .looseProcess && kinds[82] == .looseProcess)
        #expect(kinds[83] == .system)
    }
}
