import Foundation

/// The classifier's verdict for an entry (with its paths) or for a loose path.
public struct Classification: Sendable, Equatable {
    public var risk: Risk
    /// Starts checked in the Cleanup view.
    public var preselected: Bool
    /// Matches one of the user's usage profiles (only highlighted; it never changes the risk).
    public var highlighted: Bool
    /// Protection that leaves the item as "Do not touch" (`nil` if there is none or only some paths were removed).
    public var protection: ProtectionMatch?
    /// Paths left after removing the protected ones (Trash entries); otherwise, the given paths.
    public var keptPaths: [String]
    /// Visible reasons, localized, for what changed the risk or the paths.
    public var reasons: [String]

    public init(risk: Risk, preselected: Bool, highlighted: Bool, protection: ProtectionMatch?,
                keptPaths: [String], reasons: [String]) {
        self.risk = risk; self.preselected = preselected; self.highlighted = highlighted
        self.protection = protection; self.keptPaths = keptPaths; self.reasons = reasons
    }
}

/// The single source of risk: catalog + mode + protections (hard and the user's) + per-path floors + AI.
/// Rules: the profile never touches the risk and the AI can only raise it; what is protected is always "Do not touch".
/// Only `aggressiveRisk` can lower the catalog's risk, and only for entries that regenerate,
/// never from "Do not touch" and never below the `RiskPolicy` floors.
public struct RiskClassifier: Sendable {
    private let catalog: Catalog
    private let settings: AirySettings
    private let home: String
    private let protections: HardProtections
    private let userList: ProtectList

    public init(catalog: Catalog, settings: AirySettings, home: String, protections: HardProtections = .standard) {
        self.catalog = catalog
        self.settings = settings
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.protections = protections
        userList = ProtectList(patterns: settings.protectedPaths, home: self.home)
    }

    /// The entry's risk according to the mode, before protections, floors and AI.
    public func baseRisk(of entry: CatalogEntry) -> Risk {
        guard settings.mode == .aggressive, let aggressive = entry.aggressiveRisk else { return entry.risk }
        if aggressive > entry.risk { return aggressive }
        if aggressive < entry.risk, entry.regenerates, entry.risk != .doNotTouch { return aggressive }
        return entry.risk
    }

    /// `floor`: guard from the target source (e.g. a project with keys); it only raises the risk.
    public func classify(entry: CatalogEntry, paths: [String], ai: Risk? = nil, floor: Risk? = nil) -> Classification {
        let base = baseRisk(of: entry)
        var reasons: [String] = []
        if base != entry.risk { reasons.append(String(localized: "\(settings.mode.title) mode: “\(base.label)”.", bundle: .airyCore)) }

        var kept = paths
        var protection: ProtectionMatch?
        switch entry.cleanup {
        case .trash:
            kept = []
            for path in paths {
                if let match = self.protection(for: path) {
                    reasons.append(String(localized: "Leaving out \(Format.tildePath(path, home: home)): \(match.reason)", bundle: .airyCore))
                    protection = protection ?? match
                } else {
                    kept.append(path)
                }
            }
            // If some path remains, the item stays valid without the protected ones.
            if !kept.isEmpty { protection = nil }
        case .command, .info:
            for path in paths {
                if let match = self.protection(for: path) {
                    protection = match
                    reasons.append(match.reason)
                    break
                }
            }
        }

        var risk = base
        if let ai { risk = .strictest(risk, ai) }
        if let floor { risk = .strictest(risk, floor) }
        for path in kept { risk = .strictest(risk, RiskPolicy.minimumRisk(forPath: path, home: home)) }
        if protection != nil { risk = .doNotTouch }

        return Classification(
            risk: risk, preselected: preselected(risk: risk, entry: entry), highlighted: highlighted(entry),
            protection: protection, keptPaths: kept, reasons: reasons)
    }

    /// The risk of a loose path (map, AI): its catalog entry if any, protections and floors.
    public func classify(path: String, ai: Risk? = nil) -> Classification {
        let entry = catalog.match(path: path, home: home)
        let highlighted = entry.map(highlighted) ?? false
        if let match = protection(for: path) {
            return Classification(risk: .doNotTouch, preselected: false, highlighted: highlighted, protection: match,
                                  keptPaths: [], reasons: [match.reason])
        }
        let risk = RiskPolicy.effectiveRisk(path: path, home: home, catalog: entry.map(baseRisk), ai: ai)
        return Classification(
            risk: risk, preselected: entry.map { preselected(risk: risk, entry: $0) } ?? false,
            highlighted: highlighted, protection: nil, keptPaths: [path], reasons: [])
    }

    // MARK: - Pieces

    /// Hard protection first, then the user's; both cover the path, what is inside and the parents.
    private func protection(for path: String) -> ProtectionMatch? {
        let canonical = RiskPolicy.canonical(path)
        if let hard = protections.match(canonicalPath: canonical, home: home, catalog: catalog) { return hard }
        if let pattern = userList.match(canonical) {
            // A parent of what the user protected: only the folder itself is kept (display only).
            let child = (canonical == "/" ? "" : canonical) + "/" + HardProtections.contentsProbeName
            return ProtectionMatch(source: .user, pattern: pattern,
                                   reason: String(localized: "You protected it (\(pattern)).", bundle: .airyCore),
                                   scope: userList.match(child) == nil ? .folderOnly : .folderAndContents)
        }
        return nil
    }

    private func highlighted(_ entry: CatalogEntry) -> Bool {
        !Set(entry.profiles).isDisjoint(with: settings.profiles)
    }

    private func preselected(risk: Risk, entry: CatalogEntry) -> Bool {
        risk == .safe || (settings.mode == .aggressive && risk == .yourCall && entry.preselectInAggressive)
    }
}
