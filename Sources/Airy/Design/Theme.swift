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

    static func color(for kind: ContentKind) -> Color { Color(hex: AiryPalette.kind(kind)) }

    /// Degradado sutil (más claro arriba) para bloques y segmentos del tipo.
    static func gradient(for kind: ContentKind) -> LinearGradient {
        let base = color(for: kind)
        return LinearGradient(colors: [base.mix(with: .white, by: 0.18), base],
                              startPoint: .top, endPoint: .bottom)
    }

    /// Tinta AA del tipo para texto e iconos en primer plano (el color puro solo sirve de relleno).
    static func ink(for kind: ContentKind) -> Color {
        Airy.dynamic(dark: AiryPalette.kindInk(kind, .dark), light: AiryPalette.kindInk(kind, .light))
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

    /// Color fijo de la señal de seguridad: fondos y rellenos grandes. Para texto, iconos, puntos
    /// y anillos en primer plano, `Theme.Airy.riskInk(_:)` (contraste AA también en modo claro).
    static func color(for risk: Risk) -> Color { Airy.riskFill(risk) }

    static func symbol(for risk: Risk) -> String {
        switch risk {
        case .safe: "checkmark.seal.fill"
        case .yourCall: "hand.raised.fill"
        case .doNotTouch: "lock.fill"
        }
    }

    // MARK: - Disco

    /// "Analizado" en el anillo de uso del disco.
    static let userFiles = Airy.logoGradient
    static let userFilesColor = Airy.accent
    /// "Sistema y otros".
    static let systemColor = Color(hex: AiryPalette.kind(.system))
    /// "Purgable": lo que macOS libera solo cuando hace falta.
    static let purgeableColor = Color(hex: 0x9fb3d9)
    /// Acento de marca: los botones principales y el progreso del análisis.
    static let brand = Airy.accentGradient

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

// MARK: - Theme.Airy

extension Theme {
    /// Paleta de marca. Los colores dinámicos siguen la apariencia efectiva (oscuro/claro) de la vista.
    enum Airy {
        private static func dynamic(_ pick: @escaping (AiryTokens) -> UInt32) -> Color {
            dynamic(dark: pick(AiryPalette.tokens(.dark)), light: pick(AiryPalette.tokens(.light)))
        }

        fileprivate static func dynamic(dark: UInt32, light: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(Color(hex: isDark ? dark : light))
            })
        }

        static let background = dynamic(\.background)
        static let backgroundRaised = dynamic(\.backgroundRaised)
        static let text = dynamic(\.text)
        static let textSecondary = dynamic(\.textSecondary)
        static let accent = dynamic(\.accent)
        static let sky = dynamic(\.sky)
        static let accentFill = dynamic(\.accentFill)
        static let onAccent = dynamic(\.onAccent)

        static let logoTop = Color(hex: AiryPalette.logoTop)
        static let logoBottom = Color(hex: AiryPalette.logoBottom)
        /// Noche fija: tinta sobre fondos de señal claros (ámbar, verde).
        static let night = Color(hex: 0x07112a)
        static let leafSky = Color(hex: AiryPalette.leafSky)
        static let destructiveTop = Color(hex: AiryPalette.destructiveTop)
        static let destructiveBottom = Color(hex: AiryPalette.destructiveBottom)

        static let accentGradient = LinearGradient(colors: [accentFill, logoBottom],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
        static let destructiveGradient = LinearGradient(colors: [destructiveTop, destructiveBottom],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing)
        static let logoGradient = LinearGradient(colors: [logoTop, logoBottom],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)

        /// Tinte del remolino de Rendimiento: azul de marca que se calienta con la temperatura.
        static func swirlTint(_ state: ProcessInfo.ThermalState) -> Color {
            Color(hex: AiryPalette.swirlTint(heat: WindMotion.heat(for: state)))
        }

        /// Señal de seguridad fija: solo fondos y rellenos grandes (y primer plano en oscuro).
        static func riskFill(_ risk: Risk) -> Color { Color(hex: AiryPalette.riskFill(risk)) }

        /// Tinta de riesgo para texto, iconos, puntos y anillos: AA sobre el fondo de cada modo.
        static func riskInk(_ risk: Risk) -> Color {
            dynamic(dark: AiryPalette.riskInk(risk, .dark), light: AiryPalette.riskInk(risk, .light))
        }
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
