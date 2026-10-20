import Foundation

/// Los ajustes tal y como los usa la app: leídos de `settings.json`, guardados al cambiarlos y,
/// si el fichero no se puede leer, fallo cerrado: nada destructivo hasta que el usuario lo
/// restablezca (nunca se machaca el fichero sin preguntar).
public struct SettingsSession: Sendable {
    /// `update` con el fichero ilegible: primero hay que restablecerlo.
    public struct Unreadable: Error, Sendable {}

    public let store: SettingsStore
    public private(set) var load: SettingsLoad

    public init(store: SettingsStore) {
        self.store = store
        load = store.load()
    }

    public var effective: AirySettings { load.effective }

    /// Motivo para negar cualquier acción destructiva ahora mismo, o `nil`.
    public var destructiveRefusal: String? {
        guard case .unreadable(let reason) = load else { return nil }
        return "Airy no puede leer sus ajustes (\(Self.trimmed(reason))); no se borra nada hasta que los restablezcas en Ajustes."
    }

    /// Texto del aviso `.settings` mientras el fichero es ilegible.
    public var unreadableNotice: String? {
        guard case .unreadable(let reason) = load else { return nil }
        return "No se pudieron leer los ajustes (\(Self.trimmed(reason))). Los agentes no pueden limpiar hasta que los restablezcas."
    }

    /// Vuelve a leer el fichero. `true` si cambió lo leído.
    @discardableResult
    public mutating func reload() -> Bool {
        let fresh = store.load()
        defer { load = fresh }
        return fresh != load
    }

    /// Lee lo último del disco, aplica `change` y lo guarda. Devuelve `true` si cambió algo que
    /// decide el riesgo (modo o lista protegida). Con el fichero ilegible lanza `Unreadable`.
    @discardableResult
    public mutating func update(_ change: (inout AirySettings) -> Void) throws -> Bool {
        reload()
        guard !load.isUnreadable else { throw Unreadable() }
        let before = load.effective
        var after = before
        change(&after)
        guard after != before else { return false }
        try store.save(after)
        load = .loaded(after)
        return after.mode != before.mode || after.protectedPaths != before.protectedPaths
    }

    /// Lo que explica la confirmación de «Restablecer ajustes» (antes de hacerlo): qué se conserva y qué se
    /// pierde. `nil` si el fichero ya se puede leer (no hay nada que restablecer).
    public mutating func resetConfirmation() -> String? {
        reload()
        guard load.isUnreadable else { return nil }
        let salvage = store.salvage()
        let s = salvage.settings
        var parts = ["Airy apartará el settings.json que no puede leer (guarda una copia junto a él) y empezará con ajustes nuevos."]
        if salvage.recoveredProtectedPaths {
            let n = s.protectedPaths.count
            parts.append(n == 0 ? "Tu lista «Proteger esto» está vacía."
                         : "Se conservará tu lista «Proteger esto» (\(n) \(n == 1 ? "ruta" : "rutas")).")
        } else {
            parts.append("Tu lista «Proteger esto» no se puede recuperar: quedará vacía.")
        }
        parts.append(s.agentsEnabled ? "Los agentes seguirán activos."
                     : "Los agentes quedarán desactivados hasta que los actives en Ajustes › Agentes.")
        return parts.joined(separator: " ")
    }

    /// Vuelve a leer el fichero y, solo si sigue ilegible, lo aparta y escribe ajustes nuevos con lo que se
    /// pudo rescatar (`SettingsStore.resetUnreadable`). `nil` si ya se podía leer: no se toca nada.
    @discardableResult
    public mutating func reset() throws -> SettingsReset? {
        reload()
        guard load.isUnreadable else { return nil }
        let result = try store.resetUnreadable()
        load = .loaded(result.settings)
        return result
    }

    private static func trimmed(_ reason: String) -> String {
        reason.hasSuffix(".") ? String(reason.dropLast()) : reason
    }
}
