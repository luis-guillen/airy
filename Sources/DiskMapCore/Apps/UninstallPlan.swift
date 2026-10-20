import Foundation

/// Un resto de una app: una ruta de su carpeta personal (o de `/Library`, solo informativa) o un recibo de
/// instalación.
public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case appSupport, caches, containers, preferences, byHost, savedState, httpStorage, logs, launchAgent, webKit,
             cookies, applicationScripts, autosave, syncedPreferences, plugin, receipt, systemLocation
    }

    /// En `.receipt`: el identificador del paquete (`pkgid`).
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    public let risk: Risk
    public let preselected: Bool
    public let matchedByName: Bool
    /// Por qué esta etiqueta (español).
    public let reason: String
    /// Solo `.launchAgent`: el `Label` del plist.
    public let launchLabel: String?
    public var id: String { kind.rawValue + ":" + path }
    public var canSelect: Bool { risk != .doNotTouch }

    public init(path: String, kind: Kind, bytes: Int64, risk: Risk, preselected: Bool, matchedByName: Bool,
                reason: String, launchLabel: String?) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.risk = risk
        // Lo rojo nunca sale seleccionado.
        self.preselected = preselected && risk != .doNotTouch
        self.matchedByName = matchedByName
        self.reason = reason
        self.launchLabel = launchLabel
    }
}

/// Lo que costaría desinstalar una app: el `.app` y sus restos, con el tamaño real.
public struct UninstallPlan: Sendable, Equatable, Identifiable {
    public let app: AppRecord
    public let appBytes: Int64
    /// Ordenados por riesgo ascendente, bytes descendentes y ruta.
    public let leftovers: [Leftover]
    /// Por qué Airy no desinstala esta app, o `nil`.
    public let refusal: String?
    /// Ruta de otra copia instalada con el mismo identificador (sus restos quedan solo informativos).
    public let sharedWith: String?
    /// `false` si se agotó el tiempo de medir: lo no medido queda con 0 bytes.
    public let sizeComplete: Bool
    public var id: String { app.path }

    public init(app: AppRecord, appBytes: Int64, leftovers: [Leftover], refusal: String?, sharedWith: String?,
                sizeComplete: Bool) {
        self.app = app
        self.appBytes = appBytes
        self.leftovers = leftovers.sorted {
            if $0.risk != $1.risk { return $0.risk < $1.risk }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
        self.refusal = refusal
        self.sharedWith = sharedWith
        self.sizeComplete = sizeComplete
    }

    /// Bytes de los restos que se pueden seleccionar.
    public var leftoverBytes: Int64 {
        leftovers.filter(\.canSelect).reduce(0) { $0 + $1.bytes }
    }

    /// El `.app` más todos los restos seleccionables.
    public var realBytes: Int64 { appBytes + leftoverBytes }

    public var defaultSelection: Set<String> {
        Set(leftovers.filter { $0.preselected && $0.canSelect }.map(\.id))
    }

    /// El `.app` más los restos seleccionados que se pueden seleccionar (lo rojo nunca suma).
    public func bytes(selected: Set<String>) -> Int64 {
        appBytes + leftovers.filter { $0.canSelect && selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
}
