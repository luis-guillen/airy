import Foundation

/// How a catalog entry is cleaned.
/// `command.executable` is always a bare name (e.g. "docker"); the app resolves it through PATH.
public enum CleanupMethod: Codable, Sendable, Equatable {
    case trash
    case command(executable: String, arguments: [String], sizeProbe: [String]?)
    /// Display only; no action.
    case info

    private enum CodingKeys: String, CodingKey { case type, executable, arguments, sizeProbe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "trash": self = .trash
        case "info": self = .info
        case "command":
            self = .command(
                executable: try c.decode(String.self, forKey: .executable),
                arguments: try c.decode([String].self, forKey: .arguments),
                sizeProbe: try c.decodeIfPresent([String].self, forKey: .sizeProbe))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown cleanup type: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash: try c.encode("trash", forKey: .type)
        case .info: try c.encode("info", forKey: .type)
        case .command(let executable, let arguments, let sizeProbe):
            try c.encode("command", forKey: .type)
            try c.encode(executable, forKey: .executable)
            try c.encode(arguments, forKey: .arguments)
            try c.encodeIfPresent(sizeProbe, forKey: .sizeProbe)
        }
    }
}

extension CleanupMethod {
    /// Exact command argument that is replaced by each of the item's targets
    /// (`CleanupItem.targets`); the command runs once per target.
    public static let targetPlaceholder = "{target}"

    /// `true` if it is a command with some argument equal to `targetPlaceholder`.
    public var usesTargets: Bool {
        if case .command(_, let arguments, _) = self { return arguments.contains(Self.targetPlaceholder) }
        return false
    }
}

/// Keep the newest versions in each parent folder (and the active one, if any).
public struct RetentionRule: Codable, Sendable, Equatable {
    /// ≥ 1, per parent folder.
    public var keepNewest: Int
    /// Link (e.g. `~/.local/bin/claude`): the version it points to is always kept.
    public var activeLink: String?

    public init(keepNewest: Int, activeLink: String? = nil) {
        self.keepNewest = keepNewest; self.activeLink = activeLink
    }

    private enum CodingKeys: String, CodingKey { case keepNewest, activeLink }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepNewest = try c.decode(Int.self, forKey: .keepNewest)
        guard keepNewest >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .keepNewest, in: c, debugDescription: "keepNewest must be at least 1")
        }
        activeLink = try c.decodeIfPresent(String.self, forKey: .activeLink)
    }
}

/// An entry's own source of targets (instead of its patterns). JSON `{"type": "...", ...}`.
public enum DiscoveryKind: Codable, Sendable, Equatable {
    case projectArtifacts(names: [String], cachedirTag: Bool)
    case installers
    case simulatorRuntimes
    case appSupportCaches
    case docker
    /// Installed versions of a manager's development tools (`{"type":"toolchains","manager":"pyenv"}`).
    case toolchains(manager: ToolchainManager)
    /// System installs (Xcode, /Library): informational only.
    case toolchainSystemInfo
    /// Node packages repeated across projects: informational only.
    case dependencyDuplicates
    /// Old entries directly inside the user's temporary folder (`NSTemporaryDirectory()`).
    case staleTemporaryFiles
    /// Large archives (.zip, .dmg, .tar…) next to a folder with the same name.
    case extractedArchives
    /// Git worktrees of found projects whose branch is merged and that have no changes.
    case gitWorktrees

    private enum CodingKeys: String, CodingKey { case type, names, cachedirTag, manager }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "projectArtifacts":
            self = .projectArtifacts(
                names: try c.decode([String].self, forKey: .names),
                cachedirTag: try c.decodeIfPresent(Bool.self, forKey: .cachedirTag) ?? false)
        case "installers": self = .installers
        case "simulatorRuntimes": self = .simulatorRuntimes
        case "appSupportCaches": self = .appSupportCaches
        case "docker": self = .docker
        case "toolchains": self = .toolchains(manager: try c.decode(ToolchainManager.self, forKey: .manager))
        case "toolchainSystemInfo": self = .toolchainSystemInfo
        case "dependencyDuplicates": self = .dependencyDuplicates
        case "staleTemporaryFiles": self = .staleTemporaryFiles
        case "extractedArchives": self = .extractedArchives
        case "gitWorktrees": self = .gitWorktrees
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown target source: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectArtifacts(let names, let cachedirTag):
            try c.encode("projectArtifacts", forKey: .type)
            try c.encode(names, forKey: .names)
            try c.encode(cachedirTag, forKey: .cachedirTag)
        case .installers: try c.encode("installers", forKey: .type)
        case .simulatorRuntimes: try c.encode("simulatorRuntimes", forKey: .type)
        case .appSupportCaches: try c.encode("appSupportCaches", forKey: .type)
        case .docker: try c.encode("docker", forKey: .type)
        case .toolchains(let manager):
            try c.encode("toolchains", forKey: .type)
            try c.encode(manager, forKey: .manager)
        case .toolchainSystemInfo: try c.encode("toolchainSystemInfo", forKey: .type)
        case .dependencyDuplicates: try c.encode("dependencyDuplicates", forKey: .type)
        case .staleTemporaryFiles: try c.encode("staleTemporaryFiles", forKey: .type)
        case .extractedArchives: try c.encode("extractedArchives", forKey: .type)
        case .gitWorktrees: try c.encode("gitWorktrees", forKey: .type)
        }
    }
}

