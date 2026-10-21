import Foundation

public struct AppCatalogEntry: Codable, Sendable, Equatable {
    /// An app entry's displayed text in one language (the `"es"` object in apps.json); `nil` keeps the English.
    public struct Text: Codable, Sendable, Equatable {
        public var title: String?
        public var explanation: String?

        public init(title: String? = nil, explanation: String? = nil) {
            self.title = title; self.explanation = explanation
        }
    }

    public var id, title, explanation: String
    public var bundleIDs: [String]
    public var processNames: [String]
    /// Displayed text per language code other than English.
    public var translations: [String: Text]
    /// Language of `title` and `explanation` (`"en"` as decoded).
    public private(set) var language: String = AiryLanguage.source
    /// The English text while the entry is shown in another language.
    private var sourceText: Text?

    public init(id: String, title: String, explanation: String, bundleIDs: [String] = [], processNames: [String] = [],
                translations: [String: Text] = [:]) {
        self.id = id; self.title = title; self.explanation = explanation
        self.bundleIDs = bundleIDs; self.processNames = processNames; self.translations = translations
    }

    /// The same entry with its text in `language` (English where there is no translation).
    public func localized(to language: String) -> AppCatalogEntry {
        let language = AiryLanguage.resolve([language])
        var entry = self
        if let source = entry.sourceText {
            entry.title = source.title ?? entry.title
            entry.explanation = source.explanation ?? entry.explanation
            entry.sourceText = nil
            entry.language = AiryLanguage.source
        }
        guard language != AiryLanguage.source, let text = translations[language] else { return entry }
        entry.sourceText = Text(title: entry.title, explanation: entry.explanation)
        entry.title = text.title ?? entry.title
        entry.explanation = text.explanation ?? entry.explanation
        entry.language = language
        return entry
    }

    private enum CodingKeys: String, CodingKey { case id, title, explanation, bundleIDs, processNames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        explanation = try c.decode(String.self, forKey: .explanation)
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        processNames = try c.decodeIfPresent([String].self, forKey: .processNames) ?? []
        let languages = try decoder.container(keyedBy: LanguageCodingKey.self)
        var translations: [String: Text] = [:]
        for key in LanguageCodingKey.translated {
            if let text = try languages.decodeIfPresent(Text.self, forKey: key) { translations[key.stringValue] = text }
        }
        self.translations = translations
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceText?.title ?? title, forKey: .title)
        try c.encode(sourceText?.explanation ?? explanation, forKey: .explanation)
        try c.encode(bundleIDs, forKey: .bundleIDs)
        try c.encode(processNames, forKey: .processNames)
        var languages = encoder.container(keyedBy: LanguageCodingKey.self)
        for (code, text) in translations.sorted(by: { $0.key < $1.key }) {
            try languages.encode(text, forKey: LanguageCodingKey(stringValue: code))
        }
    }
}

/// One-line explanations of well-known apps and processes (`apps.json`).
public struct AppCatalog: Sendable {
    public let entries: [AppCatalogEntry]
    private let byBundleID: [String: AppCatalogEntry]
    private let byProcessName: [String: AppCatalogEntry]

    public init(entries: [AppCatalogEntry]) {
        self.entries = entries
        var bundles: [String: AppCatalogEntry] = [:], names: [String: AppCatalogEntry] = [:]
        for e in entries {
            for b in e.bundleIDs where bundles[b] == nil { bundles[b] = e }
            for n in e.processNames where names[n.lowercased()] == nil { names[n.lowercased()] = e }
        }
        byBundleID = bundles; byProcessName = names
    }

    private struct File: Decodable { let entries: [AppCatalogEntry] }

    /// The text comes in `language` (`nil` ⇒ `AiryLanguage.current`).
    public static func bundled(language: String? = nil) throws -> AppCatalog {
        try bundled(executableURL: Bundle.main.executableURL, language: language)
    }

    /// Decodes apps.json with its text in `language` (`nil` ⇒ `AiryLanguage.current`).
    public static func decode(_ data: Data, language: String? = nil) throws -> AppCatalog {
        AppCatalog(entries: try JSONDecoder().decode(File.self, from: data).entries)
            .localized(to: language ?? AiryLanguage.current)
    }

    /// The same catalog with every entry's text in `language`.
    public func localized(to language: String) -> AppCatalog {
        AppCatalog(entries: entries.map { $0.localized(to: language) })
    }

    /// Same bundle lookup as `Catalog.bundled(executableURL:)`.
    public static func bundled(executableURL: URL?, searchProcessBundles: Bool = true,
                               language: String? = nil) throws -> AppCatalog {
        let dirs = Catalog.resourceSearchDirectories(executableURL: executableURL, searchProcessBundles: searchProcessBundles)
        var tried: [String] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(Catalog.bundleName)
            if tried.contains(url.path) { continue }
            tried.append(url.path)
            if let bundle = Bundle(url: url), let json = bundle.url(forResource: "apps", withExtension: "json") {
                return try decode(Data(contentsOf: json), language: language)
            }
        }
        throw CatalogError(description: String(localized: "apps.json was not found in \(Catalog.bundleName). Searched in: \(tried.joined(separator: ", "))", bundle: .airyCore))
    }

    /// First by bundle id; then by process name, case-insensitively.
    public func entry(bundleID: String?, processName: String) -> AppCatalogEntry? {
        if let bundleID, let e = byBundleID[bundleID] { return e }
        return byProcessName[processName.lowercased()]
    }
}
