import Foundation
import Testing
@testable import DiskMapCore

private func makeDir(_ label: String) -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func touch(_ path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
}

private func mkdir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func link(_ path: String, to target: String) {
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
}

@Suite struct PathGateTests {
    let h = makeDir("airy-gate-home")
    let tmp = makeDir("airy-gate-tmp")

    func gate(protected patterns: [String] = [], protections: HardProtections = .standard) -> PathGate {
        PathGate(home: h, catalog: try? Catalog.bundled(), userProtected: ProtectList(patterns: patterns, home: h),
                 protections: protections)
    }

    @Test func rejectsRelativeDotDotAndControlChars() {
        let gate = gate()
        for p in ["Library/x", "/tmp/a/../b", "/a\u{7}b", "", "/a//b", "/a/./b", "/a/", "/" + String(repeating: "a", count: 1100)] {
            #expect(gate.validate(p).failure != nil, "\(p)")
        }
        #expect(gate.validate(h + "/no-existe").failure != nil)
    }

    @Test func rejectsCriticalRootsCaseInsensitive() {
        let gate = gate()
        for p in ["/", "/usr", "/USR", "/applications", "/System/Library", "/private/var/folders", "/Users"] {
            #expect(gate.validate(p).failure != nil, "\(p)")
        }
    }

    @Test func rejectsHomeAndUsersChildren() {
        let gate = gate()
        for p in [h, "/Users/Shared", "/Users/" + NSUserName()] {
            #expect(gate.validate(p).failure != nil, "\(p)")
        }
        // The resolved form of the home too (/private/var/… versus /var/…).
        let real = String(cString: realpath(h, nil))
        #expect(gate.validate(real).failure != nil)
    }

    @Test func rejectsAliasOfCriticalRootByInode() throws {
        // The injected critical root is declared through a link: the text does not match the real path,
        // only `(st_dev, st_ino)` can recognize it.
        let realRoot = tmp + "/raiz-real"
        mkdir(realRoot)
        link(tmp + "/raiz-declarada", to: realRoot)
        let protections = HardProtections(criticalRoots: HardProtections.standard.criticalRoots + [tmp + "/raiz-declarada"])
        let gate = gate(protections: protections)
        let refusal = try #require(gate.validate(realRoot).failure)
        #expect(refusal.reason.contains("the same as"), "\(refusal.reason)")
        // Without the injected root, the same folder is accepted: what rejects it is the inode.
        #expect(self.gate().validate(realRoot).failure == nil)
        // System alias: the same folder as /Users.
        #expect(gate.validate("/System/Volumes/Data/Users").failure != nil)
    }

    @Test func resolvesSymlinkedAncestor() {
        touch(h + "/Library/Mail/x")
        link(tmp + "/enlace", to: h + "/Library/Mail")
        #expect(gate().validate(tmp + "/enlace/x").failure != nil)
    }

