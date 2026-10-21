import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private final class NoListing: ProcessListing, Sendable {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func tempHome() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-appcache-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func writeFile(_ path: String, bytes: Int = 10_000, daysAgo: Double = 0) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
    if daysAgo > 0 {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        try! FileManager.default.setAttributes([.modificationDate: date],
                                               ofItemAtPath: (path as NSString).deletingLastPathComponent)
    }
}

private func catalog(_ ids: String...) throws -> Catalog {
    let all = try Catalog.bundled()
    return Catalog(entries: try ids.map { try #require(all.entry(id: $0), "\($0)") })
}

private func scan(_ catalog: Catalog, home: String) async -> [CleanupItem] {
    await CleanupScanner(catalog: catalog, runner: FakeRunner(), probes: FakeProbes(),
                         references: ReferenceChecker(roots: []), home: home, processListing: NoListing())
        .findItems(scan: nil)
}

private let support = "/Library/Application Support"

@Suite struct AppCacheTests {
    @Test func chromiumProfileCachesAreFoundButNotProfileData() async throws {
        let home = tempHome()
        let chrome = home + support + "/Google/Chrome"
        writeFile(chrome + "/Default/Code Cache/js/a")
        writeFile(chrome + "/Default/Cookies")
        writeFile(chrome + "/Default/Local Storage/leveldb/b")
        writeFile(chrome + "/Profile 1/Service Worker/CacheStorage/c")
        writeFile(chrome + "/GrShaderCache/d")
        writeFile(home + "/Library/Caches/Google/Chrome/e")
        let items = await scan(try catalog("chrome-cache"), home: home)
        let item = try #require(items.first)
        #expect(Set(item.paths) == [
            chrome + "/Default/Code Cache", chrome + "/Profile 1/Service Worker/CacheStorage",
            chrome + "/GrShaderCache", home + "/Library/Caches/Google/Chrome",
        ])
        #expect(item.risk == .safe && item.entry.mustBeClosed == ["com.google.Chrome"])
        #expect(!item.paths.contains { $0.contains("Cookies") || $0.contains("Local Storage") })
    }

    @Test func browserTableCoversTheChromiumFamily() throws {
        let all = try Catalog.bundled()
        let bundles = ["chrome-cache": "com.google.Chrome", "brave-cache": "com.brave.Browser",
                       "edge-cache": "com.microsoft.edgemac", "chromium-cache": "org.chromium.Chromium",
                       "arc-cache": "company.thebrowser.Browser", "vivaldi-cache": "com.vivaldi.Vivaldi",
                       "opera-cache": "com.operasoftware.Opera", "firefox-cache": "org.mozilla.firefox"]
        for (id, bundle) in bundles {
            let entry = try #require(all.entry(id: id), "\(id)")
            #expect(entry.cleanup == .trash && entry.risk == .safe && entry.mustBeClosed == [bundle], "\(id)")
            #expect(entry.profiles == [.basic], "\(id)")
        }
        let edge = try #require(all.entry(id: "edge-cache"))
        #expect(edge.paths.contains("~/Library/Application Support/Microsoft Edge/*/Service Worker/CacheStorage"))
        #expect(edge.paths.contains("~/Library/Application Support/Microsoft Edge/Crashpad/completed"))
        #expect(edge.paths.contains("~/Library/Caches/com.microsoft.edgemac"))
        // Nunca datos de perfil.
        for id in bundles.keys {
            let paths = try #require(all.entry(id: id)).paths
            #expect(!paths.contains { $0.contains("Cookies") || $0.contains("Login Data") || $0.contains("Local Storage")
                || $0.contains("History") || $0.hasSuffix("/Default") }, "\(id)")
        }
    }

    @Test func heuristicFindsElectronAppAndSkipsCatalogued() async throws {
        let home = tempHome()
        writeFile(home + support + "/FooApp/GPUCache/a")
        writeFile(home + support + "/FooApp/Cache/b")
        writeFile(home + support + "/FooApp/Data/c")
        writeFile(home + support + "/Google/Chrome/GrShaderCache/z")
        writeFile(home + support + "/Otra/Crashpad/completed/x")
        let items = await scan(try catalog("chrome-cache", "app-support-caches"), home: home)
        let app = try #require(items.first { $0.id == "app-support-caches:FooApp" })
        #expect(Set(app.paths) == [home + support + "/FooApp/GPUCache", home + support + "/FooApp/Cache"])
        #expect(app.entry.title == "Cachés regenerables de una app")
        let crash = try #require(items.first { $0.id == "app-support-caches:Otra" })
        #expect(crash.paths == [home + support + "/Otra/Crashpad/completed"])
        // Chrome lo reclama su ficha, no la heurística.
        #expect(!items.contains { $0.id == "app-support-caches:Google/Chrome" })
        #expect(items.contains { $0.id == "chrome-cache" })
        // Prudente: ámbar; Agresivo: verde.
        let all = try Catalog.bundled()
        let entry = try #require(all.entry(id: "app-support-caches"))
        var settings = AirySettings()
        settings.mode = .prudent
        #expect(RiskClassifier(catalog: all, settings: settings, home: home).classify(entry: entry, paths: app.paths).risk == .yourCall)
        settings.mode = .aggressive
        #expect(RiskClassifier(catalog: all, settings: settings, home: home).classify(entry: entry, paths: app.paths).risk == .safe)
    }

    @Test func heuristicDropsHardProtectedApps() async throws {
        let home = tempHome()
        writeFile(home + support + "/1Password/GPUCache/a")
        writeFile(home + support + "/Code/GPUCache/b") // «code» es sensible
        #expect(await scan(try catalog("app-support-caches"), home: home).isEmpty)
    }

    @Test func heuristicSkipsHugeFolders() async throws {
        let home = tempHome()
        let folder = home + support + "/Grande"
        writeFile(folder + "/GPUCache/a")
        #expect(await scan(try catalog("app-support-caches"), home: home).count == 1)
        for i in 0..<(AppSupportCacheSource.maxChildren + 1) {
            FileManager.default.createFile(atPath: folder + "/f\(i)", contents: nil)
        }
        #expect(await scan(try catalog("app-support-caches"), home: home).isEmpty)
    }

    @Test func heuristicRevalidatesAtActTime() async throws {
        let home = tempHome()
        writeFile(home + support + "/FooApp/GPUCache/a")
        let cat = try catalog("app-support-caches")
        let item = try #require(await scan(cat, home: home).first)
        let entry = try #require(cat.entries.first)
        let context = DiscoveryContext(catalog: cat, home: home, runner: FakeRunner(), processListing: NoListing(),
                                       now: Date(), scan: nil)
        let source = AppSupportCacheSource()
        #expect(await source.revalidate(entry, item: item, context: context) == nil)
        var other = item
        other.paths = [home + support + "/FooApp/Data"]
        writeFile(home + support + "/FooApp/Data/c")
        #expect(await source.revalidate(entry, item: other, context: context)?.hasPrefix("No es una carpeta de caché conocida") == true)
        try FileManager.default.removeItem(atPath: home + support + "/FooApp/GPUCache")
        writeFile(home + support + "/FooApp/Cache/x")
        var cache = item
        cache.paths = [home + support + "/FooApp/Cache"]
        #expect(await source.revalidate(entry, item: cache, context: context)?.hasPrefix("La app ya no tiene") == true)
    }

    @Test func sensitiveAppCachesPassThroughCatalogException() throws {
        let home = tempHome()
        let all = try Catalog.bundled()
        let gate = PathGate(home: home, catalog: all, userProtected: ProtectList(patterns: [], home: home))
        for app in ["Slack", "discord", "Notion", "Figma"] {
            for cache in ["Cache", "Code Cache", "GPUCache"] { writeFile(home + support + "/\(app)/\(cache)/x") }
            writeFile(home + support + "/\(app)/storage/y")
            #expect(gate.validate(home + support + "/\(app)/Cache").failure == nil, "\(app)")
            #expect(gate.validate(home + support + "/\(app)/storage").failure != nil, "\(app)")
        }
        writeFile(home + support + "/Slack/Service Worker/CacheStorage/z")
        #expect(gate.validate(home + support + "/Slack/Service Worker/CacheStorage").failure == nil)
        for id in ["slack-cache", "discord-cache", "notion-cache", "figma-cache"] {
            #expect(try #require(all.entry(id: id)).paths.allSatisfy { !$0.contains("*") }, "\(id)")
        }
    }

    @Test func staleGamesOnlyAfter90Days() async throws {
        let home = tempHome()
        writeFile(home + support + "/Steam/steamapps/common/Viejo/data", daysAgo: 100)
        writeFile(home + support + "/Steam/steamapps/common/Nuevo/data", daysAgo: 10)
        let items = await scan(try catalog("steam-games"), home: home)
        #expect(items.map(\.id) == ["steam-games:~/Library/Application Support/Steam/steamapps/common/Viejo"])
        #expect(items.first?.risk == .yourCall && items.first?.preselected == false)
        let all = try Catalog.bundled()
        for id in ["steam-games", "epic-games", "whisky-bottles"] {
            let entry = try #require(all.entry(id: id))
            #expect(entry.perMatch && entry.staleAfterDays == 90 && entry.risk == .yourCall, "\(id)")
        }
        #expect(try #require(all.entry(id: "whisky-bottles")).regenerates == false)
        #expect(try #require(all.entry(id: "epic-games")).paths == ["/Users/Shared/Epic Games/*"])
    }

    @Test func appCachesCarryTheirProfiles() throws {
        let all = try Catalog.bundled()
        let expected: [String: [UsageProfile]] = [
            "slack-cache": [.basic], "discord-cache": [.basic], "zoom-cache": [.basic], "teams-cache": [.basic],
            "whatsapp-cache": [.basic], "telegram-cache": [.basic], "office-caches": [.basic], "notion-cache": [.basic],
            "adobe-media-cache": [.creative], "figma-cache": [.creative], "finalcut-cache": [.creative],
            "davinci-cache": [.creative], "sketch-cache": [.creative], "apple-music-cache": [.music],
            "vlc-cache": [.music], "spotify-cache": [.music, .basic], "steam-caches": [.gaming],
            "steam-games": [.gaming], "epic-games": [.gaming], "whisky-bottles": [.gaming], "minecraft-logs": [.gaming],
        ]
        for (id, profiles) in expected {
            let entry = try #require(all.entry(id: id), "\(id)")
            #expect(entry.profiles == profiles, "\(id)")
        }
        #expect(try #require(all.entry(id: "adobe-media-cache")).processNames
            == ["Adobe Premiere Pro", "After Effects", "Adobe Media Encoder"])
        #expect(try #require(all.entry(id: "office-caches")).paths.count == 4)
        // La última de Limpieza (las de mantenimiento van detrás y el escáner de Limpieza las salta).
        #expect(all.entries.last { $0.section == .cleanup }?.id == "app-support-caches")
    }

    @Test func davinciCacheInMoviesIsAmber() throws {
        let all = try Catalog.bundled()
        let entry = try #require(all.entry(id: "davinci-cache"))
        let verdict = RiskClassifier(catalog: all, settings: AirySettings(), home: "/Users/ana")
            .classify(entry: entry, paths: ["/Users/ana/Movies/CacheClip"])
        #expect(entry.risk == .safe && verdict.risk == .yourCall && !verdict.preselected)
    }

    @Test func oldDownloadsMeasuresUnderOneSharedBudget() async throws {
        let home = tempHome()
        for i in 0..<3 { writeFile(home + "/Downloads/v\(i).bin", bytes: 60_000_000, daysAgo: 400) }
        let all = try Catalog.bundled()
        let entry = try #require(all.entry(id: "old-downloads"))
        let context = DiscoveryContext(catalog: all, home: home, runner: FakeRunner(), processListing: NoListing(),
                                       now: Date(), scan: nil)
        #expect(await StaticPatternSource().discover(entry, context: context).count == 3)
        // Sin tiempo no se ofrece nada (no se sabe si están sin usar).
        #expect(await StaticPatternSource(measureBudget: .zero).discover(entry, context: context).isEmpty)
    }
}
