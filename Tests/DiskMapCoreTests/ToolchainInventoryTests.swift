import Foundation
import Testing
@testable import DiskMapCore

func toolchainTempDir() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-tc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return CleanupTargets.realPath(url.path) ?? url.path
}

func tcMakeDir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func tcWrite(_ path: String, _ text: String = "x") {
    tcMakeDir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

/// `atime`/`mtime` de `path` hace tantos días (sin seguir enlaces).
func tcSetTimes(_ path: String, accessDaysAgo: Double, modifiedDaysAgo: Double) {
    let now = Date().timeIntervalSince1970
    func tv(_ days: Double) -> timeval { timeval(tv_sec: Int(now - days * 86_400), tv_usec: 0) }
    var times = [tv(accessDaysAgo), tv(modifiedDaysAgo)]
    _ = lutimes(path, &times)
}

/// Raíces de prueba: todo dentro de `base` (home en `base/home`).
func tcRoots(_ base: String) -> ToolchainRoots {
    ToolchainRoots(home: base + "/home", cellars: [base + "/Cellar"], applications: base + "/Applications",
                   libraryJava: base + "/Java", libraryPython: base + "/Python", xcodeSelectLink: base + "/xcode_link")
}

@Suite struct ToolchainInventoryTests {
    @Test func inventoryFindsEachManagerLayout() {
        let base = toolchainTempDir()
        let h = base + "/home"
        let dirs = [
            ".pyenv/versions/3.11.4", "miniconda3/envs/ml", ".nvm/versions/node/v20.1.0",
            "Library/Application Support/fnm/node-versions/v18.17.0", ".volta/tools/image/node/20.11.0",
            ".asdf/installs/nodejs/18.17.0", ".asdf/installs/golang/1.21.0", ".asdf/installs/elixir/1.15",
            ".rbenv/versions/3.2.2", ".rvm/rubies/ruby-3.1.0", ".sdkman/candidates/java/17.0.9-tem",
            ".sdkman/candidates/gradle/8.5", ".rustup/toolchains/stable-aarch64-apple-darwin", "sdk/go1.21.0",
        ]
        for d in dirs { tcMakeDir(h + "/" + d) }
        tcMakeDir(base + "/Cellar/python@3.11/3.11.6")
        let found = ToolchainInventory.scan(tcRoots(base))
        func row(_ name: String) -> InstalledToolchain? { found.first { $0.name == name } }
        let expected: [(String, ToolchainManager, ToolchainLanguage, String)] = [
            ("3.11.4", .pyenv, .python, "3.11.4"),
            ("ml", .conda, .condaEnv, h + "/miniconda3/envs/ml"),
            ("v20.1.0", .nvm, .node, h + "/.nvm/versions/node/v20.1.0"),
            ("v18.17.0", .fnm, .node, "v18.17.0"),
            ("20.11.0", .volta, .node, h + "/.volta/tools/image/node/20.11.0"),
            ("18.17.0", .asdf, .node, h + "/.asdf/installs/nodejs/18.17.0"),
            ("1.21.0", .asdf, .go, h + "/.asdf/installs/golang/1.21.0"),
            ("1.15", .asdf, .other, h + "/.asdf/installs/elixir/1.15"),
            ("3.2.2", .rbenv, .ruby, "3.2.2"),
            ("ruby-3.1.0", .rvm, .ruby, h + "/.rvm/rubies/ruby-3.1.0"),
            ("java/17.0.9-tem", .sdkman, .java, h + "/.sdkman/candidates/java/17.0.9-tem"),
            ("gradle/8.5", .sdkman, .other, h + "/.sdkman/candidates/gradle/8.5"),
            ("stable-aarch64-apple-darwin", .rustup, .rust, "stable-aarch64-apple-darwin"),
            ("go1.21.0", .goSDK, .go, h + "/sdk/go1.21.0"),
            ("python@3.11", .homebrew, .python, "python@3.11"),
        ]
        #expect(found.count == expected.count)
        for (name, manager, language, target) in expected {
            let r = row(name)
            #expect(r?.manager == manager && r?.language == language && r?.target == target, "\(name)")
            #expect(r?.informational == false, "\(name)")
        }
    }

    @Test func symlinkEntriesAreNotInventoried() throws {
        let base = toolchainTempDir()
        let h = base + "/home"
        tcMakeDir(h + "/.pyenv/versions/3.11.4")
        try FileManager.default.createSymbolicLink(atPath: h + "/.pyenv/versions/foo",
                                                   withDestinationPath: h + "/.pyenv/versions/3.11.4")
        tcMakeDir(h + "/.sdkman/candidates/java/17.0.9-tem")
        try FileManager.default.createSymbolicLink(atPath: h + "/.sdkman/candidates/java/current",
                                                   withDestinationPath: "17.0.9-tem")
        tcMakeDir(h + "/.rvm/rubies/ruby-3.1.0")
        try FileManager.default.createSymbolicLink(atPath: h + "/.rvm/rubies/default", withDestinationPath: "ruby-3.1.0")
        let names = ToolchainInventory.scan(tcRoots(base)).map(\.name)
        #expect(names.sorted() == ["3.11.4", "java/17.0.9-tem", "ruby-3.1.0"])
    }

    @Test func homebrewOnlyVersionedLanguageFormulas() {
        let base = toolchainTempDir()
        for f in ["python@3.11", "node@18", "ffmpeg", "openjdk", "python@3", "go@1.21"] {
            tcMakeDir(base + "/Cellar/\(f)/1.0")
        }
        let found = ToolchainInventory.scan(tcRoots(base))
        #expect(found.map(\.name).sorted() == ["go@1.21", "node@18", "openjdk", "python@3.11"])
        #expect(found.allSatisfy { $0.manager == .homebrew && $0.target == $0.name })
    }

    @Test func condaBaseIsNeverAnInstall() {
        let base = toolchainTempDir()
        let h = base + "/home"
        tcMakeDir(h + "/miniconda3/bin")
        tcMakeDir(h + "/miniconda3/envs/ml")
        let found = ToolchainInventory.scan(tcRoots(base))
        #expect(found.map(\.path) == [h + "/miniconda3/envs/ml"])
        #expect(found.first?.target == h + "/miniconda3/envs/ml")
    }

    @Test func lastUsedIsMaxOfExecutableAtimeAndFolderMtime() throws {
        let base = toolchainTempDir()
        let v = base + "/home/.pyenv/versions"
        tcWrite(v + "/3.11.4/bin/python3")
        tcSetTimes(v + "/3.11.4/bin/python3", accessDaysAgo: 10, modifiedDaysAgo: 300)
        tcSetTimes(v + "/3.11.4", accessDaysAgo: 200, modifiedDaysAgo: 200)
        tcMakeDir(v + "/3.12.1")
        tcSetTimes(v + "/3.12.1", accessDaysAgo: 50, modifiedDaysAgo: 50)
        let found = ToolchainInventory.scan(tcRoots(base))
        let day: TimeInterval = 86_400
        let a = try #require(found.first { $0.name == "3.11.4" }?.lastUsed)
        #expect(abs(Date().timeIntervalSince(a) - 10 * day) < day)
        let b = try #require(found.first { $0.name == "3.12.1" }?.lastUsed)
        #expect(abs(Date().timeIntervalSince(b) - 50 * day) < day)
    }

    @Test func systemInstallsAreInformational() {
        let base = toolchainTempDir()
        tcMakeDir(base + "/Applications/Xcode.app")
        tcMakeDir(base + "/Applications/Xcode-beta.app")
        tcMakeDir(base + "/Java/x.jdk")
        tcMakeDir(base + "/Python/3.11")
        tcMakeDir(base + "/Python/Current")
        let found = ToolchainInventory.scan(tcRoots(base))
        #expect(found.map(\.name).sorted() == ["3.11", "Xcode-beta.app", "Xcode.app", "x.jdk"])
        #expect(found.allSatisfy { $0.informational && $0.manager == .system })
        // Un solo Xcode no es «duplicado».
        let single = toolchainTempDir()
        tcMakeDir(single + "/Applications/Xcode.app")
        #expect(ToolchainInventory.scan(tcRoots(single)).isEmpty)
    }
}