/// Version manager of a development tool (each with its own way of removing a version).
public enum ToolchainManager: String, Codable, Sendable, CaseIterable {
    case pyenv, conda, nvm, fnm, volta, asdf, rbenv, rvm, sdkman, rustup, goSDK, homebrew, system
}

extension Risk {
    /// Text names used in catalog.json and in the AI's JSON.
    public var jsonName: String {
        switch self {
        case .safe: "safe"
        case .yourCall: "yourCall"
        case .doNotTouch: "doNotTouch"
        }
    }

    public init?(jsonName: String) {
        switch jsonName {
        case "safe": self = .safe
        case "yourCall": self = .yourCall
        case "doNotTouch": self = .doNotTouch
        default: return nil
        }
    }
}

/// App section an entry belongs to: Cleanup (default) or Maintenance (Performance).
public enum CatalogSection: String, Codable, Sendable { case cleanup, maintenance }

/// An entry's displayed text in one language: the object under a language code (e.g. `"es"`) in a
/// catalog.json entry. A `nil` field keeps the English one.
public struct CatalogEntryText: Codable, Sendable, Equatable {
    public var title: String?
    public var explanation: String?
    public var whoCreatesIt: String?
    public var shortReason: String?
    public var reviewHint: String?

    public init(title: String? = nil, explanation: String? = nil, whoCreatesIt: String? = nil,
                shortReason: String? = nil, reviewHint: String? = nil) {
        self.title = title; self.explanation = explanation; self.whoCreatesIt = whoCreatesIt
        self.shortReason = shortReason; self.reviewHint = reviewHint
    }
}

/// Coding key for a language code (`"es"`) next to an entry's fixed keys.
struct LanguageCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// Every supported language except the source one (its text lives in the base fields).
    static var translated: [LanguageCodingKey] {
        AiryLanguage.supported.filter { $0 != AiryLanguage.source }.map(LanguageCodingKey.init(stringValue:))
    }
}

