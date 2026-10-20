import Testing
@testable import DiskMapCore

struct AiryPaletteTests {
    @Test func contrastRatioMatchesWCAGReferences() {
        #expect(abs(ColorMath.contrastRatio(0xFFFFFF, 0x000000) - 21) < 1e-9)
        #expect(abs(ColorMath.contrastRatio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(ColorMath.contrastRatio(0x2f8bff, 0x07112a) == ColorMath.contrastRatio(0x07112a, 0x2f8bff))
    }

    @Test func darkTokensAreTheSpecValues() {
        let t = AiryPalette.tokens(.dark)
        #expect(t.background == 0x07112a && t.backgroundRaised == 0x0d2350)
        #expect(t.accent == 0x2f8bff && t.sky == 0x5ab8ff)
        #expect(t.text == 0xf2f7ff && t.textSecondary == 0xb9cdf0)
        #expect(AiryPalette.logoTop == 0x2fd0ff && AiryPalette.logoBottom == 0x2a3bd9)
    }

    @Test func safetyColoursAreFixed() {
        #expect(AiryPalette.riskFill(.safe) == 0x1fdc7a)
        #expect(AiryPalette.riskFill(.yourCall) == 0xffb020)
        #expect(AiryPalette.riskFill(.doNotTouch) == 0xff4d5e)
    }

    @Test(arguments: AiryAppearance.allCases)
    func everyTextPairMeetsAA(_ appearance: AiryAppearance) {
        let checks = AiryPalette.contrastChecks(appearance)
        #expect(checks.count == 18)
        for check in checks {
            #expect(check.minimum >= 4.5)
            #expect(ColorMath.contrastRatio(check.foreground, check.background) >= check.minimum,
                    "\(appearance) \(check.name)")
        }
    }

    @Test(arguments: AiryAppearance.allCases)
    func kindInkMeetsAAOnBothSurfaces(_ appearance: AiryAppearance) {
        let t = AiryPalette.tokens(appearance)
        for kind in ContentKind.allCases {
            let ink = AiryPalette.kindInk(kind, appearance)
            #expect(ColorMath.contrastRatio(ink, t.background) >= 4.5, "\(appearance) \(kind) fondo")
            #expect(ColorMath.contrastRatio(ink, t.backgroundRaised) >= 4.5, "\(appearance) \(kind) elevado")
        }
    }

    @Test func tileLabelsMeetAAOnEveryGradientStop() {
        for base in ContentKind.allCases.map(AiryPalette.kind) + [AiryPalette.others] {
            let ink = AiryPalette.tileInk(base)
            #expect(ink == 0xffffff || ink == 0x07112a)
            for stop in AiryPalette.tileStops(base) {
                #expect(ColorMath.contrastRatio(ink, stop) >= 4.5, "tesela \(String(base, radix: 16))")
            }
        }
    }

    @Test func treemapKindsAreDistinguishable() {
        let colours = ContentKind.allCases.map(AiryPalette.kind)
        for i in colours.indices { for j in colours.indices where j > i {
            #expect(ColorMath.deltaE76(colours[i], colours[j]) >= 20,
                    "\(ContentKind.allCases[i]) vs \(ContentKind.allCases[j])")
        } }
    }

    @Test func treemapKindsStayInTheColdRange() {
        for kind in ContentKind.allCases where kind != .system && kind != .other {
            let hue = ColorMath.hueDegrees(AiryPalette.kind(kind))
            #expect((160...300).contains(hue), "\(kind) \(hue)")
        }
    }

    @Test func swirlTintWarmsWithHeat() {
        #expect(AiryPalette.swirlTint(heat: 0) == 0x2f8bff)
        #expect(AiryPalette.swirlTint(heat: 1) == 0xff8a3d)
        #expect(AiryPalette.swirlTint(heat: 7) == 0xff8a3d)
        #expect(AiryPalette.swirlTint(heat: .nan) == 0x2f8bff)
        let reds = [0, 0.35, 0.7, 1].map { (AiryPalette.swirlTint(heat: $0) >> 16) & 0xFF }
        #expect(zip(reds, reds.dropFirst()).allSatisfy { $0 < $1 })
    }
}
