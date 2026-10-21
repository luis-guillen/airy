import Foundation

/// Un fichero que el usuario puede revisar y mandar a la Papelera (Grandes y viejos, Tipos de archivo).
public struct ActionableFile: Sendable, Equatable, Identifiable {
    public let path: String, name: String, bytes: Int64, kind: ContentKind
    public let lastModified: Date?, lastOpened: Date?
    public let risk: Risk, protection: ProtectionMatch?, reasons: [String]
    /// `true` si Spotlight no contestó a tiempo: la fecha de último uso se desconoce (no es «antiguo»).
    public let openDateUnknown: Bool
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
    /// La más reciente de `lastModified` y `lastOpened`.
    public var lastActivity: Date? {
        switch (lastModified, lastOpened) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    public init(path: String, name: String, bytes: Int64, kind: ContentKind, lastModified: Date?, lastOpened: Date?,
                risk: Risk, protection: ProtectionMatch?, reasons: [String], openDateUnknown: Bool = false) {
        self.path = path; self.name = name; self.bytes = bytes; self.kind = kind
        self.lastModified = lastModified; self.lastOpened = lastOpened
        self.risk = risk; self.protection = protection; self.reasons = reasons
        self.openDateUnknown = openDateUnknown
    }

    /// risk = classifier.classify(path:).risk; si la ficha del catálogo no existe o no `regenerates`, al menos
    /// `.yourCall`; `gate.validate` falla ⇒ `.doNotTouch` con la protección y los motivos del rechazo.
    public static func make(node: FileNode, classifier: RiskClassifier, catalog: Catalog?, gate: PathGate,
                            lastOpened: Date?, home: String = NSHomeDirectory(),
                            openDateUnknown: Bool = false) -> ActionableFile {
        let path = node.path
        let classification = classifier.classify(path: path)
        var risk = classification.risk
        var protection = classification.protection
        var reasons = classification.reasons
        if let entry = catalog?.match(path: path, home: home) {
            if !entry.regenerates { risk = .strictest(risk, .yourCall) }
        } else {
            risk = .strictest(risk, .yourCall)
        }
        if protection == nil, case let .failure(refusal) = gate.validate(path) {
            protection = ProtectionMatch(source: .airy, pattern: path, reason: refusal.reason)
            reasons.append(refusal.reason)
        }
        if protection != nil { risk = .doNotTouch }
        if openDateUnknown { reasons.append("No se pudo saber cuándo se abrió por última vez.") }
        return ActionableFile(path: path, name: node.name, bytes: node.allocatedSize, kind: node.kind,
                              lastModified: node.lastModified, lastOpened: lastOpened, risk: risk,
                              protection: protection, reasons: reasons, openDateUnknown: openDateUnknown)
    }
}

/// Selección compartida por las secciones de ficheros: nunca contiene rojo ni protegido.
public struct FileSelection: Sendable, Equatable {
    public private(set) var ids: Set<String>
    public init() { ids = [] }

    public mutating func toggle(_ file: ActionableFile) {
        guard file.canSelect else { return }
        if ids.remove(file.id) == nil { ids.insert(file.id) }
    }

    public mutating func selectAllGreen(_ files: [ActionableFile]) {
        for file in files where file.canSelect && file.risk == .safe { ids.insert(file.id) }
    }

    /// Verde + ámbar seleccionable.
    public mutating func selectAll(_ files: [ActionableFile]) {
        for file in files where file.canSelect && file.risk != .doNotTouch { ids.insert(file.id) }
    }

    public mutating func clear() { ids = [] }

    /// Quita lo que ya no está en `files` o ya no se puede marcar.
    public mutating func prune(to files: [ActionableFile]) {
        let valid = Set(files.filter(\.canSelect).map(\.id))
        ids.formIntersection(valid)
    }

    public func selected(in files: [ActionableFile]) -> [ActionableFile] {
        files.filter { ids.contains($0.id) && $0.canSelect }
    }

    public func bytes(in files: [ActionableFile]) -> Int64 {
        selected(in: files).reduce(0) { $0 + $1.bytes }
    }

    /// Verde, ámbar y rojo, sin grupos vacíos.
    public static func groups(_ files: [ActionableFile]) -> [(risk: Risk, files: [ActionableFile])] {
        [Risk.safe, .yourCall, .doNotTouch].compactMap { risk in
            let group = files.filter { $0.risk == risk }
            return group.isEmpty ? nil : (risk, group)
        }
    }
}
