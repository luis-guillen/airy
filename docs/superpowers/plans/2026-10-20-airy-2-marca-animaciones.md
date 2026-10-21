# Airy 2 of 5 — Brand and animations · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Airy debuts its wind brand: the «remolino con hojas» (wind swirl with leaves) icon (with a small variant), a blue palette with cool accents and AA contrast verified by tests, fixed safety colors with a three-text `RiskBadge`, and all the animations of §2.2 (launch, analysis, delete, «Borrar todo» (Delete all), background breeze, swaying buttons and the Performance pieces) without spending CPU at rest.

**Architecture:** Everything that can be computed without SwiftUI lives in `DiskMapCore/Design/` and is tested with Swift Testing: color math and WCAG contrast, the palette tokens, the logo geometry and the deterministic poses of each animation (pure functions of time or progress, with no random state). The app (`Sources/Airy/Design/`) only translates those numbers into `Color`, `Canvas` and transitions, and a single «motion gatekeeper» (portero de movimiento) in `RootView` decides through the environment whether each animation runs, pauses (hidden window or inactive app ⇒ no live clock) or is reduced to fades («Reducir movimiento» (Reduce Motion)). The `.icns` icon comes from the same CoreGraphics script as always, with the geometry copied from the library and a fingerprint that a test compares.

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, SwiftUI + AppKit (`Canvas`, `TimelineView`, `keyframeAnimator`, `AnyTransition.modifier`), CoreGraphics/ImageIO (`scripts/make-icon.swift`), `sips`/`iconutil`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.1 (logo, palette, contrast, safety colors), §2.2 (animations and their limits), §4 («que las animaciones hagan la app pesada» (animations making the app heavy), «verse azul plano y aburrido o con poco contraste» (looking flat, boring blue or with low contrast)), §7 («paleta clara derivada y valores exactos de contraste» (derived light palette and exact contrast values), «implementación de las animaciones» (implementation of the animations)). Plan 1 interfaces consumed: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` (`Risk.label`, `Airy` identity, `Resources/Airy.icns`).

**Out of this plan:** grouping Cleanup by the three labels, «why» texts and the «Borrar todo» button (plan 3: consumes `RiskBadge`, `.leafAway`, `CleanupFlow.gust`); Performance section (plan 4: consumes `WindSwirl`, `.leafAway`, `Theme.Airy.swirlTint`); Uninstaller, Large & old, Duplicates, File types (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only (no Xcode); `swift build` / `swift test`; platform `.macOS(.v15)`; the test target keeps the `unsafeFlags` of the Swift Testing plugin from Package.swift. The test target only depends on `DiskMapCore`: everything that is tested lives there.
- SwiftUI views with the `@ViewState` alias (not `@State`), never `.fixedSize(horizontal:false,vertical:true)` on multiline `Text`. **No SwiftUI macros** (`@State`, `@Entry`, `#Preview`): they do not compile with Command Line Tools; environment keys are written by hand with `EnvironmentKey`. Follow the existing patterns (`Theme`, `PrimaryButton`, `SectionHeader`, `GlassCard`).
- Interface in **Spanish (Spain)**.
- Dark palette (spec, literal): night `#07112a`/`#0d2350`, blue `#2f8bff`, sky `#5ab8ff`, text `#f2f7ff`/secondary `#b9cdf0`. Logo: gradient `#2fd0ff` → `#2a3bd9`, three concentric wind arcs in translucent white, white/light-blue leaves. Variant ≤ 64 px: a single thick arc and one leaf.
- **Fixed safety colors** (spec, literal): green `#1fdc7a` (no problem), amber `#ffb020` (you decide), red `#ff4d5e` (do not delete). They are signals, not decoration: they are not used to adorn.
- **Strong contrast:** all text and indicators with WCAG AA contrast ≥ 4.5:1 in dark and in light (verified by `AiryPaletteTests`).
- The block map uses the **cool range** (blues, turquoises, violets, indigo), with each type distinguishable (ΔE76 ≥ 20 between any pair).
- Animations: «Reducir movimiento» ⇒ fades only; 60–120 fps; **zero CPU at rest**: no unpaused `TimelineView` nor live `repeatForever` animation with the window hidden, minimized, covered or the app inactive (the map's pattern: `TimelineView(.animation(minimumInterval: nil, paused: …))` and clocks that only exist while the effect lasts).
- Every destructive action still goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor`; the animations only **react** to results, they never trigger deletions. No DEBUG shortcuts that act without confirmation (the new `AIRY_*` debug variables only hide the window, skip the launch or show a gallery).
- DEBUG screenshots only of the app's own windows; to stop the app, kill **only its own PID** (never `pkill -x`); each manual verification uses its own temporary `AIRY_SUPPORT_DIR`. Never `scripts/build-app.sh --install`, never write to `/Applications`, never touch the Keychain.
- In tests and verification, real cleanups are never run and the real Trash is never emptied.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Window minimized, covered, on another Desktop or app in the background mid-animation** → all ambient clocks stop (0 % CPU) and on return continue without a jump. Test in Task 4 (`ambientPausesWhenHiddenOrInactive`, `swirlPhaseDoesNotJumpAfterPause`) and CPU verification in Task 5.
2. **«Reducir movimiento» enabled (before or during)** → nothing moves or spins; the launch is a short fade that does not cover the app for more than 0.7 s. Test in Task 4 (`reduceMotionWinsOverRunning`, `launchTimelineIsShortWithReduceMotion`) and screenshot with `AIRY_REDUCE_MOTION=1` in Task 6.
3. **Light mode** (the derived palette that is not in the spec) → every text pair meets AA just as in dark, including the risk labels. Test in Task 1 (`everyTextPairMeetsAA` with `.light`).
4. **«Borrar todo» with hundreds of rows or tiny blocks** → the gust lasts at most 1.2 s and the per-row leaves do not fire; a 0×0 rectangle does not produce `NaN`. Test in Task 4 (`gustDurationIsCappedForHugeLists`, `leafCountIsClamped`, `dissolveHandlesDegenerateRect`).
5. **CPU load or thermal state out of range** (what plan 4 will pass: `NaN`, negative, > 1) → the swirl's speed and tint are clamped, it never freezes nor spins wildly. Test in Task 4 (`swirlSpeedClampsGarbage`) and Task 1 (`swirlTintWarmsWithHeat`).

---

## Public interfaces consumed by plans 3–5

Fixed names (defined here; plans 3–5 use them as they are):

| Name | Where | What it is |
|---|---|---|
| `Theme.Airy` | `Sources/Airy/Design/Theme.swift` | Palette: `background`, `backgroundRaised`, `text`, `textSecondary`, `accent`, `sky`, `onAccent`, `leafSky` (`Color`, dynamic light/dark), `accentGradient`, `destructiveGradient`, `logoGradient` (`LinearGradient`), `riskFill(_ risk: Risk) -> Color`, `riskInk(_ risk: Risk) -> Color`, `swirlTint(_ thermal: ProcessInfo.ThermalState) -> Color` |
| `RiskBadge(risk:compact:reason:)` | `Sources/Airy/Design/Components.swift` | Label «Sin problema» / «Tú decides» / «No borrar» (No problem / You decide / Do not delete) (`Risk.label`) with symbol, AA ink and optional `reason` in the help text and in VoiceOver |
| `AiryLogo(size:animated:)` | `Sources/Airy/Design/AiryLogo.swift` | Vector logo; automatic small variant ≤ 64 px |
| `BreezeBackground(intensity:)` | `Sources/Airy/Design/BreezeBackground.swift` | Breeze background; `BreezeIntensity.ambient` / `.scan` |
| `WindLeaves(mode:count:)` | `Sources/Airy/Design/WindLeaves.swift` | Leaves: `.orbit(radius:)`, `.launch(start:)`, `.burst(start:rect:)` |
| `AnyTransition.leafAway` | `Sources/Airy/Design/WindLeaves.swift` | A row that flies off like a leaf and breaks apart into leaves (delete in Cleanup; quit app in Performance) |
| `WindSwirl(speed:tint:)` | `Sources/Airy/Design/WindSwirl.swift` | Swirl; `speed` in revolutions/s (use `WindMotion.swirlRevolutionsPerSecond(cpuLoad:)`), `tint` (use `Theme.Airy.swirlTint(_:)`) |
| `GustSweep(start:)`, `.gustSway(index:start:)` | `Sources/Airy/Design/GustSweep.swift` | A gust that sweeps a list from left to right |
| `.hoverSway(_ hovering: Bool)` | `Sources/Airy/Design/Motion.swift` | Brief sway on hover |
| `EnvironmentValues.airyAmbientMotion` / `.airyTransientMotion` (`MotionMode`) | `Sources/Airy/Design/Motion.swift` | Motion gatekeeper; every new animated view reads it |
| `CleanupFlow.gust: CleanupFlow.Gust?`, `CleanupFlow.batchFreed: Int64` | `Sources/Airy/Cleanup/CleanupFlow.swift` | The gust fires by itself on every confirmed batch of ≥ 2 items; `batchFreed` goes up with each row |
| `AiryPalette`, `ColorMath`, `AiryLogoGeometry`, `WindMotion`, `AnimationGate`, `MotionMode`, `BreezeIntensity` | `Sources/DiskMapCore/Design/` | Pure, tested core |

---

## File structure

```
Sources/DiskMapCore/Design/                                   (new)
  ColorMath.swift          WCAG luminance, contrast, sRGB mixing, ΔE76, hue
  AiryPalette.swift        dark/light tokens, safety, map types, contrast checks
  AiryLogoGeometry.swift   logo arcs and leaves (1024 grid), variant, launch targets, fingerprint
  WindMotion.swift         deterministic poses: launch, orbit, break apart, fly off, gust,
                           breeze, swirl, sway; MotionMode/AnimationGate; BreezeIntensity
Tests/DiskMapCoreTests/
  AiryPaletteTests.swift, AiryLogoGeometryTests.swift, WindMotionTests.swift   (new)
scripts/make-icon.swift    swirl with leaves; small variant for ≤ 64 px
Resources/Airy.icns, Resources/Airy-1024.png                  (regenerated)
Sources/Airy/Design/
  Theme.swift              + Theme.Airy; types, risk and brand move to the new palette
  Components.swift         new RiskBadge, PrimaryButton with AA ink and sway
  AiryLogo.swift           vector logo (replaces AppGlyph)                          (new)
  Motion.swift             environment keys, window activity reader, hoverSway (new)
  BreezeBackground.swift   background breeze                                         (new)
  WindLeaves.swift         leaves in Canvas + AnyTransition.leafAway                 (new)
  WindSwirl.swift          Performance swirl                                         (new)
  GustSweep.swift          «Borrar todo» gust                                       (new)
  MotionGallery.swift      DEBUG-only gallery (AIRY_MOTION_GALLERY=1)                (new)
Sources/Airy/Shell/
  LaunchSwirl.swift        launch: the leaves form the logo                          (new)
  RootView.swift           motion gatekeeper, background, tint, text hierarchy, launch
  Sidebar.swift            AiryLogo, raised background
  ScanProgressView.swift   analysis breeze + orbiting leaves
  DebugSnapshot.swift      AIRY_HIDE_AT, AIRY_UNHIDE_AT, AIRY_REDUCE_MOTION, AIRY_SKIP_LAUNCH
Sources/Airy/Map/          TreemapCanvas.swift (tile palette), MapScene.swift + MapView.swift (block into leaves)
Sources/Airy/Cleanup/      CleanupFlow.swift (gust, batchFreed), CleanupView.swift (leafAway, gust, counter),
                           FreedCelebration.swift, ConfirmSheet.swift (colors)
Sources/Airy/Shell/FullDiskAccessBanner.swift (colors)
```

---

### Task 1: Palette and contrast in the core

**Files:**
- Create: `Sources/DiskMapCore/Design/ColorMath.swift`, `Sources/DiskMapCore/Design/AiryPalette.swift`
- Test: `Tests/DiskMapCoreTests/AiryPaletteTests.swift`

**Interfaces:**
- Consumes: `ContentKind` (CaseIterable), `Risk` (`Sources/DiskMapCore/Model/FileNode.swift`).
- Produces:
  - `public enum ColorMath { static func relativeLuminance(_ hex: UInt32) -> Double; static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double; static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32; static func deltaE76(_ a: UInt32, _ b: UInt32) -> Double; static func hueDegrees(_ hex: UInt32) -> Double }`
  - `public enum AiryAppearance: Sendable, CaseIterable { case dark, light }`
  - `public struct AiryTokens: Sendable, Equatable { background, backgroundRaised, text, textSecondary, accent, sky, accentFill, onAccent, safeInk, yourCallInk, doNotTouchInk: UInt32 }`
  - `public struct ContrastCheck: Sendable { name: String; foreground: UInt32; background: UInt32; minimum: Double }`
  - `public enum AiryPalette` with: `logoTop`, `logoBottom`, `leafSky`, `heat`, `destructiveTop`, `destructiveBottom`, `safe`, `yourCall`, `doNotTouch`, `others` (`UInt32`); `tokens(_:) -> AiryTokens`; `riskFill(_: Risk) -> UInt32`; `riskInk(_: Risk, _: AiryAppearance) -> UInt32`; `kind(_: ContentKind) -> UInt32`; `tileStops(_ base: UInt32) -> [UInt32]`; `tileInk(_ base: UInt32) -> UInt32`; `swirlTint(heat: Double) -> UInt32`; `contrastChecks(_: AiryAppearance) -> [ContrastCheck]`; `static let badgeTintOpacity = 0.14`.

Values (those from the spec, literal; the rest, derived and verified by the tests below):

| Token | Dark | Light |
|---|---|---|
| background | `0x07112a` | `0xf3f7ff` |
| backgroundRaised | `0x0d2350` | `0xffffff` |
| text | `0xf2f7ff` | `0x07112a` |
| textSecondary | `0xb9cdf0` | `0x34486e` |
| accent | `0x2f8bff` | `0x1a63d6` |
| sky | `0x5ab8ff` | `0x0a6fb0` |
| accentFill (button background) | `0x1d5fd6` | `0x1d5fd6` |
| onAccent | `0xffffff` | `0xffffff` |
| safeInk / yourCallInk / doNotTouchInk | `0x1fdc7a` / `0xffb020` / `0xff8590` | `0x0a7a3f` / `0x8a5300` / `0xc0182f` |

Constants: `logoTop 0x2fd0ff`, `logoBottom 0x2a3bd9`, `leafSky 0xbfe9ff`, `heat 0xff8a3d`, `destructiveTop 0xd12a40`, `destructiveBottom 0xb81f33`, `safe 0x1fdc7a`, `yourCall 0xffb020`, `doNotTouch 0xff4d5e`, `others 0x5a6380`.

Map types (`kind(_:)`): video `0xa77bff`, images `0xe58cf5`, apps `0x4b4ee8`, code `0x2f8bff`, caches `0x18c7a6`, aiModels `0x5fe0ff`, containers `0x0f6a8c`, documents `0xc2d3ff`, system `0x605a80`, other `0x8d96a6`.

Rules: `mix` interpolates each sRGB channel (0–255) and rounds; `tileStops(b) = [mix(b, 0xffffff, 0.10), b, mix(b, 0x000000, 0.10)]`; `tileInk(b)` = `0xffffff` or `0x07112a`, whichever has the higher contrast with `b`; `swirlTint(heat:)` = `mix(0x2f8bff, heat, h)` with `h` clamped to 0…1 and `NaN` ⇒ 0; `contrastChecks(a)` returns exactly 18 pairs, all with `minimum = 4.5`: text, textSecondary, accent and sky over background and over backgroundRaised (8); onAccent over accentFill and over `logoBottom` (2); onAccent over `destructiveTop` and `destructiveBottom` (2); each `riskInk` over `mix(background, riskFill, 0.14)` and over `mix(backgroundRaised, riskFill, 0.14)` (6). The names are readable in Spanish («texto/fondo» (text/background), «No borrar/elevado» (Do not delete/raised)…) so that the test message says which pair fails.

- [ ] **Step 1: Write the failing tests**

```swift
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

    @Test func tileLabelsMeetAAOnEveryGradientStop() {
        for base in ContentKind.allCases.map(AiryPalette.kind) + [AiryPalette.others] {
            let ink = AiryPalette.tileInk(base)
            #expect(ink == 0xffffff || ink == 0x07112a)
            for stop in AiryPalette.tileStops(base) {
                #expect(ColorMath.contrastRatio(ink, stop) >= 4.5, "tile \(String(base, radix: 16))")
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AiryPaletteTests`
Expected: FAIL to compile («cannot find 'ColorMath' in scope»).

- [ ] **Step 3: Implement `ColorMath` and `AiryPalette`**

WCAG 2.x luminance (channel/255, `≤ 0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4`, weights 0.2126/0.7152/0.0722); contrast `(L1+0.05)/(L2+0.05)` with the larger on top; ΔE76 = Euclidean distance in CIELAB D65; HSV hue in degrees 0…360. Header comment: the values come from spec §2.1 and the derived ones (light mode, risk inks, button) were chosen to pass `AiryPaletteTests`; whoever changes a color runs the tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AiryPaletteTests`
Expected: PASS (the 8 tests; `everyTextPairMeetsAA` in both of its arguments).

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskMapCore/Design/ColorMath.swift Sources/DiskMapCore/Design/AiryPalette.swift Tests/DiskMapCoreTests/AiryPaletteTests.swift
git commit -m "feat: Airy palette with verified AA contrast

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Logo geometry and «remolino con hojas» icon

**Files:**
- Create: `Sources/DiskMapCore/Design/AiryLogoGeometry.swift`
- Modify: `scripts/make-icon.swift` (complete drawing, size table), `Resources/Airy.icns`, `Resources/Airy-1024.png` (regenerated)
- Test: `Tests/DiskMapCoreTests/AiryLogoGeometryTests.swift`

**Interfaces:**
- Consumes: `AiryPalette.logoTop/logoBottom/leafSky` (Task 1).
- Produces:
  - `public enum AiryLogoGeometry` with `enum Variant { case full, small }`, `struct Arc: Sendable, Equatable { radius, lineWidth, startDegrees, sweepDegrees, opacity: Double }`, `struct Leaf: Sendable, Equatable { radius, angleDegrees, length, width: Double; tint: UInt32 }`.
  - `static let grid = 1024.0`, `static let squircleInset = 100.0`, `static let squircleRadius = 185.0`, `static let center = 512.0`, `static let unit = 412.0` (half the squircle: 1 normalized unit).
  - `static func arcs(_: Variant) -> [Arc]`, `static func leaves(_: Variant) -> [Leaf]`, `static func variant(forPixelSize: Double) -> Variant` (≤ 64 ⇒ `.small`).
  - `static func leafPath(length: Double, width: Double) -> CGPath` — centered at the origin along +x: `move(-L/2, 0)`, quadratic curve to `(L/2, 0)` with control `(0, -W)`, return to `(-L/2, 0)` with control `(0, 0.6·W)`.
  - `static func leafCenter(_: Leaf) -> CGPoint` and `leafRotationDegrees(_: Leaf) = angle + 90` (tangent, clockwise with y pointing down); in grid coordinates.
  - `static func launchTargets(count: Int) -> [CGPoint]` — in normalized units (center 0, `(grid − 512)/412`, y pointing down): first the centers of `leaves(.full)`, then points distributed equally along `arcs(.full)`.
  - `static var fingerprint: String` — `"airy-logo-v1|"` + each arc and leaf with its numbers (free but stable format).

Geometry (1024 grid, angles in degrees, 0 = +x, y pointing down):

| Variant | Arcs (radius, thickness, start, sweep, opacity) | Leaves (radius, angle, length, width, tint) |
|---|---|---|
| `.full` | (300, 34, −20, 250, 0.90) · (220, 30, 70, 250, 0.70) · (140, 26, 160, 250, 0.50) | (300, 230, 132, 62, `0xFFFFFF`) · (220, 320, 112, 52, `0xBFE9FF`) · (140, 50, 92, 44, `0xFFFFFF`) |
| `.small` | (230, 86, −30, 270, 0.95) | (230, 240, 230, 110, `0xFFFFFF`) |

Each leaf is at the end of its arc (start + sweep), as if the wind had released it.

Icon (`scripts/make-icon.swift`): the continuous squircle, the shadow, the specular highlight and the light edge of the current script are kept; the background becomes a linear gradient `0x2fd0ff` (top-left) → `0x2a3bd9` (bottom-right) and the treemap is replaced by the arcs (white stroke with the opacity from the table, rounded ends) and the leaves (filled with their tint, soft shadow `alpha 0.25`). The geometry is copied from the table above with a comment `// logo-geometry: <AiryLogoGeometry.fingerprint>` (the exact fingerprint text). Sizes: `px ≤ 64` (16, 16@2x, 32, 32@2x) are drawn at their size with `.small` and pixel-aligned; 128…512 with `sips` from the master; 1024 = master. `AIRY_ICON_PREVIEW` keeps writing `preview-16/32/64.png`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import DiskMapCore

struct AiryLogoGeometryTests {
    @Test func fullHasThreeConcentricArcsAndLeaves() {
        let arcs = AiryLogoGeometry.arcs(.full)
        #expect(arcs.count == 3)
        #expect(zip(arcs, arcs.dropFirst()).allSatisfy { $0.radius > $1.radius })
        #expect(arcs.allSatisfy { $0.opacity > 0 && $0.opacity < 1 })
        let leaves = AiryLogoGeometry.leaves(.full)
        #expect(leaves.count == 3)
        #expect(leaves.allSatisfy { [0xFFFFFF, 0xBFE9FF].contains($0.tint) })
    }

    @Test func smallHasOneThickArcAndOneLeaf() {
        let thickest = AiryLogoGeometry.arcs(.full).map(\.lineWidth).max()!
        #expect(AiryLogoGeometry.arcs(.small).count == 1)
        #expect(AiryLogoGeometry.arcs(.small)[0].lineWidth >= 2 * thickest)
        #expect(AiryLogoGeometry.leaves(.small).count == 1)
    }

    @Test func variantSwitchesAt64Pixels() {
        for px in [16.0, 32, 64] { #expect(AiryLogoGeometry.variant(forPixelSize: px) == .small) }
        for px in [65.0, 128, 1024] { #expect(AiryLogoGeometry.variant(forPixelSize: px) == .full) }
    }

    @Test(arguments: [AiryLogoGeometry.Variant.full, .small])
    func leavesSitAtArcEnds(_ variant: AiryLogoGeometry.Variant) {
        for (arc, leaf) in zip(AiryLogoGeometry.arcs(variant), AiryLogoGeometry.leaves(variant)) {
            let end = (arc.startDegrees + arc.sweepDegrees).truncatingRemainder(dividingBy: 360)
            #expect(abs(((end + 360).truncatingRemainder(dividingBy: 360)) - leaf.angleDegrees) < 1e-9)
            #expect(arc.radius == leaf.radius)
        }
    }

    @Test(arguments: [AiryLogoGeometry.Variant.full, .small])
    func everythingFitsInsideTheSquircle(_ variant: AiryLogoGeometry.Variant) {
        let limit = AiryLogoGeometry.unit - 40
        for arc in AiryLogoGeometry.arcs(variant) { #expect(arc.radius + arc.lineWidth / 2 <= limit) }
        for leaf in AiryLogoGeometry.leaves(variant) { #expect(leaf.radius + leaf.length / 2 <= limit) }
    }

    @Test func leafPathSpansItsLength() {
        let box = AiryLogoGeometry.leafPath(length: 100, width: 40).boundingBoxOfPath
        #expect(abs(box.width - 100) < 0.5)
        #expect(box.height > 20 && box.height < 40)
    }

    @Test func launchTargetsStartWithTheLeavesAndStayInside() {
        let targets = AiryLogoGeometry.launchTargets(count: 18)
        #expect(targets.count == 18)
        for (target, leaf) in zip(targets, AiryLogoGeometry.leaves(.full)) {
            let c = AiryLogoGeometry.leafCenter(leaf)
            #expect(abs(target.x - (c.x - 512) / 412) < 1e-9 && abs(target.y - (c.y - 512) / 412) < 1e-9)
        }
        #expect(targets.allSatisfy { hypot($0.x, $0.y) <= 1 })
    }

    @Test func iconScriptCarriesTheGeometryFingerprint() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-icon.swift")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("// logo-geometry: \(AiryLogoGeometry.fingerprint)"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AiryLogoGeometryTests`
Expected: FAIL to compile («cannot find 'AiryLogoGeometry' in scope»).

- [ ] **Step 3: Implement `AiryLogoGeometry` with the table above**

- [ ] **Step 4: Run tests — all pass except the fingerprint one**

Run: `swift test --filter AiryLogoGeometryTests`
Expected: 7 PASS, `iconScriptCarriesTheGeometryFingerprint` FAIL.

- [ ] **Step 5: Rewrite the drawing in `scripts/make-icon.swift` and add the fingerprint comment**

Copy the exact text of `AiryLogoGeometry.fingerprint` (e.g. with a temporary `print` in a test, which is then removed). Change the script header (there is no treemap anymore) and the small-variant threshold from `px <= 32` to `px <= 64`.

- [ ] **Step 6: Regenerate and inspect the icon**

Run:
```bash
swift scripts/make-icon.swift Resources/
T=$(mktemp -d) && AIRY_ICON_PREVIEW=1 swift scripts/make-icon.swift "$T" && ls "$T"
iconutil -c iconset Resources/Airy.icns -o "$T/check.iconset" && ls "$T/check.iconset" | wc -l
```
Expected: «Icono generado: …» (Icon generated: …), `preview-16.png preview-32.png preview-64.png Airy-1024.png Airy.icns`, and `10`. Open `Resources/Airy-1024.png` and the three previews with the image reading tool: large, a turquoise→indigo squircle with three arcs and three leaves; at 16/32/64, a thick arc and a leaf that are legible, without smudges.

- [ ] **Step 7: Run the whole geometry suite**

Run: `swift test --filter AiryLogoGeometryTests`
Expected: PASS (8).

- [ ] **Step 8: Commit**

```bash
git add Sources/DiskMapCore/Design/AiryLogoGeometry.swift Tests/DiskMapCoreTests/AiryLogoGeometryTests.swift scripts/make-icon.swift Resources/Airy.icns Resources/Airy-1024.png
git commit -m "feat: swirl-with-leaves icon and variant for small sizes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `Theme.Airy`, the palette across the app, `RiskBadge` and `AiryLogo`

**Files:**
- Modify: `Sources/Airy/Design/Theme.swift`, `Sources/Airy/Design/Components.swift`, `Sources/Airy/Map/TreemapCanvas.swift:41-66` (`TilePalette`), `Sources/Airy/Shell/RootView.swift` (`DetailBackground`, tint and text hierarchy), `Sources/Airy/Shell/Sidebar.swift:56-95` (brand and `AppGlyph`), `Sources/Airy/Shell/ScanProgressView.swift` (`ScanRing`), `Sources/Airy/Cleanup/FreedCelebration.swift`, `Sources/Airy/Cleanup/CleanupView.swift:160-175` (`HeroCard`), `Sources/Airy/Cleanup/ConfirmSheet.swift:170-178`, `Sources/Airy/Shell/FullDiskAccessBanner.swift:14`
- Create: `Sources/Airy/Design/AiryLogo.swift`

**Interfaces:**
- Consumes: `AiryPalette`, `AiryTokens`, `AiryAppearance` (Task 1); `AiryLogoGeometry` (Task 2); `Risk.label` (plan 1).
- Produces:
  - `extension Theme { enum Airy }` with the members of the interfaces table. The dynamic `Color`s are made with `Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })` from `AiryPalette.tokens(.dark/.light)`. `accentGradient = [accentFill, logoBottom]`, `destructiveGradient = [destructiveTop, destructiveBottom]`, `logoGradient = [logoTop, logoBottom]` (`topLeading → bottomTrailing`). `riskFill` = fixed safety color; `riskInk` = dynamic with `AiryPalette.riskInk`; `swirlTint(_:) = Color(hex: AiryPalette.swirlTint(heat: WindMotion.heat(for:)))` (add it in Task 4 along with `WindMotion`; here only `riskFill`/`riskInk` and the tokens).
  - `Theme.color(for: ContentKind)` → `Color(hex: AiryPalette.kind(kind))`; `Theme.color(for: Risk)` → `Theme.Airy.riskFill(risk)` (icons, dots, rings); `Theme.brand` → `Theme.Airy.accentGradient`; `Theme.userFiles` → `Theme.Airy.logoGradient`; `Theme.userFilesColor` → `Theme.Airy.accent`; `Theme.systemColor` → `Color(hex: AiryPalette.kind(.system))`; `Theme.purgeableColor` → `Color(hex: 0x9fb3d9)`.
  - `struct RiskBadge: View { init(risk: Risk, compact: Bool = false, reason: String? = nil) }` — text `risk.label`, symbol `Theme.symbol(for:)`, foreground `Theme.Airy.riskInk(risk)`, background `riskFill.opacity(AiryPalette.badgeTintOpacity)`, border `riskFill.opacity(0.35)`, `.help(reason ?? risk.label)`, `accessibilityLabel` = `risk.label` + («. » + reason if there is one). The three existing calls (`CleanupRow`, `ConfirmSheet`, `HoverCard`) now show the new texts with no further changes: this is intentional (plan 3 groups and explains).
  - `struct AiryLogo: View { init(size: CGFloat, animated: Bool = false) }` — continuous squircle (`RoundedRectangle(cornerRadius: size * 185/824, style: .continuous)`) with `logoGradient`, arcs and leaves from `AiryLogoGeometry` scaled by `size/824` from the squircle; variant by `variant(forPixelSize: size * displayScale)` (`@Environment(\.displayScale)`). `animated` is ignored in this task (Task 5 turns it on). Replaces `AppGlyph` (deleted).

Application rules:
- `TilePalette`: gradient = `tileStops(base)`, text **and** secondary text = `tileInk(base)` at opacity 1 (size is distinguished by font weight, not by transparency); «Otros» (Other) uses `AiryPalette.others`.
- `RootView`: `.tint(Theme.Airy.accent)` and `.foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)` at the root and again in the sheet's `Group` (so `.secondary`/`.tertiary` inherit AA tones); `DetailBackground` paints `Theme.Airy.background` with the two radial halos in `accent`/`logoBottom` (opacity 0.10/0.08 dark, 0.06/0.04 light). Task 5 replaces it with `BreezeBackground`.
- `Sidebar`: `.scrollContentBackground(.hidden)` and background `Theme.Airy.backgroundRaised`; brand with `AiryLogo(size: 26)`.
- Text with a risk color (not icons): `Theme.Airy.riskInk(_:)` instead of `Theme.color(for: Risk)` — review with `grep -rn "foregroundStyle(Theme.color(for: \." Sources/Airy` and change the ones that tint a `Text`.
- `PrimaryButton`: `.destructive` uses `destructiveGradient`; `ConfirmSheet:174` the same; `FullDiskAccessBanner` uses `riskFill(.yourCall)`; `FreedCelebration` ring `[riskFill(.safe), sky]` and particles `[safe, sky, accent, leafSky, logoTop]`; `HeroCard` same as the ring; `ScanRing` uses `logoGradient`.

- [ ] **Step 1: Implement `Theme.Airy`, the mappings and `RiskBadge`**

- [ ] **Step 2: Implement `AiryLogo` and replace `AppGlyph`**

Run: `grep -rn "AppGlyph" Sources/Airy`
Expected: no results.

- [ ] **Step 3: Apply the palette rules above to the listed files**

Run: `grep -rn "Color(hex: 0x" Sources/Airy | grep -v Design/Theme.swift`
Expected: no results (every color goes through `Theme`/`AiryPalette`).

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!` and all tests green.

- [ ] **Step 5: Snapshot both appearances and inspect them**

Run:
```bash
for A in dark light; do for S in map cleanup; do
  T=$(mktemp -d); D=$(mktemp -d)
  AIRY_SUPPORT_DIR=$D AIRY_SNAPSHOT_DIR=$T AIRY_SNAPSHOT_PREFIX=$A-$S AIRY_SNAPSHOT_TIMES=8 \
    AIRY_APPEARANCE=$A AIRY_SECTION=$S .build/debug/Airy & PID=$!
  sleep 10; kill $PID; ls $T
done; done
```
Expected: one PNG per combination. Open them: night background `#07112a` (dark) / `#f3f7ff` (light), raised sidebar, new 26 pt logo, tiles in the cool range with legible labels, labels «Sin problema / Tú decides / No borrar» in Cleanup, blue buttons with white text.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: high-contrast blue palette, RiskBadge and vector logo

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Deterministic motion in the core

**Files:**
- Create: `Sources/DiskMapCore/Design/WindMotion.swift`
- Modify: `Sources/Airy/Design/Theme.swift` (add `Theme.Airy.swirlTint(_:)`)
- Test: `Tests/DiskMapCoreTests/WindMotionTests.swift`

**Interfaces:**
- Consumes: `AiryLogoGeometry.launchTargets(count:)` (Task 2), `SpringCurve` (`Layout/MapGeometry.swift`).
- Produces (all `public`, `Sendable`; coordinates in points except where it says «normalized»):
  - `struct LeafPose: Equatable { x, y, rotation /* rad */, scale, opacity: Double }`
  - `enum MotionMode: Equatable { case running, paused, reduced }`
  - `enum AnimationGate { static func ambient(windowVisible: Bool, appActive: Bool, reduceMotion: Bool) -> MotionMode; static func transient(windowVisible: Bool, reduceMotion: Bool) -> MotionMode }` — ambient: hidden or inactive ⇒ `.paused`; otherwise «Reducir movimiento» ⇒ `.reduced`; otherwise `.running`. Transient (delete, gust, launch): hidden ⇒ `.paused` (jumps to the final state); «Reducir movimiento» ⇒ `.reduced` (fade); otherwise `.running` (even if the app is inactive: the user has just confirmed).
  - `enum BreezeIntensity { case ambient, scan }`, `struct BreezeStreak: Equatable { yFraction, lengthFraction, thickness, opacity, period /* s */, phase /* 0…1 */: Double }`
  - `enum WindMotion` with:
    - `static func noise(_ index: Int, _ salt: Int) -> Double` — in [0, 1), deterministic (splitmix64-style mixing like `ParticleBurst.random`, which may switch to using this one).
    - Launch: `static let launchLeafCount = 18`; `static func launchTimeline(_ mode: MotionMode) -> (gather: Double, hold: Double, fade: Double)` — `.running` (1.4, 0.25, 0.35), `.reduced` (0.25, 0.2, 0.25), `.paused` (0, 0, 0); `static func launchLeaf(index: Int, count: Int, progress: Double) -> LeafPose` in normalized coordinates: it starts from a radius of 2.4…3.2, spirals (≈ 1.1 extra turns) and arrives with an ease-out at the target `launchTargets(count:)[index]`; opacity 0 → 1 in the first 25 %; `progress ≥ 1` ⇒ exactly the target, opacity 1, scale 1.
    - Orbit: `static let orbitAngularSpeed = 0.9` (rad/s); `static func orbitLeaf(index: Int, count: Int, time: Double, radius: Double) -> LeafPose` around (0, 0), radius with ±6 % sway, base angle equally distributed.
    - Breaking apart into leaves: `static let dissolveDuration = 0.75`; `static func leafCount(for rect: CGRect) -> Int` = `clamp(Int(area/1800), 6, 24)` (0 if the area is not finite); `static func dissolveLeaf(index: Int, count: Int, progress: Double, in rect: CGRect) -> LeafPose` — born inside `rect`, goes to the right (Δx 80…240 with ease-out) and rises a bit with fluttering, opacity rises up to 15 % and falls to 0 at 1, scale 1 → 0.6.
    - Flying off: `static func leafAwayTransform(progress: Double) -> (dx: Double, dy: Double, rotationDegrees: Double, scale: Double, opacity: Double)` = (220·p², −24·p, 6·p, 1 − 0.12·p, 1 − p), `p` clamped.
    - Gust: `static let gustRowDelay = 0.04`, `gustRowDuration = 0.55`, `gustMaxDuration = 1.2`, `gustBandDuration = 0.9`; `static func gustDuration(rowCount: Int) -> Double` = 0 if there are no rows, otherwise `min((n−1)·0.04, 0.65) + 0.55`; `static func gustRowOffset(row: Int, rowCount: Int, elapsed: Double) -> Double` = `14·sin(π·q)` with `q` the row's own progress (delay `min(row·0.04, 0.65)`), 0 before and after.
    - Breeze: `static func breezeStreaks(_ intensity: BreezeIntensity) -> [BreezeStreak]` — `.ambient`: 3 streaks, opacity ≤ 0.06, period 18…26 s; `.scan`: 6 streaks, opacity 0.08…0.14, period 4…6 s; values with `noise`.
    - Swirl: `static func swirlRevolutionsPerSecond(cpuLoad: Double) -> Double` = `0.06 + 0.84·clamp(load, 0, 1)` (`NaN` ⇒ 0.06); `static func heat(for state: ProcessInfo.ThermalState) -> Double` = nominal 0, fair 0.35, serious 0.7, critical 1 (unknown ⇒ 0).
    - `struct SwirlPhase { var angle: Double; mutating func advance(to time: Double, revolutionsPerSecond: Double) -> Double }` — integrates the angle (rad, modulo 2π) so that a speed change does not cause jumps; the first `advance` only sets the time; `dt` is clamped to 1/15 s (after a pause it does not jump).
    - Sway: `static let swayKeyframes: [(degrees: Double, time: Double)] = [(1.6, 0.12), (-1.1, 0.26), (0.5, 0.42), (0, 0.6)]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import DiskMapCore

struct WindMotionTests {
    @Test func ambientPausesWhenHiddenOrInactive() {
        #expect(AnimationGate.ambient(windowVisible: false, appActive: true, reduceMotion: false) == .paused)
        #expect(AnimationGate.ambient(windowVisible: true, appActive: false, reduceMotion: false) == .paused)
        #expect(AnimationGate.ambient(windowVisible: false, appActive: false, reduceMotion: true) == .paused)
        #expect(AnimationGate.ambient(windowVisible: true, appActive: true, reduceMotion: false) == .running)
    }

    @Test func reduceMotionWinsOverRunning() {
        #expect(AnimationGate.ambient(windowVisible: true, appActive: true, reduceMotion: true) == .reduced)
        #expect(AnimationGate.transient(windowVisible: true, reduceMotion: true) == .reduced)
        #expect(AnimationGate.transient(windowVisible: true, reduceMotion: false) == .running)
        #expect(AnimationGate.transient(windowVisible: false, reduceMotion: false) == .paused)
    }

    @Test func launchTimelineIsShortWithReduceMotion() {
        let running = WindMotion.launchTimeline(.running), reduced = WindMotion.launchTimeline(.reduced)
        #expect(running.gather + running.hold + running.fade <= 2.0)
        #expect(reduced.gather + reduced.hold + reduced.fade <= 0.7)
        let paused = WindMotion.launchTimeline(.paused)
        #expect(paused.gather + paused.hold + paused.fade == 0)
    }

    @Test func launchLeavesLandExactlyOnTheLogo() {
        let n = WindMotion.launchLeafCount
        let targets = AiryLogoGeometry.launchTargets(count: n)
        for i in 0..<n {
            let start = WindMotion.launchLeaf(index: i, count: n, progress: 0)
            #expect(hypot(start.x, start.y) >= 2.4)
            #expect(start.opacity == 0)
            let end = WindMotion.launchLeaf(index: i, count: n, progress: 1)
            #expect(abs(end.x - targets[i].x) < 1e-9 && abs(end.y - targets[i].y) < 1e-9)
            #expect(end.opacity == 1 && end.scale == 1)
            #expect(WindMotion.launchLeaf(index: i, count: n, progress: 0.4)
                    == WindMotion.launchLeaf(index: i, count: n, progress: 0.4))   // deterministic
        }
    }

    @Test func orbitStaysOnTheRing() {
        for i in 0..<7 { for t in stride(from: 0.0, through: 10, by: 0.37) {
            let p = WindMotion.orbitLeaf(index: i, count: 7, time: t, radius: 100)
            #expect((92...108).contains(hypot(p.x, p.y)))
        } }
        let a = WindMotion.orbitLeaf(index: 0, count: 7, time: 0, radius: 100)
        let b = WindMotion.orbitLeaf(index: 0, count: 7, time: 1, radius: 100)
        #expect(a != b)
    }

    @Test func dissolveStartsInsideAndBlowsRightUntilGone() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 60)
        let n = WindMotion.leafCount(for: rect)
        for i in 0..<n {
            let start = WindMotion.dissolveLeaf(index: i, count: n, progress: 0, in: rect)
            #expect(rect.contains(CGPoint(x: start.x, y: start.y)))
            let xs = stride(from: 0.0, through: 1, by: 0.1).map { WindMotion.dissolveLeaf(index: i, count: n, progress: $0, in: rect).x }
            #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(WindMotion.dissolveLeaf(index: i, count: n, progress: 1, in: rect).opacity == 0)
        }
    }

    @Test func dissolveHandlesDegenerateRect() {
        let pose = WindMotion.dissolveLeaf(index: 3, count: 6, progress: 0.5, in: .zero)
        #expect([pose.x, pose.y, pose.rotation, pose.scale, pose.opacity].allSatisfy(\.isFinite))
        #expect(WindMotion.leafCount(for: .zero) == 6)
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)) == 0)
    }

    @Test func leafCountIsClamped() {
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: 4000, height: 3000)) == 24)
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: 20, height: 20)) == 6)
    }

    @Test func leafAwayGoesFromIdentityToGone() {
        let start = WindMotion.leafAwayTransform(progress: 0)
        #expect(start.dx == 0 && start.dy == 0 && start.rotationDegrees == 0 && start.scale == 1 && start.opacity == 1)
        let end = WindMotion.leafAwayTransform(progress: 1)
        #expect(end.dx == 220 && end.opacity == 0)
        #expect(WindMotion.leafAwayTransform(progress: 5).opacity == 0)
    }

    @Test func gustSweepsTopRowFirstAndSettles() {
        #expect(WindMotion.gustDuration(rowCount: 0) == 0)
        #expect(WindMotion.gustRowOffset(row: 0, rowCount: 5, elapsed: 0) == 0)
        #expect(WindMotion.gustRowOffset(row: 0, rowCount: 5, elapsed: 0.1) > WindMotion.gustRowOffset(row: 4, rowCount: 5, elapsed: 0.1))
        let end = WindMotion.gustDuration(rowCount: 5)
        for row in 0..<5 { #expect(abs(WindMotion.gustRowOffset(row: row, rowCount: 5, elapsed: end)) < 1e-9) }
    }

    @Test func gustDurationIsCappedForHugeLists() {
        #expect(WindMotion.gustDuration(rowCount: 500) <= WindMotion.gustMaxDuration)
        #expect(abs(WindMotion.gustRowOffset(row: 499, rowCount: 500, elapsed: WindMotion.gustMaxDuration)) < 1e-9)
    }

    @Test func ambientBreezeIsSoftAndScanBreezeIsLively() {
        let ambient = WindMotion.breezeStreaks(.ambient), scan = WindMotion.breezeStreaks(.scan)
        #expect(ambient.count == 3 && scan.count == 6)
        #expect(ambient.allSatisfy { $0.opacity <= 0.06 && $0.period >= 18 })
        #expect(scan.allSatisfy { $0.period <= 6 && $0.opacity <= 0.14 })
        #expect(WindMotion.breezeStreaks(.scan) == scan)
    }

    @Test func swirlSpeedFollowsCPUAndClampsGarbage() {
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0) == 0.06)
        #expect(abs(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 1) - 0.9) < 1e-12)
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0.5) < WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0.8))
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: .nan) == 0.06)
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: -3) == 0.06)
        #expect(abs(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 40) - 0.9) < 1e-12)
    }

    @Test func heatFollowsThermalState() {
        #expect(WindMotion.heat(for: .nominal) == 0)
        #expect(WindMotion.heat(for: .fair) == 0.35)
        #expect(WindMotion.heat(for: .serious) == 0.7)
        #expect(WindMotion.heat(for: .critical) == 1)
    }

    @Test func swirlPhaseIsContinuousWhenSpeedChanges() {
        var phase = SwirlPhase()
        _ = phase.advance(to: 0, revolutionsPerSecond: 0.1)
        let a = phase.advance(to: 1.0 / 60, revolutionsPerSecond: 0.1)
        let b = phase.advance(to: 2.0 / 60, revolutionsPerSecond: 0.9)
        #expect(abs(b - a - 2 * .pi * 0.9 / 60) < 1e-9)
    }

    @Test func swirlPhaseDoesNotJumpAfterPause() {
        var phase = SwirlPhase()
        _ = phase.advance(to: 0, revolutionsPerSecond: 0.9)
        let before = phase.advance(to: 0.016, revolutionsPerSecond: 0.9)
        let after = phase.advance(to: 120, revolutionsPerSecond: 0.9)   // two minutes paused
        #expect(abs(after - before) <= 2 * .pi * 0.9 / 15 + 1e-9)
    }

    @Test func swayEndsAtRestAndDecays() {
        let keys = WindMotion.swayKeyframes
        #expect(keys.last?.degrees == 0 && keys.last?.time == 0.6)
        let amplitudes = keys.map { abs($0.degrees) }
        #expect(zip(amplitudes, amplitudes.dropFirst()).allSatisfy { $0 > $1 })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WindMotionTests`
Expected: FAIL to compile («cannot find 'AnimationGate' in scope»).

- [ ] **Step 3: Implement `WindMotion.swift` per the Interfaces block, and `Theme.Airy.swirlTint(_:)`**

- [ ] **Step 4: Run tests to verify they pass, then the whole suite**

Run: `swift test --filter WindMotionTests && swift test`
Expected: PASS (17 in `WindMotionTests`) and everything else green.

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskMapCore/Design/WindMotion.swift Tests/DiskMapCoreTests/WindMotionTests.swift Sources/Airy/Design/Theme.swift
git commit -m "feat: deterministic wind animation poses and motion gatekeeper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Motion gatekeeper, background breeze, leaves, animated logo and swaying buttons

**Files:**
- Create: `Sources/Airy/Design/Motion.swift`, `Sources/Airy/Design/BreezeBackground.swift`, `Sources/Airy/Design/WindLeaves.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (gatekeeper injection; `DetailBackground` → `BreezeBackground(intensity: .ambient)`), `Sources/Airy/Design/AiryLogo.swift` (`animated`), `Sources/Airy/Design/Components.swift` (`PrimaryButtonBody` with `.hoverSway`), `Sources/Airy/Shell/Sidebar.swift` (`AiryLogo(size: 26, animated: true)`), `Sources/Airy/Shell/DebugSnapshot.swift`

**Interfaces:**
- Consumes: `AnimationGate`, `MotionMode`, `BreezeIntensity`, `WindMotion.*` (Task 4); `Theme.Airy` (Task 3); `FPSMeter` (`Map/TreemapCanvas.swift`, DEBUG).
- Produces:
  - `EnvironmentValues.airyAmbientMotion: MotionMode` (default `.paused`) and `.airyTransientMotion: MotionMode` (default `.reduced`), with hand-written `EnvironmentKey`. Default "stopped": a view that does not receive the gatekeeper (e.g. a new sheet that forgot to inject it) does not spend CPU.
  - `struct WindowActivityReader: NSViewRepresentable { var onChange: (_ visible: Bool, _ active: Bool) -> Void }` — takes `view.window` in `viewDidMoveToWindow` and listens to `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturizeNotification`, `didDeminiaturizeNotification` (of that window) and `NSApplication.didBecomeActiveNotification`, `didResignActiveNotification`, `didHideNotification`, `didUnhideNotification`; visible = `occlusionState.contains(.visible) && !isMiniaturized && !NSApp.isHidden`; active = `NSApp.isActive`.
  - `RootView` stores `windowVisible`/`appActive` in `@ViewState`, reads `accessibilityReduceMotion` (in DEBUG, `AIRY_REDUCE_MOTION=1` forces it to `true`) and injects both modes into the content **and** into the sheet's `Group`. In DEBUG with `AIRY_FPS=1`, every ambient mode change writes `[motion] ambiente: running|paused|reduced` (ambiente = ambient) with `FPSMeter.log`.
  - `struct BreezeBackground: View { init(intensity: BreezeIntensity = .ambient) }` — `Theme.Airy.background` + Task 3 halos + the streaks of `WindMotion.breezeStreaks(intensity)`: capsules with a horizontal gradient transparent → `Theme.Airy.sky.opacity(streak.opacity)` → transparent (no `.blur`, no `Canvas`), crossing from left to right with `.linear(duration: period).repeatForever(autoreverses: false)` animated by the render server (like `ScanRing`), starting at `phase`. With `airyAmbientMotion != .running` a **different**, static view is drawn (streaks still at their `phase`): that way the infinite animation really disappears. `.allowsHitTesting(false)`, `.ignoresSafeArea()`.
  - `struct WindLeaves: View { enum Mode: Equatable { case orbit(radius: CGFloat); case launch(start: Date); case burst(start: Date, rect: CGRect) }; init(mode: Mode, count: Int = 7) }` — a single `Canvas(rendersAsynchronously: true)` inside `TimelineView(.animation(minimumInterval: nil, paused: …))`; it draws each leaf with `Path(AiryLogoGeometry.leafPath(length: 11, width: 5))` (×1.6 in `.launch`) transformed by the pose, alternating white and `Theme.Airy.leafSky` (in light mode, `Theme.Airy.accent` and `sky` so they are visible). `.orbit` uses `orbitLeaf` around the view's center and pauses with `airyAmbientMotion != .running`; `.launch` and `.burst` use `launchLeaf`/`dissolveLeaf` with progress `(date − start)/duration`, pause with `airyTransientMotion != .running` and draw nothing past their end (whoever shows them removes them, like `ParticleBurst`). In DEBUG it calls `FPSMeter.shared.tick()` per frame. Leaf view: input values only, nothing observable.
  - `AiryLogo(animated: true)`: the arcs turn slowly (one turn every 20 s) with the render server's `repeatForever` only if `airyAmbientMotion == .running`; otherwise a static view.
  - `extension View { func hoverSway(_ hovering: Bool) -> some View }` — on switching to `true`, `keyframeAnimator(initialValue: 0.0, trigger: counter)` with `WindMotion.swayKeyframes` on `.rotationEffect(.degrees(_), anchor: .bottom)`; with `airyTransientMotion != .running` it does nothing.
  - DEBUG in `DebugSnapshot.configure`: `AIRY_HIDE_AT=<s>` calls `NSApp.hide(nil)` at those seconds and `AIRY_UNHIDE_AT=<s>` calls `NSApp.unhide(nil)` (the app itself only).

- [ ] **Step 1: Implement `Motion.swift` (keys, reader, `hoverSway`) and wire `RootView`**

- [ ] **Step 2: Implement `BreezeBackground` and replace `DetailBackground`**

- [ ] **Step 3: Implement `WindLeaves`, animated `AiryLogo`, `hoverSway` on `PrimaryButtonBody`, DEBUG hide/unhide**

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all green.

- [ ] **Step 5: Verify zero CPU when hidden and low CPU when idle-visible**

Run:
```bash
D=$(mktemp -d); AIRY_SUPPORT_DIR=$D AIRY_FPS=1 AIRY_SKIP_LAUNCH=1 AIRY_HIDE_AT=60 AIRY_UNHIDE_AT=90 \
  .build/debug/Airy 2> "$D/log.txt" & PID=$!
sleep 50; ps -o %cpu= -p $PID     # analysis finished, window active and still
sleep 25; ps -o %cpu= -p $PID     # hidden since second 60
sleep 20; ps -o %cpu= -p $PID     # visible again
kill $PID; grep "\[motion\]" "$D/log.txt"
```
Expected: visible and still ≤ 3 %; hidden ≤ 0.3 % (zero in practice); on return, again ≤ 3 %; the log shows `ambiente: running`, `ambiente: paused` and `ambiente: running` again. If the analysis has not finished by 50 s, lengthen the first wait (the analysis does not count as rest). `AIRY_SKIP_LAUNCH` does not exist until Task 6: until then it is ignored.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: background breeze, leaves and sway with full pause when out of view

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Launch (the leaves form the logo) and analysis (breeze and orbiting leaves)

**Files:**
- Create: `Sources/Airy/Shell/LaunchSwirl.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (launch layer), `Sources/Airy/Shell/ScanProgressView.swift` (`hero`), `Sources/Airy/Shell/DebugSnapshot.swift` (`AIRY_SKIP_LAUNCH`)

**Interfaces:**
- Consumes: `WindLeaves(.launch)`, `WindLeaves(.orbit)`, `BreezeBackground(.scan)`, `AiryLogo` (Task 5); `WindMotion.launchTimeline(_:)`, `launchLeafCount` (Task 4).
- Produces:
  - `struct LaunchSwirl: View { var onDone: () -> Void }` — full-screen opaque `Theme.Airy.background` layer; in the center, `WindLeaves(mode: .launch(start:), count: WindMotion.launchLeafCount)` in a 240 pt box (normalized unit = 120 pt) and `AiryLogo(size: 120)` fading in during the last 35 % of `gather`; then `hold` and the whole layer fades out over `fade`; a click closes it immediately. With the transient mode `.reduced`: only the logo with a fade in/out (timings from `launchTimeline(.reduced)`); with `.paused`: immediate `onDone()`. It ends with `DispatchQueue.main.asyncAfter` (not `Task.sleep`, see why in `MapScene.scheduleStop`).
  - `RootView`: shows `LaunchSwirl` only once per process (`static var hasPlayed`), above everything; the analysis starts at the same time (`.task { model.startScan() }` does not wait). In DEBUG it is skipped if `AIRY_SKIP_LAUNCH=1` or if any `AIRY_*_SCRIPT` variable is set (the existing debug scripts must not change their timings).
  - `ScanProgressView.hero`: `BreezeBackground(intensity: .scan)` behind the hero content (only while the hero is shown) and `WindLeaves(mode: .orbit(radius: 98), count: 7)` in a 240 pt box centered on the 168 pt `ScanRing`. The `.compact` pill does not change.

- [ ] **Step 1: Implement `LaunchSwirl` and the `RootView` layer with the DEBUG skip**

- [ ] **Step 2: Add breeze and orbiting leaves to `ScanProgressView.hero`**

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all green.

- [ ] **Step 4: Capture the launch and the scan, normal and reduced**

Run:
```bash
for R in 0 1; do T=$(mktemp -d); D=$(mktemp -d)
  AIRY_SUPPORT_DIR=$D AIRY_SNAPSHOT_DIR=$T AIRY_SNAPSHOT_PREFIX=rm$R AIRY_SNAPSHOT_TIMES=0.4,1.0,1.6,2.4,4 \
    AIRY_REDUCE_MOTION=$R AIRY_APPEARANCE=dark AIRY_FPS=1 .build/debug/Airy 2> $D/log & PID=$!
  sleep 7; kill $PID; ls $T; grep "\[fps\]" $D/log | tail -3
done
```
Expected (`rm0`): at 0.4 s leaves spiraling; at 1.0 s almost forming the swirl; at 1.6 s the complete logo; at 2.4 s the app with the analysis (breeze and leaves around the ring); with `AIRY_FPS=1`, the `[fps]` lines of the animations ≥ 60 fps. (`rm1`): at 0.4 s only the logo fading in, at 1.0 s already the app, nothing spinning nor orbiting leaves. Open the PNGs to check.

- [ ] **Step 5: Commit**

```bash
git add Sources/Airy
git commit -m "feat: launch with leaves forming the logo and breeze during analysis

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Deleting is carried away by the wind: rows and blocks into leaves, counter that goes up and batch gust

**Files:**
- Create: `Sources/Airy/Design/GustSweep.swift`
- Modify: `Sources/Airy/Design/WindLeaves.swift` (`AnyTransition.leafAway`), `Sources/Airy/Cleanup/CleanupFlow.swift` (`gust`, `batchFreed`), `Sources/Airy/Cleanup/CleanupView.swift` (`GroupSection` and gust and counter layer), `Sources/Airy/Map/MapScene.swift` (leaf bursts), `Sources/Airy/Map/TreemapCanvas.swift` (`MapRenderer.draw`), `Sources/Airy/Map/MapView.swift` (`TrashCandidate`, `requestTrash`)

**Interfaces:**
- Consumes: `WindMotion.leafAwayTransform`, `dissolveLeaf`, `leafCount(for:)`, `dissolveDuration`, `gustRowOffset`, `gustDuration`, `gustBandDuration` (Task 4); `WindLeaves`, `airyTransientMotion` (Task 5).
- Produces:
  - `extension AnyTransition { static var leafAway: AnyTransition }` = `.asymmetric(insertion: .opacity, removal: .modifier(active: LeafAwayEffect(progress: 1), identity: LeafAwayEffect(progress: 0)))`. `LeafAwayEffect: ViewModifier, Animatable` (`animatableData = progress`): applies `leafAwayTransform(progress:)` to the content (`offset`, `rotationEffect`, `scaleEffect`, `opacity`) and overlays a **clockless** `Canvas` (redrawn by `progress`'s own interpolation) with `leafCount(for:)` leaves from `dissolveLeaf` at the content's size (`GeometryReader` in the `overlay`). Reads `airyTransientMotion`: anything other than `.running` ⇒ only `opacity(1 − progress)`. It serves equally for «delete a row» and for «the row of a closed app flies off» (plan 4).
  - `CleanupFlow.Gust: Equatable { let id: UUID; let start: Date; let order: [String] }` and `private(set) var gust: Gust?` — set in `confirm(_:model:)` for `.items` with ≥ 2 elements (`order` = ids in execution order) and cleared after `WindMotion.gustDuration(rowCount:) + 0.1` s with `DispatchQueue.main.asyncAfter`. Plan 3's «Borrar todo» calls `requestClean` and gets the gust with nothing else.
  - `CleanupFlow.batchFreed: Int64` (`private(set)`) — 0 at the start of each `.items` batch; adds the bytes of each `.freed`/`.movedToTrash`.
  - `struct GustSweep: View { let start: Date }` — wide vertical band (≈ 40 % of the width) with a gradient transparent → `Theme.Airy.sky.opacity(0.18)` → transparent and a few leaves, crossing from left to right in `gustBandDuration`; `TimelineView(.animation(paused: airyTransientMotion != .running))`; draws nothing past its end.
  - `extension View { func gustSway(index: Int?, start: Date?) -> some View }` — if both exist and the transient mode is `.running`, `offset(x: gustRowOffset(row: index, rowCount:, elapsed:))` inside a `TimelineView` that only exists until `gustDuration`; otherwise nothing.
  - `MapScene.burst(rect: CGRect)` — adds `MapLeafBurst(rect:, start: CACurrentMediaTime())` to `private(set) var bursts: [MapLeafBurst]` and calls `keepAnimating(fadeEnd: start + WindMotion.dissolveDuration)`; `finishAnimating` removes the finished ones. `MapFrame` gains `bursts`; `MapRenderer.draw` paints, after the tiles, the leaves of each live burst with `dissolveLeaf` (color: the tile's light ink, `leafSky`).
  - `TrashCandidate` gains `rect: CGRect?` (rectangle in the canvas of the tile whose menu was opened: `scene.layout?.tile(id: details.id)?.rect`); in `requestTrash`, with `.movedToTrash` or `.freed` and `airyTransientMotion == .running`, `scene.burst(rect:)` is called before showing the notice.

Cleanup wiring: in `GroupSection`, each row's exit transition changes from `.opacity.combined(with: .scale(...))` to `.leafAway` and each row receives `.gustSway(index: order.firstIndex(of: item.id), start: flow.gust?.start)`; `CleanupView` overlays `GustSweep(start:)` on the list while `flow.gust` exists (`.allowsHitTesting(false)`) and, at the bottom, while `flow.isRunning && flow.batchFreed > 0`, a pill `leaf.fill` + `BytesCounter(bytes: flow.batchFreed, countsUpOnAppear: false)` + «liberados» (freed) that goes up with each row (`BytesCounter` already rolls the digits). The spring that collapses the row (`hiddenIDs` with `Theme.zoomSpring`) does not change.

- [ ] **Step 1: Implement `.leafAway` and switch the cleanup rows to it**

- [ ] **Step 2: Add `gust`/`batchFreed` to `CleanupFlow`, implement `GustSweep`/`gustSway` and the freed pill in `CleanupView`**

- [ ] **Step 3: Implement the map leaf burst (`MapScene.burst`, renderer, `TrashCandidate.rect`)**

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all green.

- [ ] **Step 5: Watch it with the DEBUG gallery's fake rows (no real cleanup)**

The visual verification of this task is done in Task 8 (gallery with fake rows that are deleted without touching the disk). Here it is enough to check that no live clocks remain after a gust:

Run: `grep -n "repeatForever\|TimelineView" Sources/Airy/Design/*.swift Sources/Airy/Shell/LaunchSwirl.swift`
Expected: every occurrence is behind a `paused:` or inside a view that only exists while its effect lasts or while the mode is `.running` (review them one by one).

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: rows and blocks carried off by the wind, freed counter and batch gust

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `WindSwirl` for Performance and motion gallery (DEBUG)

**Files:**
- Create: `Sources/Airy/Design/WindSwirl.swift`, `Sources/Airy/Design/MotionGallery.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (gallery in DEBUG), `Sources/Airy/Shell/DebugSnapshot.swift` (document the new variables in its comment)

**Interfaces:**
- Consumes: `SwirlPhase`, `WindMotion.swirlRevolutionsPerSecond`, `WindMotion.heat(for:)` (Task 4); `Theme.Airy.swirlTint(_:)`; `.leafAway`, `GustSweep`, `gustSway`, `WindLeaves`, `RiskBadge`, `AiryLogo` (Tasks 3–7).
- Produces:
  - `struct WindSwirl: View { init(speed: Double, tint: Color) }` — `speed` in revolutions per second; three concentric arcs (`AiryLogoGeometry.arcs(.full)`, `tint` stroke with each arc's opacity) and the three leaves, rotating with the angle of a `SwirlPhase` stored in a non-observable class in `@ViewState` (advanced inside the `Canvas` with the `TimelineView`'s date). `TimelineView(.animation(minimumInterval: nil, paused: airyAmbientMotion != .running))`; with `.reduced`, static and the tint changes with a 0.3 s fade. A change of `speed` never causes jumps (guaranteed by `SwirlPhase`). Intended use by plan 4: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: load), tint: Theme.Airy.swirlTint(ProcessInfo.processInfo.thermalState))`.
  - `MotionGallery` (`#if DEBUG` only, with `AIRY_MOTION_GALLERY=1` it replaces the section's content): four `WindSwirl` (load 0 / 0.5 / 1 with nominal state, and load 1 with `.serious`), five `RiskBadge` (the three risks, one compact, one with `reason`), `AiryLogo` at 16, 26, 64 and 128 pt, and a list of 6 fake rows (in-memory text only) with a «Simular borrado» (Simulate deletion) button that activates `GustSweep`/`gustSway` and then removes them one at a time every 0.25 s with `.leafAway`, while a pill with `BytesCounter` goes up. It does not call `CleanupFlow`, `AppModel` or anything that touches the disk. With `AIRY_GALLERY_AUTOPLAY=<s>` the button presses itself at those seconds (for screenshots).

- [ ] **Step 1: Implement `WindSwirl`**

- [ ] **Step 2: Implement `MotionGallery` and its DEBUG switch**

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all green.

- [ ] **Step 4: Capture the gallery mid-gust and with reduced motion**

Run:
```bash
for R in 0 1; do T=$(mktemp -d); D=$(mktemp -d)
  AIRY_SUPPORT_DIR=$D AIRY_SKIP_LAUNCH=1 AIRY_MOTION_GALLERY=1 AIRY_GALLERY_AUTOPLAY=3 AIRY_REDUCE_MOTION=$R \
    AIRY_SNAPSHOT_DIR=$T AIRY_SNAPSHOT_PREFIX=g$R AIRY_SNAPSHOT_TIMES=2.5,3.3,3.9,5.5 AIRY_FPS=1 \
    .build/debug/Airy 2> $D/log & PID=$!
  sleep 7; kill $PID; ls $T; grep "\[fps\]" $D/log | tail -3
done
```
Expected (`g0`): at 2.5 s four swirls (the last one orange), «Sin problema / Tú decides / No borrar» labels legible, logos with the small variant at 16/26 pt; at 3.3 s the gust band crossing and the rows displaced; at 3.9 s rows leaving as leaves and the pill counting; at 5.5 s empty list. `[fps]` ≥ 60. (`g1`): nothing moves, rows disappear with a fade, swirls still.

- [ ] **Step 5: Final checks for the whole plan**

Run: `swift test && swift build -c release && git status --short`
Expected: all tests green (including `AiryPaletteTests`, `AiryLogoGeometryTests`, `WindMotionTests`), `Build complete!` in release and no unexpected untracked files. Repeat step 5 of Task 5 (hidden CPU ≤ 0.3 %) now with all the animations mounted.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: Performance swirl and motion gallery for debugging

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
