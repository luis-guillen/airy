import Foundation
import Testing
@testable import DiskMapCore

@Suite struct QuitPolicyTests {
    let me: UInt32 = 501
    let ownPID: Int32 = 4242
    var policy: QuitPolicy { QuitPolicy(currentUID: me, ownPIDs: [ownPID]) }

    func app(bundle: String? = nil, name: String, kind: AppGroupKind = .app, uid: UInt32 = 501,
             pid: Int32 = 100, path: String? = nil, processNames: [String]? = nil) -> AppGroup {
        AppGroup(id: bundle ?? "pid:\(pid):0", name: name, bundleID: bundle, bundlePath: path, kind: kind,
                 uid: uid, leadPID: pid, leadStart: Date(timeIntervalSince1970: 0), pids: [pid],
                 processNames: processNames ?? [name], memory: 1)
    }

    @Test func neverClosableList() {
        for (bundle, name) in [("com.apple.finder", "Finder"), ("com.apple.dock", "Dock"), (nil, "WindowServer"),
                               ("com.apple.loginwindow", "loginwindow"), ("com.apple.systemuiserver", "SystemUIServer"),
                               ("com.apple.controlcenter", "Control Center"), ("local.airy.Airy", "Airy"),
                               (nil, "airy-mcp")] as [(String?, String)] {
            let kind: AppGroupKind = bundle == nil ? .looseProcess : .app
            #expect(!policy.eligibility(app(bundle: bundle, name: name, kind: kind)).isAllowed, "\(name)")
        }
    }

    @Test func namesAreCaseInsensitive() {
        #expect(!policy.eligibility(app(name: "finder", kind: .looseProcess)).isAllowed)
        #expect(!policy.eligibility(app(name: "x", kind: .looseProcess, processNames: ["WINDOWSERVER"])).isAllowed)
    }

    @Test func ownPIDNeverEvenIfRenamed() {
        let g = app(bundle: "com.otra.app", name: "Otra", pid: ownPID)
        #expect(policy.eligibility(g) == .never("Es el propio Airy."))
    }

    @Test func airyMCPInsideBundleIsNever() {
        let g = app(name: "airy-mcp", kind: .looseProcess,
                    path: "/Applications/Airy.app/Contents/MacOS/airy-mcp")
        #expect(policy.eligibility(g) == .never("Es el propio Airy."))
        let bundle = app(bundle: "x.y", name: "Z", path: "/Applications/Airy.app")
        #expect(policy.eligibility(bundle) == .never("Es el propio Airy."))
    }

    @Test func otherUsersAndSystemNever() {
        #expect(policy.eligibility(app(name: "Algo", uid: 0)) == .never("Es de otro usuario o del sistema."))
        #expect(policy.eligibility(app(name: "Algo", kind: .system)) == .never("Es parte de macOS."))
        #expect(policy.eligibility(app(name: "Algo", kind: .background))
                == .never("Es un proceso de fondo; macOS lo vuelve a abrir solo."))
    }

    @Test func looseProcessesAreAmber() {
        for n in ["node", "python3"] {
            #expect(policy.eligibility(app(name: n, kind: .looseProcess)) == .allowed(.yourCall))
        }
    }

    @Test func normalAppsAreGreen() {
        let g = app(bundle: "com.spotify.client", name: "Spotify")
        #expect(policy.eligibility(g) == .allowed(.safe))
        #expect(policy.eligibility(g).isAllowed)
    }

    @Test func neverWinsOverEverything() {
        let g = app(bundle: "com.apple.finder", name: "Cualquiera")
        #expect(policy.eligibility(g) == .never("macOS lo necesita para funcionar."))
    }
}
