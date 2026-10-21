import Foundation
import Synchronization

/// Picks the language of DiskMapCore's user-facing text: `Localizable.xcstrings` strings and the
/// localized fields of `catalog.json` / `apps.json`. English is the source language.
public enum AiryLanguage {
    /// Languages DiskMapCore ships text for.
    public static let supported = ["en", "es"]
    /// Language the source strings and the base JSON fields are written in.
    public static let source = "en"

    private static let overrideStorage = Mutex<String?>(nil)

    /// Forces one language for all DiskMapCore text; `nil` follows the app. `airy-mcp` sets `"en"` so agents
    /// always get stable English. An unsupported language falls back to English.
    public static var override: String? {
        get { overrideStorage.withLock { $0 } }
        set { overrideStorage.withLock { $0 = newValue.map { resolve([$0]) } } }
    }

    /// The language in use: the override if set; otherwise the language the app's own UI resolved to
    /// (`Bundle.main.preferredLocalizations`, i.e. `Locale.preferredLanguages` matched against the languages the
    /// app ships), falling back to English. A process with no localizations of its own (`swift test`,
    /// `swift run`, a bare command-line tool) gets English.
    public static var current: String {
        if let forced = override { return forced }
        guard !Bundle.main.localizations.filter({ $0 != "Base" }).isEmpty else { return source }
        return resolve(Bundle.main.preferredLocalizations)
    }

    /// First supported language among `preferences` (BCP 47 identifiers such as `es-ES` or `en`), or English.
    public static func resolve(_ preferences: [String]) -> String {
        for preference in preferences {
            let code = Locale(identifier: preference).language.languageCode?.identifier
                ?? String(preference.prefix(2))
            if supported.contains(code.lowercased()) { return code.lowercased() }
        }
        return source
    }

    /// English name of a language, for prompts sent to Claude (`"es"` ⇒ `"Spanish"`).
    public static func englishName(of language: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
    }
}

extension Bundle {
    /// DiskMapCore's resource bundle (`Airy_DiskMapCore.bundle`) localized to `AiryLanguage.current`.
    /// Use it as `String(localized: "…", bundle: .airyCore)`. Never aborts: unlike SwiftPM's `Bundle.module`,
    /// a missing bundle falls back to `Bundle.main`.
    public static var airyCore: Bundle { airyCore(language: AiryLanguage.current) }

    /// DiskMapCore's resource bundle pinned to one language (its `<language>.lproj`), whatever the process's
    /// preferences. An unsupported or missing language gives the English source strings.
    public static func airyCore(language: String) -> Bundle {
        AiryCoreBundle.localized(AiryLanguage.resolve([language]))
    }
}

/// Finds and caches `Airy_DiskMapCore.bundle` and its per-language `.lproj` sub-bundles.
enum AiryCoreBundle {
    /// The resource bundle, searched by path like `Catalog.bundled()`: the .app's `Contents/Resources`, next to
    /// the running binary (`airy-mcp`, `swift run`), and the bundles loaded in the process (`swift test`).
    static let resources: Bundle? = {
        let dirs = Catalog.resourceSearchDirectories(executableURL: Bundle.main.executableURL,
                                                     searchProcessBundles: true)
        for dir in dirs {
            if let bundle = Bundle(url: dir.appendingPathComponent(Catalog.bundleName)) { return bundle }
        }
        return nil
    }()

    private static let cache = Mutex<[String: Bundle]>([:])

    static func localized(_ language: String) -> Bundle {
        if let hit = cache.withLock({ $0[language] }) { return hit }
        guard let base = resources else { return .main }
        let bundle = base.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? base
        cache.withLock { $0[language] = bundle }
        return bundle
    }
}
