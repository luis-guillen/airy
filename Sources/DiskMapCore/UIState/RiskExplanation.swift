import Foundation

/// Una frase en español que explica por qué una fila es verde, ámbar o roja. Una sola fuente para la lista, la
/// tarjeta del Mapa, la hoja de confirmación y el MCP.
public enum RiskExplanation {
    /// En `shortReason`, «{size}» se sustituye por el tamaño del elemento («Tendrías que volver a descargar
    /// {size}.» ⇒ «… descargar 4,2 GB.»); sin tamaño, «el contenido».
    public static let sizePlaceholder = "{size}"

    /// Prioridad (la primera que aplique): doNotTouch ⇒ motivo, protección, ficha, texto fijo; yourCall ⇒ motivo,
    /// ficha, «está en tus carpetas personales», tamaño; safe ⇒ ficha, «Se vuelve a crear sola.».
    public static func why(risk: Risk, entry: CatalogEntry?, protection: ProtectionMatch?, reason: String?,
                           bytes: Int64, personal: Bool) -> String {
        let short = entry?.shortReason.map { expand($0, bytes: bytes) }
        switch risk {
        case .doNotTouch:
            return nonEmpty(reason) ?? protection?.reason ?? short ?? "Es del sistema o guarda datos que no se recuperan."
        case .yourCall:
            if let text = nonEmpty(reason) ?? short { return text }
            if personal { return "Está en tus carpetas personales: solo tú sabes si lo necesitas." }
            if bytes > 0 { return "Pierdes lo que hay dentro (\(Format.bytes(bytes))); no vuelve solo." }
            return "Pierdes lo que hay dentro; no vuelve solo."
        case .safe:
            return short ?? "Se vuelve a crear sola."
        }
    }

    /// Para un elemento de la lista. Las filas de «Solo revisar» empiezan por el consejo de su ficha.
    public static func why(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String {
        if CleanupBoard.isReviewOnly(item), let hint = item.entry.reviewHint, !hint.isEmpty { return hint }
        let personal = item.paths.contains { RiskPolicy.minimumRisk(forPath: $0, home: home) == .yourCall }
        return why(risk: item.risk, entry: item.entry, protection: item.protection, reason: item.riskReason,
                   bytes: item.bytes, personal: personal)
    }

    static func expand(_ text: String, bytes: Int64) -> String {
        text.replacingOccurrences(of: sizePlaceholder, with: bytes > 0 ? Format.bytes(bytes) : "el contenido")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
