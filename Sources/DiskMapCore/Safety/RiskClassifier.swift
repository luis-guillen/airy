import Foundation

/// Veredicto del clasificador para una ficha (con sus rutas) o para una ruta suelta.
public struct Classification: Sendable, Equatable {
    public var risk: Risk
    /// Se marca de entrada en la vista Limpieza.
    public var preselected: Bool
    /// Coincide con algún perfil de uso del usuario (solo se destaca; nunca cambia el riesgo).
    public var highlighted: Bool
    /// Protección que deja el elemento en «No tocar» (`nil` si no la hay o solo se quitaron algunas rutas).
    public var protection: ProtectionMatch?
    /// Rutas que quedan tras quitar las protegidas (fichas de Papelera); el resto, las rutas dadas.
    public var keptPaths: [String]
    /// Motivos visibles, en español, de lo que ha cambiado el riesgo o las rutas.
    public var reasons: [String]

    public init(risk: Risk, preselected: Bool, highlighted: Bool, protection: ProtectionMatch?,
                keptPaths: [String], reasons: [String]) {
        self.risk = risk; self.preselected = preselected; self.highlighted = highlighted
        self.protection = protection; self.keptPaths = keptPaths; self.reasons = reasons
    }
}

/// Única fuente del riesgo: catálogo + modo + protecciones (duras y del usuario) + suelos por ruta + IA.
/// Reglas: el perfil nunca toca el riesgo y la IA solo puede subirlo; lo protegido siempre es «No tocar».
/// Solo `aggressiveRisk` puede bajar el riesgo del catálogo, y solo en fichas que se regeneran,
/// nunca desde «No tocar» y nunca por debajo de los suelos de `RiskPolicy`.
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

    /// Riesgo de la ficha según el modo, antes de protecciones, suelos e IA.
    public func baseRisk(of entry: CatalogEntry) -> Risk {
        guard settings.mode == .aggressive, let aggressive = entry.aggressiveRisk else { return entry.risk }
        if aggressive > entry.risk { return aggressive }
        if aggressive < entry.risk, entry.regenerates, entry.risk != .doNotTouch { return aggressive }
        return entry.risk
    }

    public func classify(entry: CatalogEntry, paths: [String], ai: Risk? = nil) -> Classification {
        let base = baseRisk(of: entry)
        var reasons: [String] = []
        if base != entry.risk { reasons.append("Modo \(settings.mode.title): «\(base.label)».") }

        var kept = paths
        var protection: ProtectionMatch?
        switch entry.cleanup {
        case .trash:
            kept = []
            for path in paths {
                if let match = self.protection(for: path) {
                    reasons.append("Se deja fuera \(Format.tildePath(path, home: home)): \(match.reason)")
                    protection = protection ?? match
                } else {
                    kept.append(path)
                }
            }
            // Si queda alguna ruta, el elemento sigue siendo válido sin las protegidas.
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
        for path in kept { risk = .strictest(risk, RiskPolicy.minimumRisk(forPath: path, home: home)) }
        if protection != nil { risk = .doNotTouch }

        return Classification(
            risk: risk, preselected: preselected(risk: risk, entry: entry), highlighted: highlighted(entry),
            protection: protection, keptPaths: kept, reasons: reasons)
    }

    /// Riesgo de una ruta suelta (mapa, IA): su ficha del catálogo si la hay, protecciones y suelos.
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

    // MARK: - Piezas

    /// Protección dura primero, luego la del usuario; ambas cubren la ruta, lo de dentro y las superiores.
    private func protection(for path: String) -> ProtectionMatch? {
        let canonical = RiskPolicy.canonical(path)
        if let hard = protections.match(canonicalPath: canonical, home: home, catalog: catalog) { return hard }
        if let pattern = userList.match(canonical) {
            return ProtectionMatch(source: .user, pattern: pattern, reason: "Lo has protegido tú (\(pattern)).")
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