public struct CatalogEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var explanation: String
    public var whoCreatesIt: String
    public var regenerates: Bool
    public var risk: Risk
    public var kind: ContentKind
    /// Patterns with `~` and `*` (`*` does not cross component boundaries).
    public var paths: [String]
    public var cleanup: CleanupMethod
    /// Bundle IDs of apps that must be closed before cleaning.
    public var mustBeClosed: [String]
    /// String to look for in projects; `{name}` = name of the matched folder, transformed:
    /// the `models--` / `datasets--` prefix is dropped and `--` becomes `/` (Hugging Face).
    /// See `referenceNeedle(forMatchedFolder:)`.
    public var referenceCheck: String?
    /// `true` if the official command only removes part (e.g. `pnpm store prune` keeps what
    /// projects use): the UI shows "up to X" and does not count it as safe in "You can free".
    public var partialCleanup: Bool
    /// Risk in Aggressive mode. It can only lower `risk` if the entry regenerates and is not "Do not touch";
    /// raising it is always allowed (see `RiskClassifier.baseRisk(of:)`). `nil` ⇒ same as `risk`.
    public var aggressiveRisk: Risk?
    /// In Aggressive mode, it starts selected even if it is "Up to you".
    public var preselectInAggressive: Bool
    /// Usage profiles for which this entry is highlighted (they never change the risk).
    public var profiles: [UsageProfile]
    /// Processes that must be closed before cleaning (filled in by task 6).
    public var processNames: [String]
    /// One sentence: why it is green or red, or what you lose if it is amber.
    public var shortReason: String?
    /// One item per matched path (instead of one per entry).
    public var perMatch: Bool
    /// Last components that are never included (e.g. `.DS_Store`).
    public var except: [String]
    /// Only paths with nothing changed inside for at least this many days.
    public var staleAfterDays: Int?
    /// Minimum size per item.
    public var minimumBytes: Int64?
    /// Keep the newest versions (and the active one) in each parent folder.
    public var retention: RetentionRule?
    /// Own source of targets, instead of the patterns.
    public var discovery: DiscoveryKind?
    /// Informational entries: what you should do yourself.
    public var reviewHint: String?
    /// `.maintenance`: only `MaintenanceScanner` sees it (Cleanup, `Catalog.match` and the MCP ignore it).
    public var section: CatalogSection
    /// Displayed text per language code other than English (the `"es"` object in catalog.json).
    public var translations: [String: CatalogEntryText]
    /// Language of `title`, `explanation`, `whoCreatesIt`, `shortReason` and `reviewHint` (`"en"` as decoded).
    public private(set) var language: String = AiryLanguage.source
    /// The English text while the entry is shown in another language (for `localized(to:)` and encoding).
    private var sourceText: CatalogEntryText?

    public init(
        id: String, title: String, explanation: String, whoCreatesIt: String, regenerates: Bool,
        risk: Risk, kind: ContentKind, paths: [String], cleanup: CleanupMethod,
        mustBeClosed: [String] = [], referenceCheck: String? = nil, partialCleanup: Bool = false,
        aggressiveRisk: Risk? = nil, preselectInAggressive: Bool = false, profiles: [UsageProfile] = [],
        processNames: [String] = [], shortReason: String? = nil, perMatch: Bool = false, except: [String] = [],
        staleAfterDays: Int? = nil, minimumBytes: Int64? = nil, retention: RetentionRule? = nil,
        discovery: DiscoveryKind? = nil, reviewHint: String? = nil, section: CatalogSection = .cleanup,
        translations: [String: CatalogEntryText] = [:]
    ) {
        self.id = id; self.title = title; self.explanation = explanation
        self.whoCreatesIt = whoCreatesIt; self.regenerates = regenerates; self.risk = risk
        self.kind = kind; self.paths = paths; self.cleanup = cleanup
        self.mustBeClosed = mustBeClosed; self.referenceCheck = referenceCheck
        self.partialCleanup = partialCleanup
        self.aggressiveRisk = aggressiveRisk; self.preselectInAggressive = preselectInAggressive
        self.profiles = profiles; self.processNames = processNames
        self.shortReason = shortReason; self.perMatch = perMatch; self.except = except
        self.staleAfterDays = staleAfterDays; self.minimumBytes = minimumBytes; self.retention = retention
        self.discovery = discovery; self.reviewHint = reviewHint; self.section = section
        self.translations = translations
    }

    /// The same entry with its displayed text in `language` (fields without a translation stay in English).
    /// Ids, paths, risks and commands never change.
    public func localized(to language: String) -> CatalogEntry {
        let language = AiryLanguage.resolve([language])
        var entry = self
        if let source = entry.sourceText {
            entry.apply(source)
            entry.shortReason = source.shortReason
            entry.reviewHint = source.reviewHint
            entry.sourceText = nil
            entry.language = AiryLanguage.source
        }
        guard language != AiryLanguage.source, let text = translations[language] else { return entry }
        entry.sourceText = CatalogEntryText(title: entry.title, explanation: entry.explanation,
                                            whoCreatesIt: entry.whoCreatesIt, shortReason: entry.shortReason,
                                            reviewHint: entry.reviewHint)
        entry.apply(text)
        entry.language = language
        return entry
    }

    private mutating func apply(_ text: CatalogEntryText) {
        if let v = text.title { title = v }
        if let v = text.explanation { explanation = v }
        if let v = text.whoCreatesIt { whoCreatesIt = v }
        if let v = text.shortReason { shortReason = v }
        if let v = text.reviewHint { reviewHint = v }
    }

    /// Search string for a given folder (e.g. `models--a--b` ⇒ `a/b`).
    public func referenceNeedle(forMatchedFolder folder: String) -> String? {
        guard let referenceCheck else { return nil }
        var name = (folder as NSString).lastPathComponent
        for prefix in ["models--", "datasets--"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        name = name.replacingOccurrences(of: "--", with: "/")
        return referenceCheck.replacingOccurrences(of: "{name}", with: name)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, explanation, whoCreatesIt, regenerates, risk, kind, paths, cleanup
        case mustBeClosed, referenceCheck, partialCleanup
        case aggressiveRisk, preselectInAggressive, profiles, processNames
        case shortReason, perMatch, except, staleAfterDays, minimumBytes, retention, discovery, reviewHint
        case section
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        explanation = try c.decode(String.self, forKey: .explanation)
        whoCreatesIt = try c.decode(String.self, forKey: .whoCreatesIt)
        regenerates = try c.decode(Bool.self, forKey: .regenerates)
        let riskName = try c.decode(String.self, forKey: .risk)
        guard let risk = Risk(jsonName: riskName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .risk, in: c, debugDescription: "Unknown risk: \(riskName)")
        }
        self.risk = risk
        let kindName = try c.decode(String.self, forKey: .kind)
        guard let kind = ContentKind(rawValue: kindName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown kind: \(kindName)")
        }
        self.kind = kind
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        cleanup = try c.decode(CleanupMethod.self, forKey: .cleanup)
        mustBeClosed = try c.decodeIfPresent([String].self, forKey: .mustBeClosed) ?? []
        referenceCheck = try c.decodeIfPresent(String.self, forKey: .referenceCheck)
        partialCleanup = try c.decodeIfPresent(Bool.self, forKey: .partialCleanup) ?? false
        if let name = try c.decodeIfPresent(String.self, forKey: .aggressiveRisk) {
            guard let aggressive = Risk(jsonName: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .aggressiveRisk, in: c, debugDescription: "Unknown aggressive risk: \(name)")
            }
            aggressiveRisk = aggressive
        } else {
            aggressiveRisk = nil
        }
        preselectInAggressive = try c.decodeIfPresent(Bool.self, forKey: .preselectInAggressive) ?? false
        // Unknown profiles (from a future version) are ignored: they only serve for highlighting.
        profiles = (try c.decodeIfPresent([String].self, forKey: .profiles) ?? []).compactMap(UsageProfile.init(rawValue:))
        processNames = try c.decodeIfPresent([String].self, forKey: .processNames) ?? []
        shortReason = try c.decodeIfPresent(String.self, forKey: .shortReason)
        perMatch = try c.decodeIfPresent(Bool.self, forKey: .perMatch) ?? false
        except = try c.decodeIfPresent([String].self, forKey: .except) ?? []
        staleAfterDays = try c.decodeIfPresent(Int.self, forKey: .staleAfterDays)
        minimumBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumBytes)
        retention = try c.decodeIfPresent(RetentionRule.self, forKey: .retention)
        discovery = try c.decodeIfPresent(DiscoveryKind.self, forKey: .discovery)
        reviewHint = try c.decodeIfPresent(String.self, forKey: .reviewHint)
        section = try c.decodeIfPresent(CatalogSection.self, forKey: .section) ?? .cleanup
        let languages = try decoder.container(keyedBy: LanguageCodingKey.self)
        var translations: [String: CatalogEntryText] = [:]
        for key in LanguageCodingKey.translated {
            if let text = try languages.decodeIfPresent(CatalogEntryText.self, forKey: key) {
                translations[key.stringValue] = text
            }
        }
        self.translations = translations
    }

    public func encode(to encoder: Encoder) throws {
        // The base fields are always English; translations go under their language code.
        let english = sourceText
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(english?.title ?? title, forKey: .title)
        try c.encode(english?.explanation ?? explanation, forKey: .explanation)
        try c.encode(english?.whoCreatesIt ?? whoCreatesIt, forKey: .whoCreatesIt)
        try c.encode(regenerates, forKey: .regenerates)
        try c.encode(risk.jsonName, forKey: .risk)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(paths, forKey: .paths)
        try c.encode(cleanup, forKey: .cleanup)
        try c.encode(mustBeClosed, forKey: .mustBeClosed)
        try c.encodeIfPresent(referenceCheck, forKey: .referenceCheck)
        if partialCleanup { try c.encode(true, forKey: .partialCleanup) }
        try c.encodeIfPresent(aggressiveRisk?.jsonName, forKey: .aggressiveRisk)
        if preselectInAggressive { try c.encode(true, forKey: .preselectInAggressive) }
        if !profiles.isEmpty { try c.encode(profiles.map(\.rawValue), forKey: .profiles) }
        if !processNames.isEmpty { try c.encode(processNames, forKey: .processNames) }
        try c.encodeIfPresent(english == nil ? shortReason : english?.shortReason, forKey: .shortReason)
        if perMatch { try c.encode(true, forKey: .perMatch) }
        if !except.isEmpty { try c.encode(except, forKey: .except) }
        try c.encodeIfPresent(staleAfterDays, forKey: .staleAfterDays)
        try c.encodeIfPresent(minimumBytes, forKey: .minimumBytes)
        try c.encodeIfPresent(retention, forKey: .retention)
        try c.encodeIfPresent(discovery, forKey: .discovery)
        try c.encodeIfPresent(english == nil ? reviewHint : english?.reviewHint, forKey: .reviewHint)
        if section == .maintenance { try c.encode(section, forKey: .section) }
        var languages = encoder.container(keyedBy: LanguageCodingKey.self)
        for (code, text) in translations.sorted(by: { $0.key < $1.key }) {
            try languages.encode(text, forKey: LanguageCodingKey(stringValue: code))
        }
    }
}

