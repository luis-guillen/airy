import SwiftUI
import DiskMapCore

/// Sistema visual de Airy: paleta por tipo, muelles y medidas compartidas por todas las vistas.
/// Toda animación pasa por aquí para que el movimiento sea coherente en la app.
enum Theme {
    // MARK: - Movimiento

    /// Muelle de zoom del mapa (y de cualquier cambio de nivel o selección).
    static let zoomSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// La misma curva, calculada a mano, para lo que el mapa interpola en su `Canvas`.
    static let springCurve = SpringCurve(response: 0.45, dampingFraction: 0.82)
    /// Cambio de sección en la ventana: el mismo muelle, un poco más vivo.
    static let sectionSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Números que cuentan y anillos que crecen.
    static let counterSpring = Animation.spring(response: 0.6, dampingFraction: 0.9)
    /// Respuesta táctil de botones y filas al pulsar o pasar el ratón.
    static let pressSpring = Animation.spring(response: 0.25, dampingFraction: 0.7)

    /// Retardo entre bloques de una entrada escalonada.
    static let staggerStep: Double = 0.012
    /// Toda la cascada termina de arrancar como mucho a los 0,6 s.
    static let staggerMaxDelay: Double = 0.6

    /// Entrada escalonada: 12 ms por bloque, con el retardo acotado a 0,6 s.
    static func stagger(index: Int) -> Animation {
        zoomSpring.delay(min(Double(max(index, 0)) * staggerStep, staggerMaxDelay))
    }

    // MARK: - Paleta por tipo (mismo tono en oscuro y claro)

    static func color(for kind: ContentKind) -> Color {
        switch kind {
        case .video: Color(hex: 0xFF375F)
        case .images: Color(hex: 0xFF9F0A)
        case .apps: Color(hex: 0xBF5AF2)
        case .code: Color(hex: 0x0A84FF)
        case .caches: Color(hex: 0x30D158)
        case .aiModels: Color(hex: 0x64D2FF)
        case .containers: Color(hex: 0x5E5CE6)
        case .documents: Color(hex: 0xFFD60A)
        case .system: Color(hex: 0x8E8E93)
        case .other: Color(hex: 0xAC8E68)
        }
    }

    /// Degradado sutil (más claro arriba) para bloques y segmentos del tipo.
    static func gradient(for kind: ContentKind) -> LinearGradient {
        let base = color(for: kind)
        return LinearGradient(colors: [base.mix(with: .white, by: 0.18), base],
                              startPoint: .top, endPoint: .bottom)
    }

    static func symbol(for kind: ContentKind) -> String {
        switch kind {
        case .video: "film"
        case .images: "photo"
        case .apps: "app.badge"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .caches: "archivebox"
        case .aiModels: "cpu"
        case .containers: "shippingbox"
        case .documents: "doc.text"
        case .system: "gearshape"
        case .other: "square.dashed"
        }
    }

    // MARK: - Riesgo

    static func color(for risk: Risk) -> Color {
        switch risk {
        case .safe: Color(hex: 0x30D158)
        case .yourCall: Color(hex: 0xFF9F0A)
        case .doNotTouch: Color(hex: 0xFF453A)
        }
    }

    static func symbol(for risk: Risk) -> String {
        switch risk {
        case .safe: "checkmark.seal.fill"
        case .yourCall: "hand.raised.fill"
        case .doNotTouch: "lock.fill"
        }
    }

    // MARK: - Disco

    /// "Analizado" en el anillo de uso del disco.
    static let userFiles = LinearGradient(colors: [Color(hex: 0x64D2FF), Color(hex: 0x0A84FF)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
    static let userFilesColor = Color(hex: 0x0A84FF)
    /// "Sistema y otros".
    static let systemColor = Color(hex: 0x8E8E93)
    /// "Purgable": lo que macOS libera solo cuando hace falta.
    static let purgeableColor = Color(hex: 0xC7C7CC)
    /// Acento de marca: los botones principales y el progreso del análisis.
    static let brand = LinearGradient(colors: [Color(hex: 0x64D2FF), Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: - Medidas

    static let cardRadius: CGFloat = 18
    static let smallRadius: CGFloat = 10
    static let padding: CGFloat = 20
    static let contentPadding: CGFloat = 28
    static let spacing: CGFloat = 14

    /// Locale de toda la interfaz.
    static let locale = Locale(identifier: "es_ES")

    /// "ahora mismo" durante el primer minuto (el formateador relativo diría "dentro de 0 segundos").
    static func relative(_ date: Date, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 60 ? "ahora mismo" : Format.relativeDate(date)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }
}

extension Color {
    /// Color sRGB a partir de un entero `0xRRGGBB`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