    @Test func unresolvableParentFailsClosed() {
        // The literal path is short and `lstat` works, but the real one goes past PATH_MAX: `realpath` fails with
        // ENAMETOOLONG. Without resolving it we do not know it is inside ~/Library/Mail: it is rejected.
        // tmp/l1 → ~/Library/Mail;  ~/Library/Mail/l2 → "aaa…/bbb…/ccc…/ddd…" (relative);  x inside.
        let mail = h + "/Library/Mail"
        mkdir(mail)
        link(tmp + "/l1", to: mail)
        let names = ["a", "b", "c", "d"].map { String(repeating: $0, count: 250) }
        var fd = open(mail, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0)
        for name in names {
            #expect(mkdirat(fd, name, 0o755) == 0)
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        let file = openat(fd, "x", O_CREAT | O_WRONLY, 0o644)
        #expect(file >= 0)
        close(file); close(fd)
        #expect(symlink(names.joined(separator: "/"), mail + "/l2") == 0)
        let tail = tmp + "/l1/l2"
        var info = stat()
        #expect(lstat(tail + "/x", &info) == 0)
        #expect(realpath(tail, nil) == nil)
        let refusal = gate().validate(tail + "/x").failure
        #expect(refusal?.reason == "The real path cannot be resolved; it is not touched.")
        // Broken link: still accepted (the target does not exist; its text is checked).
        link(tmp + "/roto", to: tmp + "/no-existe")
        #expect(gate().validate(tmp + "/roto").failure == nil)
        link(tmp + "/roto-mail", to: h + "/Library/Mail/no-existe")
        #expect(gate().validate(tmp + "/roto-mail").failure != nil)
    }

    @Test func symlinkTargetIsValidated() {
        mkdir(h + "/Library/Keychains")
        link(tmp + "/enlace", to: h + "/Library/Keychains")
        #expect(gate().validate(tmp + "/enlace").failure != nil)
        mkdir(tmp + "/inocuo")
        link(tmp + "/enlace-bueno", to: tmp + "/inocuo")
        #expect(gate().validate(tmp + "/enlace-bueno").failure == nil)
    }

    @Test func identityChangeIsDetected() throws {
        let gate = gate()
        let target = h + "/Library/Caches/com.example.app"
        mkdir(target + "/sub")
        mkdir(h + "/Documents")
        let validated = try gate.validate(target).get()
        #expect(gate.confirmUnchanged(validated) == nil)
        try FileManager.default.removeItem(atPath: target)
        link(target, to: h + "/Documents")
        #expect(gate.confirmUnchanged(validated) != nil)
    }

    @Test func userProtectedAndItsAncestorsRefused() {
        touch(h + "/Library/Caches/Foo/Bar/x")
        touch(h + "/Library/Caches/Otra/x")
        let gate = gate(protected: ["~/Library/Caches/Foo/Bar"])
        let inside = gate.validate(h + "/Library/Caches/Foo/Bar/x").failure
        #expect(inside?.reason == "You protected it (~/Library/Caches/Foo/Bar).")
        #expect(gate.validate(h + "/Library/Caches/Foo").failure != nil)   // parent: only the user's rule
        #expect(gate.validate(h + "/Library/Caches").failure != nil)
        #expect(gate.validate(h + "/Library/Caches/Otra/x").failure == nil)
        // Through a link to the protected folder, too.
        link(tmp + "/alias", to: h + "/Library/Caches/Foo")
        #expect(gate.validate(tmp + "/alias/Bar").failure != nil)
    }

    @Test func hardProtectionsIgnoreUserSettings() {
        touch(h + "/Library/Keychains/x")
        touch(h + "/.ssh/id_ed25519")
        let gate = gate(protected: [])
        #expect(gate.validate(h + "/Library/Keychains/x").failure?.reason == "Location protected by Airy: Keychains.")
        #expect(gate.validate(h + "/.ssh/id_ed25519").failure != nil)
    }

    @Test func sensitiveAppDataRefusedCatalogExceptionAllowed() {
        let app = h + "/Library/Application Support"
        for p in [app + "/1Password/data", app + "/Claude/vm_bundles", app + "/Claude/otra",
                  app + "/Code/User/x", app + "/Normal App/x",
                  h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x",
                  h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Documents/x"] { touch(p) }
        let gate = gate()
        #expect(gate.validate(app + "/1Password/data").failure?.reason == "Data of a sensitive app (1Password).")
        #expect(gate.validate(app + "/Claude/vm_bundles").failure == nil)   // real catalog
        #expect(gate.validate(app + "/Claude/otra").failure != nil)
        #expect(gate.validate(app + "/Claude").failure != nil)
        #expect(gate.validate(app + "/Code/User/x").failure != nil)          // short name (equality)
        #expect(gate.validate(app + "/Normal App/x").failure == nil)
        #expect(gate.validate(h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x").failure == nil)
        #expect(gate.validate(h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Documents/x").failure != nil)
    }

    @Test func fragmentsAnywhere() {
        for p in [h + "/Library/Caches/com.apple.FontRegistry", h + "/Library/Caches/com.crowdstrike.x",
                  tmp + "/MiSpotlightIndex/x",
                  // 1Password 7: AgileBits' container and group container.
                  h + "/Library/Containers/com.agilebits.onepassword7/Data/x",
                  h + "/Library/Group Containers/2BUA8C4S2C.com.agilebits/x"] {
            touch(p)
            #expect(gate().validate(p).failure != nil, "\(p)")
        }
    }

    @Test func userTempDirContentsStillAllowed() {
        touch(tmp + "/borrable")
        let result = gate().validate(tmp + "/borrable")
        #expect(result.failure == nil)
        let validated = try? result.get()
        #expect(validated?.forms.contains(RiskPolicy.canonical(String(cString: realpath(tmp, nil)) + "/borrable")) == true)
        // The temporary folder itself, no (and not because of the syntax: without the trailing slash).
        var temp = NSTemporaryDirectory()
        if temp.hasSuffix("/") { temp.removeLast() }
        let refusal = gate().validate(temp).failure
        #expect(refusal != nil)
        #expect(refusal?.reason.hasPrefix("Location protected by Airy") == true, "\(String(describing: refusal))")
    }

    @Test func catalogRulesMovedFromExecutor() {
        // "Do not touch" entries and caches that are only cleaned with their official command.
        touch(h + "/.cache/codex-runtimes/codex-primary-runtime/bin/tool")
        touch(h + "/.npm/_cacache/x")
        let gate = gate()
        #expect(gate.validate(h + "/.cache/codex-runtimes").failure != nil)
        #expect(gate.validate(h + "/.npm/_cacache/x").failure != nil)
    }
}