public struct CatalogError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public struct Catalog: Sendable {
    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) { self.entries = entries }

    private struct File: Decodable { let entries: [CatalogEntry] }

    /// Decodes catalog.json with its text in `language` (`nil` ⇒ `AiryLanguage.current`).
    public static func decode(_ data: Data, language: String? = nil) throws -> Catalog {
        Catalog(entries: try JSONDecoder().decode(File.self, from: data).entries)
            .localized(to: language ?? AiryLanguage.current)
    }

    /// The same catalog with every entry's text in `language` (see `CatalogEntry.localized(to:)`).
    public func localized(to language: String) -> Catalog {
        Catalog(entries: entries.map { $0.localized(to: language) })
    }

    static let bundleName = "Airy_DiskMapCore.bundle"

    private final class BundleToken {}

    /// Looks the resource bundle up by path (without `Bundle.module`, which aborts if missing):
    /// the .app's Contents/Resources, the main bundle's root and the running binary's folder.
    /// The text comes in `language` (`nil` ⇒ `AiryLanguage.current`).
    public static func bundled(language: String? = nil) throws -> Catalog {
        try bundled(executableURL: Bundle.main.executableURL, language: language)
    }

    /// Folders where `Airy_DiskMapCore.bundle` is looked for (shared with `AppCatalog`).
    static func resourceSearchDirectories(executableURL: URL?, searchProcessBundles: Bool) -> [URL] {
        var dirs: [URL] = []
        if let e = executableURL {
            let folder = e.deletingLastPathComponent()
            dirs.append(folder.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true))
            dirs.append(folder)
        }
        if searchProcessBundles {
            if let r = Bundle.main.resourceURL { dirs.append(r) }
            dirs.append(Bundle.main.bundleURL)
            dirs.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent())
            for b in Bundle.allBundles + Bundle.allFrameworks { dirs.append(b.bundleURL.deletingLastPathComponent()) }
        }
        return dirs
    }

    /// Like `bundled()`, with the given executable: looks in its folder and in `<executable>/../../Resources`
    /// (`airy-mcp` in `Airy.app/Contents/MacOS/`). `searchProcessBundles: false` (tests) looks only there.
    public static func bundled(executableURL: URL?, searchProcessBundles: Bool = true,
                               language: String? = nil) throws -> Catalog {
        let dirs = resourceSearchDirectories(executableURL: executableURL, searchProcessBundles: searchProcessBundles)
        var tried: [String] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(bundleName)
            if tried.contains(url.path) { continue }
            tried.append(url.path)
            if let bundle = Bundle(url: url), let json = bundle.url(forResource: "catalog", withExtension: "json") {
                return try decode(try Data(contentsOf: json), language: language)
            }
        }
        throw CatalogError(description: String(localized: "catalog.json was not found in \(bundleName). Searched in: \(tried.joined(separator: ", "))", bundle: .airyCore))
    }

    public func entry(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// Most specific entry (longest literal pattern) that contains or equals `path`.
    /// Case-insensitive, after collapsing `.`, `..` and `//`.
    public func match(path: String, home: String) -> CatalogEntry? {
        let pathParts = Self.components(RiskPolicy.canonical(path))
        var best: (entry: CatalogEntry, score: Int)?
        for entry in entries where entry.section != .maintenance {
            for pattern in entry.paths {
                let expanded = RiskPolicy.canonical(Self.expand(pattern, home: home))
                let patParts = Self.components(expanded)
                guard patParts.count <= pathParts.count else { continue }
                let ok = zip(patParts, pathParts).allSatisfy { Self.componentMatches($0, $1) }
                guard ok else { continue }
                let score = expanded.filter { $0 != "*" }.count
                if best == nil || score > best!.score { best = (entry, score) }
            }
        }
        return best?.entry
    }

    private static func expand(_ pattern: String, home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if pattern == "~" { return base }
        if pattern.hasPrefix("~/") { return base + String(pattern.dropFirst(1)) }
        return pattern
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        if !pattern.contains("*") { return pattern == name }
        return fnmatch(pattern, name, 0) == 0
    }
}
