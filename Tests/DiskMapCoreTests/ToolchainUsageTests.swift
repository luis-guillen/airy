import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private func link(_ path: String, to destination: String) {
    tcMakeDir((path as NSString).deletingLastPathComponent)
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
}

private func report(_ base: String, runner: FakeRunner = FakeRunner(),
                    projects: ProjectList = ProjectList(projects: [], complete: true)) async -> UsageReport {
    let roots = tcRoots(base)
    return await ToolchainUsage.report(installs: ToolchainInventory.scan(roots), roots: roots, projects: projects,
                                       runner: runner)
}

private func install(_ manager: ToolchainManager, _ language: ToolchainLanguage, _ name: String,
                     path: String = "/x") -> InstalledToolchain {
    InstalledToolchain(manager: manager, language: language, name: name, path: path, target: name, lastUsed: nil)
}

@Suite struct ToolchainUsageTests {
    @Test func defaultsFromEachManagerFile() async {
        let base = toolchainTempDir()
        let h = base + "/home"
        for d in [".pyenv/versions/3.9.18", ".pyenv/versions/3.11.4", ".nvm/versions/node/v18.17.0",
                  ".nvm/versions/node/v20.1.0", ".fnm/node-versions/v18.0.0", ".fnm/node-versions/v20.0.0",
                  ".volta/tools/image/node/18.0.0", ".volta/tools/image/node/20.0.0",
                  ".asdf/installs/nodejs/16.0.0", ".asdf/installs/nodejs/17.0.0", ".rbenv/versions/3.2.2",
                  ".rbenv/versions/3.3.0", ".rvm/rubies/ruby-3.1.0", ".rvm/rubies/ruby-3.0.0",
                  ".sdkman/candidates/java/17.0.9-tem", ".sdkman/candidates/java/21.0.1-tem",
                  ".rustup/toolchains/stable-aarch64-apple-darwin", ".rustup/toolchains/1.70.0-aarch64-apple-darwin",
                  ".rustup/toolchains/nightly-aarch64-apple-darwin"] {
            tcMakeDir(h + "/" + d)
        }
        tcWrite(h + "/.pyenv/version", "3.11.4\n")
        tcWrite(h + "/.nvm/alias/default", "20\n")
        link(h + "/.fnm/aliases/default", to: h + "/.fnm/node-versions/v18.0.0")
        tcWrite(h + "/.volta/tools/user/platform.json", #"{"node":{"runtime":"20.0.0","npm":null}}"#)
        tcWrite(h + "/.tool-versions", "nodejs 17.0.0\n")
        tcWrite(h + "/.rbenv/version", "3.3.0\n")
        link(h + "/.rvm/rubies/default", to: h + "/.rvm/rubies/ruby-3.0.0")
        link(h + "/.sdkman/candidates/java/current", to: "21.0.1-tem")
        tcWrite(h + "/.rustup/settings.toml",
                "default_toolchain = \"stable-aarch64-apple-darwin\"\nprofile = \"default\"\n\n[overrides]\n\"/Users/x/p\" = \"1.70.0\"\n")
        let r = await report(base)
        let expected: [(String, String)] = [
            (".pyenv/versions/3.11.4", "Es la versión por defecto de pyenv."),
            (".nvm/versions/node/v20.1.0", "Es la versión por defecto de nvm."),
            (".fnm/node-versions/v18.0.0", "Es la versión por defecto de fnm."),
            (".volta/tools/image/node/20.0.0", "Es la versión por defecto de Volta."),
            (".asdf/installs/nodejs/17.0.0", "Es la versión por defecto de asdf."),
            (".rbenv/versions/3.3.0", "Es la versión por defecto de rbenv."),
            (".rvm/rubies/ruby-3.0.0", "Es la versión por defecto de rvm."),
            (".sdkman/candidates/java/21.0.1-tem", "Es la versión por defecto de SDKMAN."),
            (".rustup/toolchains/stable-aarch64-apple-darwin", "Es la versión por defecto de rustup."),
            (".rustup/toolchains/1.70.0-aarch64-apple-darwin", "Es la versión por defecto de rustup."),
        ]
        for (relative, reason) in expected { #expect(r.defaults[h + "/" + relative] == reason, "\(relative)") }
        #expect(r.defaults.count == expected.count)
        #expect(r.noPreselect.isEmpty)
    }

    @Test func pathResolutionMarksInUse() async {
        let base = toolchainTempDir()
        let h = base + "/home"
        tcWrite(h + "/.nvm/versions/node/v20.1.0/bin/node")
        tcMakeDir(h + "/.nvm/versions/node/v18.0.0")
        tcMakeDir(h + "/.pyenv/versions/3.11.4")
        tcWrite(h + "/.pyenv/shims/python3")
        let runner = FakeRunner(resolved: ["node": h + "/.nvm/versions/node/v20.1.0/bin/node",
                                           "python3": h + "/.pyenv/shims/python3"])
        let r = await report(base, runner: runner)
        #expect(r.defaults == [h + "/.nvm/versions/node/v20.1.0": "La usa el PATH (node)."])
    }

    @Test func projectPinsMarkRequestedVersions() async {
        let base = toolchainTempDir()
        let h = base + "/home"
        for d in [".nvm/versions/node/v18.17.0", ".nvm/versions/node/v18.20.1", ".nvm/versions/node/v20.1.0",
                  ".pyenv/versions/3.11.4", ".pyenv/versions/3.12.1"] { tcMakeDir(h + "/" + d) }
        tcWrite(h + "/Projects/app/.nvmrc", "18\n")
        tcWrite(h + "/Projects/mono/web/.python-version", "3.11\n")
        tcWrite(h + "/Projects/mono/a/b/.python-version", "3.12\n") // demasiado hondo
        let projects = ProjectList(projects: [h + "/Projects/app", h + "/Projects/mono"], complete: true)
        let r = await report(base, projects: projects)
        #expect(r.requested[h + "/.nvm/versions/node/v18.17.0"] == "La pide ~/Projects/app (.nvmrc).")
        #expect(r.requested[h + "/.nvm/versions/node/v18.20.1"] != nil)
        #expect(r.requested[h + "/.nvm/versions/node/v20.1.0"] == nil)
        #expect(r.requested[h + "/.pyenv/versions/3.11.4"] == "La pide ~/Projects/mono/web (.python-version).")
        #expect(r.requested[h + "/.pyenv/versions/3.12.1"] == nil)
        #expect(r.projectsComplete && r.noPreselect.isEmpty)
    }

    @Test func pinMatchingIsComponentWise() {
        func pin(_ l: ToolchainLanguage, _ raw: String) -> VersionPin { VersionPin(language: l, raw: raw, source: "") }
        #expect(!pin(.python, "3.1").matches(install(.pyenv, .python, "3.11.0")))
        #expect(pin(.python, "3.11").matches(install(.pyenv, .python, "3.11.0")))
        #expect(pin(.node, "v18").matches(install(.nvm, .node, "18.0.0")))
        #expect(pin(.node, "18").matches(install(.nvm, .node, "v18.0.0")))
        #expect(pin(.ruby, "ruby-3.2.2").matches(install(.rbenv, .ruby, "3.2.2")))
        #expect(pin(.rust, "1.75").matches(install(.rustup, .rust, "1.75.0-aarch64-apple-darwin")))
        #expect(pin(.rust, "stable").matches(install(.rustup, .rust, "stable-aarch64-apple-darwin")))
        #expect(!pin(.rust, "beta").matches(install(.rustup, .rust, "stable-aarch64-apple-darwin")))
        #expect(pin(.java, "17").matches(install(.sdkman, .java, "java/17.0.9-tem")))
        #expect(pin(.python, "3.11").matches(install(.homebrew, .python, "python@3.11")))
        #expect(pin(.go, "1.21").matches(install(.goSDK, .go, "go1.21.0")))
        #expect(!pin(.node, "18").matches(install(.pyenv, .python, "18.0.0")))
    }

    @Test func toolVersionsAndRustToolchainTomlAreParsed() {
        let base = toolchainTempDir()
        tcWrite(base + "/p/.tool-versions", "nodejs 18.17.0 20.1.0\n# comentario\n")
        tcWrite(base + "/p/rust-toolchain.toml", "[toolchain]\nchannel = \"1.70.0\"\ncomponents = [\"clippy\"]\n")
        let pins = ToolchainUsage.pins(inProject: base + "/p")
        #expect(pins.filter { $0.language == .node }.map(\.raw) == ["18.17.0", "20.1.0"])
        #expect(pins.filter { $0.language == .rust }.map(\.raw) == ["1.70.0"])
        // Un archivo de más de 64 KB se ignora.
        tcWrite(base + "/q/.nvmrc", String(repeating: "1", count: 70_000))
        #expect(ToolchainUsage.pins(inProject: base + "/q").isEmpty)
    }

    @Test func unresolvablePinsAreConservative() async {
        let base = toolchainTempDir()
        let h = base + "/home"
        for d in [".nvm/versions/node/v18.17.0", ".nvm/versions/node/v20.1.0", ".nvm/versions/node/v9.0.0"] {
            tcMakeDir(h + "/" + d)
        }
        tcWrite(h + "/.nvm/alias/default", "lts/iron\n")
        tcWrite(h + "/Projects/app/.nvmrc", "lts/*\n")
        let r = await report(base, projects: ProjectList(projects: [h + "/Projects/app"], complete: true))
        #expect(r.noPreselect.contains(.node))
        #expect(r.defaults == [h + "/.nvm/versions/node/v20.1.0": "Es la versión por defecto de nvm."])
        #expect(r.requested.isEmpty)
    }

    @Test func condaEnvironmentYmlRequestsEnv() async {
        let base = toolchainTempDir()
        let h = base + "/home"
        tcMakeDir(h + "/miniconda3/envs/ml")
        tcMakeDir(h + "/miniconda3/envs/old")
        tcWrite(h + "/Projects/app/environment.yml", "name: ml\nchannels:\n  - conda-forge\n")
        let r = await report(base, projects: ProjectList(projects: [h + "/Projects/app"], complete: true))
        #expect(r.requested == [h + "/miniconda3/envs/ml": "La pide ~/Projects/app (environment.yml)."])
    }

    @Test func oneProjectWalkPerPassAndBudgetFailsClosed() async throws {
        let base = toolchainTempDir()
        let h = base + "/home"
        tcWrite(h + "/Projects/app/package.json", "{}")
        tcWrite(h + "/Projects/other/Cargo.toml", "")
        let catalog = Catalog(entries: [try #require(try Catalog.bundled().entry(id: "old-project-artifacts"))])
        let context = DiscoveryContext(catalog: catalog, home: h, runner: FakeRunner(), processListing: NoListing(),
                                       now: Date(), scan: nil)
        let count = Mutex(0)
        let source = ProjectArtifactSource(isUbiquitous: { _ in false }, onListProjects: { count.withLock { $0 += 1 } })
        _ = await source.discover(catalog.entries[0], context: context)
        let list = await source.projectList(context: context)
        _ = await ToolchainUsage.report(installs: [], roots: tcRoots(base), projects: list, runner: FakeRunner())
        #expect(count.withLock { $0 } == 1)
        #expect(list == ProjectList(projects: [h + "/Projects/app", h + "/Projects/other"], complete: true))

        let fresh = DiscoveryContext(catalog: catalog, home: h, runner: FakeRunner(), processListing: NoListing(),
                                     now: Date(), scan: nil)
        let none = await ProjectArtifactSource(totalBudget: .zero).projectList(context: fresh)
        #expect(!none.complete)
        let r = await ToolchainUsage.report(installs: [], roots: tcRoots(base), projects: none, runner: FakeRunner())
        #expect(r.noPreselect == Set(ToolchainLanguage.allCases) && !r.projectsComplete)
    }
}

struct NoListing: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}
