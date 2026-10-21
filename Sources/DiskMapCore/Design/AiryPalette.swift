import Foundation

// Airy's palette. The values come from spec §2.1; the derived ones (light mode,
// risk inks, button) were chosen to pass `AiryPaletteTests`.
// Whoever changes a color runs the tests.

public enum AiryAppearance: Sendable, CaseIterable { case dark, light }

public struct AiryTokens: Sendable, Equatable {
    public let background, backgroundRaised, text, textSecondary: UInt32
    public let accent, sky, accentFill, onAccent: UInt32
    public let safeInk, yourCallInk, doNotTouchInk: UInt32
}

public struct ContrastCheck: Sendable {
    public let name: String
    public let foreground: UInt32
    public let background: UInt32
    public let minimum: Double
}

public enum AiryPalette {
    public static let logoTop: UInt32 = 0x2fd0ff
    public static let logoBottom: UInt32 = 0x2a3bd9
    public static let leafSky: UInt32 = 0xbfe9ff
    public static let heat: UInt32 = 0xff8a3d
    public static let destructiveTop: UInt32 = 0xd12a40
    public static let destructiveBottom: UInt32 = 0xb81f33
    public static let safe: UInt32 = 0x1fdc7a
    public static let yourCall: UInt32 = 0xffb020
    public static let doNotTouch: UInt32 = 0xff4d5e
    public static let others: UInt32 = 0x5a6380

    /// Opacity used to tint a risk badge's background.
    public static let badgeTintOpacity = 0.14

    public static func tokens(_ appearance: AiryAppearance) -> AiryTokens {
        switch appearance {
        case .dark:
            AiryTokens(background: 0x07112a, backgroundRaised: 0x0d2350, text: 0xf2f7ff,
                       textSecondary: 0xb9cdf0, accent: 0x2f8bff, sky: 0x5ab8ff,
                       accentFill: 0x1d5fd6, onAccent: 0xffffff,
                       safeInk: 0x1fdc7a, yourCallInk: 0xffb020, doNotTouchInk: 0xff8590)
        case .light:
            AiryTokens(background: 0xf3f7ff, backgroundRaised: 0xffffff, text: 0x07112a,
                       textSecondary: 0x34486e, accent: 0x1a63d6, sky: 0x0a6fb0,
                       accentFill: 0x1d5fd6, onAccent: 0xffffff,
                       safeInk: 0x0a7a3f, yourCallInk: 0x8a5300, doNotTouchInk: 0xc0182f)
        }
    }

    /// Fixed color of the safety signal: only for backgrounds and large fills.
    public static func riskFill(_ risk: Risk) -> UInt32 {
        switch risk {
        case .safe: safe
        case .yourCall: yourCall
        case .doNotTouch: doNotTouch
        }
    }

    /// Risk text/icon ink with AA contrast on the mode's background.
    public static func riskInk(_ risk: Risk, _ appearance: AiryAppearance) -> UInt32 {
        let t = tokens(appearance)
        switch risk {
        case .safe: return t.safeInk
        case .yourCall: return t.yourCallInk
        case .doNotTouch: return t.doNotTouchInk
        }
    }

    public static func kind(_ kind: ContentKind) -> UInt32 {
        switch kind {
        case .video: 0xa77bff
        case .images: 0xe58cf5
        case .apps: 0x4b4ee8
        case .code: 0x2f8bff
        case .caches: 0x18c7a6
        case .aiModels: 0x5fe0ff
        case .containers: 0x0f6a8c
        case .documents: 0xc2d3ff
        case .system: 0x605a80
        case .other: 0x8d96a6
        }
    }

    /// Text/icon ink of a kind: the kind's color, lightened (dark) or darkened (light)
    /// just enough to reach AA on the mode's background and raised background.
    public static func kindInk(_ kind: ContentKind, _ appearance: AiryAppearance) -> UInt32 {
        let t = tokens(appearance)
        let base = Self.kind(kind)
        let target: UInt32 = appearance == .dark ? 0xffffff : 0x000000
        func passes(_ c: UInt32) -> Bool {
            ColorMath.contrastRatio(c, t.background) >= 4.5 && ColorMath.contrastRatio(c, t.backgroundRaised) >= 4.5
        }
        for step in 0...20 {
            let candidate = ColorMath.mix(base, target, Double(step) / 20)
            if passes(candidate) { return candidate }
        }
        return target
    }

    /// A tile's gradient: lighter at the top, darker at the bottom.
    public static func tileStops(_ base: UInt32) -> [UInt32] {
        [ColorMath.mix(base, 0xffffff, 0.10), base, ColorMath.mix(base, 0x000000, 0.10)]
    }

    /// Ink of a tile's label: white or night, whichever has more contrast.
    public static func tileInk(_ base: UInt32) -> UInt32 {
        let night: UInt32 = 0x07112a
        return ColorMath.contrastRatio(0xffffff, base) >= ColorMath.contrastRatio(night, base) ? 0xffffff : night
    }

    /// Ink (white or night) with the best minimum contrast over all the colors of a fill.
    public static func inkForFill(_ colors: [UInt32]) -> UInt32 {
        let night: UInt32 = 0x07112a
        func worst(_ ink: UInt32) -> Double { colors.map { ColorMath.contrastRatio(ink, $0) }.min() ?? 0 }
        return worst(0xffffff) >= worst(night) ? 0xffffff : night
    }

    /// Blue that warms towards `heat` with the intensity (clamped to 0…1; NaN ⇒ 0).
    public static func swirlTint(heat h: Double) -> UInt32 {
        ColorMath.mix(0x2f8bff, heat, h.isNaN ? 0 : min(max(h, 0), 1))
    }

    public static func contrastChecks(_ appearance: AiryAppearance) -> [ContrastCheck] {
        let t = tokens(appearance)
        var checks: [ContrastCheck] = []
        func add(_ name: String, _ fg: UInt32, _ bg: UInt32) {
            checks.append(ContrastCheck(name: name, foreground: fg, background: bg, minimum: 4.5))
        }
        let surfaces: [(String, UInt32)] = [("background", t.background), ("raised", t.backgroundRaised)]
        for (surfaceName, surface) in surfaces {
            add("text/\(surfaceName)", t.text, surface)
            add("secondary text/\(surfaceName)", t.textSecondary, surface)
            add("accent/\(surfaceName)", t.accent, surface)
            add("sky/\(surfaceName)", t.sky, surface)
        }
        add("on accent/button", t.onAccent, t.accentFill)
        add("on accent/logo", t.onAccent, logoBottom)
        add("on accent/destructive light", t.onAccent, destructiveTop)
        add("on accent/destructive dark", t.onAccent, destructiveBottom)
        let risks: [(String, Risk)] = [("Safe to remove", .safe), ("Your call", .yourCall), ("Don't delete", .doNotTouch)]
        for (riskName, risk) in risks {
            for (surfaceName, surface) in surfaces {
                let tinted = ColorMath.mix(surface, riskFill(risk), badgeTintOpacity)
                add("\(riskName)/\(surfaceName)", riskInk(risk, appearance), tinted)
            }
        }
        return checks
    }
}
