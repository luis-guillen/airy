import SwiftUI
import DiskMapCore

/// Airy's visual system: palette per kind, springs and measurements shared by every view.
/// Every animation goes through here so motion is consistent across the app.
enum Theme {
    // MARK: - Motion

    /// Map zoom spring (and for any level or selection change).
    static let zoomSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// The same curve, computed by hand, for what the map interpolates in its `Canvas`.
    static let springCurve = SpringCurve(response: 0.45, dampingFraction: 0.82)
    /// Section change in the window: the same spring, a little livelier.
    static let sectionSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Counting numbers and growing rings.
    static let counterSpring = Animation.spring(response: 0.6, dampingFraction: 0.9)
    /// Tactile response of buttons and rows on press or hover.
    static let pressSpring = Animation.spring(response: 0.25, dampingFraction: 0.7)

    /// Delay between blocks of a staggered entrance.
    static let staggerStep: Double = 0.012
    /// The whole cascade has started by 0.6 s at the latest.
    static let staggerMaxDelay: Double = 0.6

    /// Staggered entrance: 12 ms per block, with the delay capped at 0.6 s.
    static func stagger(index: Int) -> Animation {
        zoomSpring.delay(min(Double(max(index, 0)) * staggerStep, staggerMaxDelay))
    }

    // MARK: - Palette per kind (same hue in dark and light)

    static func color(for kind: ContentKind) -> Color { Color(hex: AiryPalette.kind(kind)) }

    /// Subtle gradient (lighter at the top) for the kind's blocks and segments.
    static func gradient(for kind: ContentKind) -> LinearGradient {
        let base = color(for: kind)
        return LinearGradient(colors: [base.mix(with: .white, by: 0.18), base],
                              startPoint: .top, endPoint: .bottom)
    }

    /// The kind's AA ink for foreground text and icons (the pure color is only for fills).
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

    // MARK: - Risk

    /// Fixed color of the safety signal: backgrounds and large fills. For foreground text, icons, dots
    /// and rings, `Theme.Airy.riskInk(_:)` (AA contrast in light mode too).
    static func color(for risk: Risk) -> Color { Airy.riskFill(risk) }

    static func symbol(for risk: Risk) -> String {
        switch risk {
        case .safe: "checkmark.seal.fill"
        case .yourCall: "hand.raised.fill"
        case .doNotTouch: "lock.fill"
        }
    }

    // MARK: - Disk

    /// "Scanned" in the disk usage ring.
    static let userFiles = Airy.logoGradient
    static let userFilesColor = Airy.accent
    /// "System & other".
    static let systemColor = Color(hex: AiryPalette.kind(.system))
    /// "Purgeable": what macOS frees by itself only when needed.
    static let purgeableColor = Color(hex: 0x9fb3d9)
    /// Brand accent: the primary buttons and the scan progress.
    static let brand = Airy.accentGradient

    // MARK: - Measurements

    static let cardRadius: CGFloat = 18
    static let smallRadius: CGFloat = 10
    static let padding: CGFloat = 20
    static let contentPadding: CGFloat = 28
    static let spacing: CGFloat = 14

    /// Locale of the whole interface: the user's, so numbers and dates match the app's language.
    static let locale = Locale.current

    /// "just now" during the first minute (the relative formatter would say "in 0 seconds").
    static func relative(_ date: Date, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 60 ? String(localized: "just now") : Format.relativeDate(date)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }
}

// MARK: - Theme.Airy

extension Theme {
    /// Brand palette. Dynamic colors follow the view's effective appearance (dark/light).
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
        /// Fixed night: ink on light signal backgrounds (amber, green).
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

        /// Performance swirl tint: brand blue that warms up with the temperature.
        static func swirlTint(_ state: ProcessInfo.ThermalState) -> Color {
            Color(hex: AiryPalette.swirlTint(heat: WindMotion.heat(for: state)))
        }

        /// Fixed safety signal: only backgrounds and large fills (and foreground in dark mode).
        static func riskFill(_ risk: Risk) -> Color { Color(hex: AiryPalette.riskFill(risk)) }

        /// Risk ink for text, icons, dots and rings: AA on each mode's background.
        static func riskInk(_ risk: Risk) -> Color {
            dynamic(dark: AiryPalette.riskInk(risk, .dark), light: AiryPalette.riskInk(risk, .light))
        }
    }
}

extension Color {
    /// sRGB color from an integer `0xRRGGBB`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
