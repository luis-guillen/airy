import Foundation

/// Límite de órdenes `airy://` aceptadas: cualquier app o página web puede abrir esos enlaces, así que
/// una ráfaga (también de `rescan`) no debe dejar la app inservible. Como mucho `limit` órdenes cada
/// `window` segundos; las de más se descartan (no cuentan).
public struct URLCommandRateLimiter: Sendable {
    public static let defaultLimit = 3
    public static let defaultWindow: TimeInterval = 10

    public let limit: Int
    public let window: TimeInterval
    private var accepted: [Date] = []

    public init(limit: Int = URLCommandRateLimiter.defaultLimit,
                window: TimeInterval = URLCommandRateLimiter.defaultWindow) {
        self.limit = max(1, limit)
        self.window = window
    }

    /// `true` si la orden que llega en `now` entra en el límite (y la cuenta).
    public mutating func allow(at now: Date = Date()) -> Bool {
        accepted.removeAll { now.timeIntervalSince($0) >= window || now < $0 }
        guard accepted.count < limit else { return false }
        accepted.append(now)
        return true
    }
}

/// Reglas y textos de una propuesta llegada por `airy://propose`. El nombre del agente lo pone quien abre
/// el enlace y no se puede verificar: se enseña y se anota como algo que «dice ser», nunca como hecho.
public enum URLProposalPolicy {
    public static let rateLimited = "Airy recibió demasiados enlaces seguidos y no hizo caso a este."
    public static let sheetOpen = "Ya hay una confirmación abierta; Airy no hizo caso a la propuesta que llegó por enlace."
    public static let busy = "Airy está limpiando; no hizo caso a la propuesta que llegó por enlace. Vuelve a pedirlo en un momento."

    /// Motivo para descartar la propuesta ahora mismo, o `nil`. Nunca sustituye una hoja ya abierta.
    public static func refusal(sheetOpen: Bool, busy: Bool) -> String? {
        if sheetOpen { return Self.sheetOpen }
        if busy { return Self.busy }
        return nil
    }

    /// Nombre que trae el enlace, limpio para enseñarlo (`nil` si no trae o está vacío).
    public static func claimedAgent(_ agent: String?) -> String? {
        guard let trimmed = agent?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Título y subtítulo del primer paso de la hoja.
    public static func warningTitle() -> String { "Propuesta recibida por enlace" }

    public static func warningSubtitle(agent: String?, reason: String) -> String {
        let who = claimedAgent(agent).map { "Dice venir de «\($0)» (Airy no puede comprobarlo)" }
            ?? "Propuesta por una app externa"
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(who) · \(why.isEmpty ? "sin motivo" : why)"
    }

    public static let warningReason = "Nada se borra hasta que lo confirmes aquí."
    public static let warningNote =
        "Cualquier app o página web puede abrir un enlace airy://. Revisa qué es antes de seguir."

    /// Contexto con el que se anota lo que el usuario confirme: el nombre como afirmación no verificada.
    public static func context(runID: UUID, agent: String?) -> OperationContext {
        .user(runID: runID, proposedBy: claimedAgent(agent), proposedVia: OperationContext.viaUnverifiedURL)
    }

    /// Ruta recortada para los avisos (la pone quien abre el enlace): como mucho `limit` caracteres.
    public static func shortPath(_ path: String, limit: Int = 80) -> String {
        guard path.count > limit else { return path }
        let keep = max(1, limit - 1)
        return "…" + path.suffix(keep)
    }

    /// `true` si el registro va en «Actividad de los agentes»: lo hizo un agente, o el usuario confirmó algo
    /// propuesto por un agente o por enlace. Las vistas previas del usuario no son operaciones.
    public static func isAgentActivity(_ record: OperationRecord) -> Bool {
        if case .agent = record.actor { return true }
        return record.proposedBy != nil || record.proposedVia != nil
    }

    /// Quién aparece en «Actividad de los agentes» para un registro.
    public static func activityAuthor(_ record: OperationRecord) -> String {
        if case .agent(let client) = record.actor { return client.isEmpty ? "Agente" : client }
        if record.proposedVia == OperationContext.viaUnverifiedURL {
            let claim = claimedAgent(record.proposedBy).map { "Por enlace (dice ser «\($0)»)" } ?? "Por enlace de una app externa"
            return claim + " · confirmado por ti"
        }
        return (record.proposedBy ?? "Agente") + " · confirmado por ti"
    }
}
