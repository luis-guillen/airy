import Foundation

/// Matemática de color sobre enteros `0xRRGGBB` en sRGB: contraste WCAG 2.x,
/// mezcla, distancia perceptual y tono. Sin dependencias de UI.
public enum ColorMath {
    private static func channels(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    private static func linear(_ channel: Double) -> Double {
        let c = channel / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Luminancia relativa WCAG 2.x (0 = negro, 1 = blanco).
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Razón de contraste WCAG `(L1 + 0,05) / (L2 + 0,05)` con la luminancia mayor arriba.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Interpola cada canal sRGB (0–255) de `a` a `b` con `t` (acotado a 0…1) y redondea.
    public static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let t = t.isNaN ? 0 : min(max(t, 0), 1)
        let ca = channels(a), cb = channels(b)
        func lerp(_ x: Double, _ y: Double) -> UInt32 { UInt32((x + (y - x) * t).rounded()) }
        return lerp(ca.r, cb.r) << 16 | lerp(ca.g, cb.g) << 8 | lerp(ca.b, cb.b)
    }

    private static func lab(_ hex: UInt32) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = channels(hex)
        let lr = linear(r), lg = linear(g), lb = linear(b)
        // sRGB lineal → XYZ (D65), normalizado al blanco de referencia.
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Distancia euclídea en CIELAB (D65), ΔE 1976.
    public static func deltaE76(_ a: UInt32, _ b: UInt32) -> Double {
        let la = lab(a), lb = lab(b)
        let dl = la.l - lb.l, da = la.a - lb.a, db = la.b - lb.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Tono HSV en grados, 0…360 (0 para grises).
    public static func hueDegrees(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return 0 }
        let h: Double
        if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        let deg = h * 60
        return deg < 0 ? deg + 360 : deg
    }
}
