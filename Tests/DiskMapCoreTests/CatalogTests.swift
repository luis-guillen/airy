import Testing
import Foundation
@testable import DiskMapCore

@Suite struct CatalogTests {
    let home = "/Users/test"

    @Test func bundledCatalogLoads() throws {
        let catalog = try Catalog.bundled()
        #expect(catalog.entries.count >= 25)
        let ids = catalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(catalog.entries.allSatisfy { !$0.explanation.isEmpty && !$0.whoCreatesIt.isEmpty })
    }

    @Test func matchesGlob() throws {
        let catalog = try Catalog.bundled()
        let m = catalog.match(path: home + "/.cache/codex-runtimes/codex-runtime-install-ab12", home: home)
        #expect(m?.id == "codex-stale-installs")
    }

    @Test func primaryRuntimeIsNotStale() throws {
        let catalog = try Catalog.bundled()
        let m = catalog.match(path: home + "/.cache/codex-runtimes/codex-primary-runtime", home: home)
        #expect(m?.id == "codex-runtime")
        let inside = catalog.match(path: home + "/.cache/codex-runtimes/codex-primary-runtime/bin/x", home: home)
        #expect(inside?.id == "codex-runtime")
    }

    @Test func globDoesNotCrossComponents() throws {
        let catalog = try Catalog.bundled()
        // `*` solo cubre un componente: "install-" sin sufijo de carpeta anidada sigue dentro de la entrada
        #expect(catalog.match(path: home + "/Library/Logs/a/b/c.log", home: home)?.id == "user-logs")
        #expect(catalog.match(path: home + "/.cache/codex-runtimes", home: home) == nil)
    }

    @Test func matchesInsidePathAndUnknown() throws {
        let catalog = try Catalog.bundled()
        #expect(catalog.match(path: home + "/Library/Caches/Homebrew/downloads/x", home: home)?.id == "homebrew")
        #expect(catalog.match(path: home + "/Library/Caches/HomebrewX", home: home) == nil)
        #expect(catalog.match(path: "/opt/x", home: home) == nil)
        #expect(catalog.match(path: home + "/.cache/huggingface/hub/models--a--b", home: home)?.id == "huggingface-model")
    }

    @Test func policyEntriesMatchBrief() throws {
        let catalog = try Catalog.bundled()
        #expect(catalog.entry(id: "docker-volumes")?.risk == .doNotTouch)
        #expect(catalog.entry(id: "codex-runtime")?.risk == .doNotTouch)
        guard case .command(let exe, let args, let probe)? = catalog.entry(id: "docker-build-cache")?.cleanup else {
            Issue.record("docker-build-cache debe ser command"); return
        }
        #expect(exe == "docker")
        #expect(args == ["builder", "prune", "-a", "-f"])
        #expect(probe == ["system", "df", "--format", "{{json .}}"])
        guard case .command(let texe, let targs, let tprobe)? = catalog.entry(id: "time-machine-snapshots")?.cleanup else {
            Issue.record("tm debe ser command"); return
        }
        #expect(texe == "tmutil")
        #expect(targs == ["thinlocalsnapshots", "/", "999999999999", "4"])
        #expect(tprobe == ["listlocalsnapshots", "/"])
        // R1: ejecutables siempre son nombres simples
        for e in catalog.entries {
            if case .command(let exe, _, _) = e.cleanup { #expect(!exe.contains("/"), "\(e.id)") }
        }
    }

    @Test func riskEncodesAsStrings() throws {
        let catalog = try Catalog.bundled()
        let entry = try #require(catalog.entry(id: "homebrew"))
        let data = try JSONEncoder().encode(entry)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["risk"] as? String == "safe")
        #expect(obj["kind"] as? String == "caches")
        let back = try JSONDecoder().decode(CatalogEntry.self, from: data)
        #expect(back.risk == .safe)
        #expect(back.cleanup == entry.cleanup)
    }

    @Test func personalFoldersNeverSafe() {
        #expect(RiskPolicy.effectiveRisk(path: home + "/Documents/x", home: home, catalog: .safe, ai: .safe) == .yourCall)
        #expect(RiskPolicy.minimumRisk(forPath: home + "/Projects", home: home) == .yourCall)
        #expect(RiskPolicy.minimumRisk(forPath: home + "/orca/a", home: home) == .yourCall)
        #expect(RiskPolicy.minimumRisk(forPath: home + "/Documentsx", home: home) == .safe)
    }

    @Test func aiCannotLowerRisk() {
        #expect(RiskPolicy.effectiveRisk(path: home + "/.ollama/models", home: home, catalog: .yourCall, ai: .safe) == .yourCall)
        #expect(RiskPolicy.effectiveRisk(path: home + "/x", home: home, catalog: .safe, ai: .doNotTouch) == .doNotTouch)
    }

    @Test func systemIsDoNotTouch() {
        #expect(RiskPolicy.minimumRisk(forPath: "/System/Library", home: home) == .doNotTouch)
        #expect(RiskPolicy.minimumRisk(forPath: "/System", home: home) == .doNotTouch)
        #expect(RiskPolicy.minimumRisk(forPath: "/Systemx", home: home) == .safe)
    }

    @Test func unknownDefaultsToYourCall() {
        #expect(RiskPolicy.effectiveRisk(path: "/opt/x", home: home, catalog: nil, ai: nil) == .yourCall)
        #expect(RiskPolicy.effectiveRisk(path: "/opt/x", home: home, catalog: .safe, ai: nil) == .safe)
        #expect(RiskPolicy.effectiveRisk(path: "/opt/x", home: home, catalog: nil, ai: .safe) == .safe)
    }
}
