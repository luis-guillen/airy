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
        #expect(policy.eligibility(g) == .never("It is Airy itself."))
    }

    @Test func airyMCPInsideBundleIsNever() {
        let g = app(name: "airy-mcp", kind: .looseProcess,
                    path: "/Applications/Airy.app/Contents/MacOS/airy-mcp")
        #expect(policy.eligibility(g) == .never("It is Airy itself."))
        let bundle = app(bundle: "x.y", name: "Z", path: "/Applications/Airy.app")
        #expect(policy.eligibility(bundle) == .never("It is Airy itself."))
    }

    @Test func otherUsersAndSystemNever() {
        #expect(policy.eligibility(app(name: "Algo", uid: 0)) == .never("It belongs to another user or to the system."))
        #expect(policy.eligibility(app(name: "Algo", kind: .system)) == .never("It is part of macOS."))
        #expect(policy.eligibility(app(name: "Algo", kind: .background))
                == .never("It is a background process; macOS reopens it by itself."))
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
        #expect(policy.eligibility(g) == .never("macOS needs it to work."))
    }
}
