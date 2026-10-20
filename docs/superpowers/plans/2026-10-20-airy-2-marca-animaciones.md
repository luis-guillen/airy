# Airy 2 de 5 — Marca y animaciones · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Airy estrena su marca de viento: icono «remolino con hojas» (con variante pequeña), paleta azul con acentos fríos y contraste AA comprobado por pruebas, colores de seguridad fijos con un `RiskBadge` de tres textos, y todas las animaciones de §2.2 (arranque, análisis, borrar, «Borrar todo», brisa de fondo, botones que se mecen y las piezas de Rendimiento) sin gastar CPU en reposo.

**Architecture:** Todo lo que se puede calcular sin SwiftUI vive en `DiskMapCore/Design/` y se prueba con Swift Testing: matemática de color y contraste WCAG, los tokens de la paleta, la geometría del logo y las poses deterministas de cada animación (funciones puras del tiempo o del progreso, sin estado aleatorio). La app (`Sources/Airy/Design/`) solo traduce esos números a `Color`, `Canvas` y transiciones, y un único «portero de movimiento» en `RootView` decide por entorno si cada animación corre, se pausa (ventana oculta o app inactiva ⇒ ningún reloj vivo) o se reduce a fundidos («Reducir movimiento»). El icono `.icns` sale del mismo script de CoreGraphics de siempre, con la geometría copiada de la librería y una huella que una prueba compara.

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, SwiftUI + AppKit (`Canvas`, `TimelineView`, `keyframeAnimator`, `AnyTransition.modifier`), CoreGraphics/ImageIO (`scripts/make-icon.swift`), `sips`/`iconutil`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.1 (logo, paleta, contraste, colores de seguridad), §2.2 (animaciones y sus límites), §4 («que las animaciones hagan la app pesada», «verse azul plano y aburrido o con poco contraste»), §7 («paleta clara derivada y valores exactos de contraste», «implementación de las animaciones»). Interfaces del plan 1 que se consumen: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` (`Risk.label`, identidad `Airy`, `Resources/Airy.icns`).

**Fuera de este plan:** agrupar Limpieza por las tres etiquetas, textos de «por qué» y botón «Borrar todo» (plan 3: consume `RiskBadge`, `.leafAway`, `CleanupFlow.gust`); sección Rendimiento (plan 4: consume `WindSwirl`, `.leafAway`, `Theme.Airy.swirlTint`); Desinstalador, Grandes y viejos, Duplicados, Tipos de archivo (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools (sin Xcode); `swift build` / `swift test`; plataforma `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing de Package.swift. El test target solo depende de `DiskMapCore`: todo lo que se prueba vive allí.
- Vistas SwiftUI con el alias `@ViewState` (no `@State`), nunca `.fixedSize(horizontal:false,vertical:true)` en `Text` multilínea. **Sin macros de SwiftUI** (`@State`, `@Entry`, `#Preview`): con Command Line Tools no compilan; las claves de entorno se escriben con `EnvironmentKey` a mano. Seguir los patrones existentes (`Theme`, `PrimaryButton`, `SectionHeader`, `GlassCard`).
- Interfaz en **español de España**.
- Paleta oscura (spec, literal): noche `#07112a`/`#0d2350`, azul `#2f8bff`, cielo `#5ab8ff`, texto `#f2f7ff`/secundario `#b9cdf0`. Logo: degradado `#2fd0ff` → `#2a3bd9`, tres arcos concéntricos de viento en blanco translúcido, hojas blancas/celestes. Variante ≤ 64 px: un solo arco grueso y una hoja.
- **Colores de seguridad fijos** (spec, literal): verde `#1fdc7a` (sin problema), ámbar `#ffb020` (tú decides), rojo `#ff4d5e` (no borrar). Son señales, no decoración: no se usan para adornar.
- **Contraste fuerte:** todo texto e indicador con contraste WCAG AA ≥ 4,5:1 en oscuro y en claro (comprobado por `AiryPaletteTests`).
- El mapa de bloques usa la **gama fría** (azules, turquesas, violetas, índigo), con cada tipo distinguible (ΔE76 ≥ 20 entre cualquier par).
- Animaciones: «Reducir movimiento» ⇒ solo fundidos; 60–120 fps; **cero CPU en reposo**: ningún `TimelineView` sin pausar ni animación `repeatForever` viva con la ventana oculta, minimizada, tapada o la app inactiva (patrón del mapa: `TimelineView(.animation(minimumInterval: nil, paused: …))` y relojes que solo existen mientras dura el efecto).
- Toda acción destructiva sigue pasando por `ConfirmSheet` → `AppModel` → `CleanupExecutor`; las animaciones solo **reaccionan** a resultados, nunca disparan borrados. Sin atajos DEBUG que actúen sin confirmación (los nuevos `AIRY_*` de depuración solo ocultan la ventana, saltan el arranque o enseñan una galería).
- Capturas DEBUG solo de las ventanas de la propia app; para parar la app, matar **solo el PID propio** (nunca `pkill -x`); cada verificación manual usa su propio `AIRY_SUPPORT_DIR` temporal. Nunca `scripts/build-app.sh --install`, nunca escribir en `/Applications`, nunca tocar el Llavero.
- En pruebas y verificación nunca se ejecutan limpiezas reales ni se vacía la Papelera real.
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Ventana minimizada, tapada, en otro Escritorio o app en segundo plano a mitad de una animación** → todos los relojes ambientales se paran (0 % CPU) y al volver siguen sin salto. Test en Task 4 (`ambientPausesWhenHiddenOrInactive`, `swirlPhaseDoesNotJumpAfterPause`) y verificación de CPU en Task 5.
2. **«Reducir movimiento» activado (antes o durante)** → nada se desplaza ni gira; el arranque es un fundido corto que no tapa la app más de 0,7 s. Test en Task 4 (`reduceMotionWinsOverRunning`, `launchTimelineIsShortWithReduceMotion`) y captura con `AIRY_REDUCE_MOTION=1` en Task 6.
3. **Modo claro** (la paleta derivada que no viene en la spec) → cada par de texto cumple AA igual que en oscuro, incluidas las etiquetas de riesgo. Test en Task 1 (`everyTextPairMeetsAA` con `.light`).
4. **«Borrar todo» con cientos de filas o bloques diminutos** → la ráfaga dura como mucho 1,2 s y las hojas por fila no se disparan; un rectángulo de 0×0 no produce `NaN`. Test en Task 4 (`gustDurationIsCappedForHugeLists`, `leafCountIsClamped`, `dissolveHandlesDegenerateRect`).
5. **Carga de CPU o estado térmico fuera de rango** (lo que pasará el plan 4: `NaN`, negativa, > 1) → la velocidad del remolino y el tinte se acotan, nunca se congela ni gira a lo loco. Test en Task 4 (`swirlSpeedClampsGarbage`) y Task 1 (`swirlTintWarmsWithHeat`).

---

## Interfaces públicas que consumen los planes 3–5

Nombres fijos (definidos aquí; los planes 3–5 los usan tal cual):

| Nombre | Dónde | Qué es |
|---|---|---|
| `Theme.Airy` | `Sources/Airy/Design/Theme.swift` | Paleta: `background`, `backgroundRaised`, `text`, `textSecondary`, `accent`, `sky`, `onAccent`, `leafSky` (`Color`, dinámicos claro/oscuro), `accentGradient`, `destructiveGradient`, `logoGradient` (`LinearGradient`), `riskFill(_ risk: Risk) -> Color`, `riskInk(_ risk: Risk) -> Color`, `swirlTint(_ thermal: ProcessInfo.ThermalState) -> Color` |
| `RiskBadge(risk:compact:reason:)` | `Sources/Airy/Design/Components.swift` | Etiqueta «Sin problema» / «Tú decides» / «No borrar» (`Risk.label`) con símbolo, tinta AA y `reason` opcional en la ayuda y en VoiceOver |
| `AiryLogo(size:animated:)` | `Sources/Airy/Design/AiryLogo.swift` | Logo vectorial; variante pequeña automática ≤ 64 px |
| `BreezeBackground(intensity:)` | `Sources/Airy/Design/BreezeBackground.swift` | Fondo de brisa; `BreezeIntensity.ambient` / `.scan` |
| `WindLeaves(mode:count:)` | `Sources/Airy/Design/WindLeaves.swift` | Hojas: `.orbit(radius:)`, `.launch(start:)`, `.burst(start:rect:)` |
| `AnyTransition.leafAway` | `Sources/Airy/Design/WindLeaves.swift` | Fila que sale volando como una hoja y se deshace en hojas (borrar en Limpieza; cerrar app en Rendimiento) |
| `WindSwirl(speed:tint:)` | `Sources/Airy/Design/WindSwirl.swift` | Remolino; `speed` en vueltas/s (usar `WindMotion.swirlRevolutionsPerSecond(cpuLoad:)`), `tint` (usar `Theme.Airy.swirlTint(_:)`) |
| `GustSweep(start:)`, `.gustSway(index:start:)` | `Sources/Airy/Design/GustSweep.swift` | Ráfaga que barre una lista de izquierda a derecha |
| `.hoverSway(_ hovering: Bool)` | `Sources/Airy/Design/Motion.swift` | Balanceo breve al pasar el ratón |
| `EnvironmentValues.airyAmbientMotion` / `.airyTransientMotion` (`MotionMode`) | `Sources/Airy/Design/Motion.swift` | Portero de movimiento; toda vista animada nueva lo lee |
| `CleanupFlow.gust: CleanupFlow.Gust?`, `CleanupFlow.batchFreed: Int64` | `Sources/Airy/Cleanup/CleanupFlow.swift` | La ráfaga se dispara sola en toda tanda confirmada de ≥ 2 elementos; `batchFreed` sube con cada fila |
| `AiryPalette`, `ColorMath`, `AiryLogoGeometry`, `WindMotion`, `AnimationGate`, `MotionMode`, `BreezeIntensity` | `Sources/DiskMapCore/Design/` | Núcleo puro y probado |

---

## Estructura de archivos

```
Sources/DiskMapCore/Design/                                   (nuevo)
  ColorMath.swift          luminancia WCAG, contraste, mezcla sRGB, ΔE76, tono
  AiryPalette.swift        tokens oscuro/claro, seguridad, tipos del mapa, comprobaciones de contraste
  AiryLogoGeometry.swift   arcos y hojas del logo (rejilla 1024), variante, objetivos del arranque, huella
  WindMotion.swift         poses deterministas: arranque, órbita, deshacerse, salir volando, ráfaga,
                           brisa, remolino, balanceo; MotionMode/AnimationGate; BreezeIntensity
Tests/DiskMapCoreTests/
  AiryPaletteTests.swift, AiryLogoGeometryTests.swift, WindMotionTests.swift   (nuevos)
scripts/make-icon.swift    remolino con hojas; variante pequeña para ≤ 64 px
Resources/Airy.icns, Resources/Airy-1024.png                  (regenerados)
Sources/Airy/Design/
  Theme.swift              + Theme.Airy; tipos, riesgo y marca pasan a la paleta nueva
  Components.swift         RiskBadge nuevo, PrimaryButton con tinta AA y balanceo
  AiryLogo.swift           logo vectorial (sustituye a AppGlyph)                     (nuevo)
  Motion.swift             claves de entorno, lector de actividad de ventana, hoverSway (nuevo)
  BreezeBackground.swift   brisa de fondo                                            (nuevo)
  WindLeaves.swift         hojas en Canvas + AnyTransition.leafAway                  (nuevo)
  WindSwirl.swift          remolino de Rendimiento                                   (nuevo)
  GustSweep.swift          ráfaga de «Borrar todo»                                   (nuevo)
  MotionGallery.swift      galería solo DEBUG (AIRY_MOTION_GALLERY=1)                (nuevo)
Sources/Airy/Shell/
  LaunchSwirl.swift        arranque: las hojas forman el logo                        (nuevo)
  RootView.swift           portero de movimiento, fondo, tinte, jerarquía de texto, arranque
  Sidebar.swift            AiryLogo, fondo elevado
  ScanProgressView.swift   brisa de análisis + hojas en órbita
  DebugSnapshot.swift      AIRY_HIDE_AT, AIRY_UNHIDE_AT, AIRY_REDUCE_MOTION, AIRY_SKIP_LAUNCH
Sources/Airy/Map/          TreemapCanvas.swift (paleta de teselas), MapScene.swift + MapView.swift (bloque en hojas)
Sources/Airy/Cleanup/      CleanupFlow.swift (gust, batchFreed), CleanupView.swift (leafAway, ráfaga, contador),
                           FreedCelebration.swift, ConfirmSheet.swift (colores)
Sources/Airy/Shell/FullDiskAccessBanner.swift (colores)
```

---

### Task 1: Paleta y contraste en el núcleo

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
  - `public enum AiryPalette` con: `logoTop`, `logoBottom`, `leafSky`, `heat`, `destructiveTop`, `destructiveBottom`, `safe`, `yourCall`, `doNotTouch`, `others` (`UInt32`); `tokens(_:) -> AiryTokens`; `riskFill(_: Risk) -> UInt32`; `riskInk(_: Risk, _: AiryAppearance) -> UInt32`; `kind(_: ContentKind) -> UInt32`; `tileStops(_ base: UInt32) -> [UInt32]`; `tileInk(_ base: UInt32) -> UInt32`; `swirlTint(heat: Double) -> UInt32`; `contrastChecks(_: AiryAppearance) -> [ContrastCheck]`; `static let badgeTintOpacity = 0.14`.

Valores (los de la spec, literales; los demás, derivados y comprobados por las pruebas de abajo):

| Token | Oscuro | Claro |
|---|---|---|
| background | `0x07112a` | `0xf3f7ff` |
| backgroundRaised | `0x0d2350` | `0xffffff` |
| text | `0xf2f7ff` | `0x07112a` |
| textSecondary | `0xb9cdf0` | `0x34486e` |
| accent | `0x2f8bff` | `0x1a63d6` |
| sky | `0x5ab8ff` | `0x0a6fb0` |
| accentFill (fondo de botón) | `0x1d5fd6` | `0x1d5fd6` |
| onAccent | `0xffffff` | `0xffffff` |
| safeInk / yourCallInk / doNotTouchInk | `0x1fdc7a` / `0xffb020` / `0xff8590` | `0x0a7a3f` / `0x8a5300` / `0xc0182f` |

Constantes: `logoTop 0x2fd0ff`, `logoBottom 0x2a3bd9`, `leafSky 0xbfe9ff`, `heat 0xff8a3d`, `destructiveTop 0xd12a40`, `destructiveBottom 0xb81f33`, `safe 0x1fdc7a`, `yourCall 0xffb020`, `doNotTouch 0xff4d5e`, `others 0x5a6380`.

Tipos del mapa (`kind(_:)`): video `0xa77bff`, images `0xe58cf5`, apps `0x4b4ee8`, code `0x2f8bff`, caches `0x18c7a6`, aiModels `0x5fe0ff`, containers `0x0f6a8c`, documents `0xc2d3ff`, system `0x605a80`, other `0x8d96a6`.

Reglas: `mix` interpola cada canal sRGB (0–255) y redondea; `tileStops(b) = [mix(b, 0xffffff, 0.10), b, mix(b, 0x000000, 0.10)]`; `tileInk(b)` = `0xffffff` o `0x07112a`, el de mayor contraste con `b`; `swirlTint(heat:)` = `mix(0x2f8bff, heat, h)` con `h` acotado a 0…1 y `NaN` ⇒ 0; `contrastChecks(a)` devuelve exactamente 18 pares, todos con `minimum = 4.5`: text, textSecondary, accent y sky sobre background y sobre backgroundRaised (8); onAccent sobre accentFill y sobre `logoBottom` (2); onAccent sobre `destructiveTop` y `destructiveBottom` (2); cada `riskInk` sobre `mix(background, riskFill, 0.14)` y sobre `mix(backgroundRaised, riskFill, 0.14)` (6). Los nombres son legibles en español («texto/fondo», «No borrar/elevado»…) para que el mensaje de la prueba diga qué par falla.

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AiryPaletteTests`
Expected: FAIL to compile («cannot find 'ColorMath' in scope»).

- [ ] **Step 3: Implement `ColorMath` and `AiryPalette`**

Luminancia WCAG 2.x (canal/255, `≤ 0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4`, pesos 0,2126/0,7152/0,0722); contraste `(L1+0.05)/(L2+0.05)` con el mayor arriba; ΔE76 = distancia euclídea en CIELAB D65; tono HSV en grados 0…360. Comentario de cabecera: los valores salen de la spec §2.1 y los derivados (modo claro, tintas de riesgo, botón) se eligieron para pasar `AiryPaletteTests`; quien cambie un color corre las pruebas.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AiryPaletteTests`
Expected: PASS (los 8 tests; `everyTextPairMeetsAA` en sus dos argumentos).

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskMapCore/Design/ColorMath.swift Sources/DiskMapCore/Design/AiryPalette.swift Tests/DiskMapCoreTests/AiryPaletteTests.swift
git commit -m "feat: paleta Airy con contraste AA comprobado

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Geometría del logo e icono «remolino con hojas»

**Files:**
- Create: `Sources/DiskMapCore/Design/AiryLogoGeometry.swift`
- Modify: `scripts/make-icon.swift` (dibujo completo, tabla de tamaños), `Resources/Airy.icns`, `Resources/Airy-1024.png` (regenerados)
- Test: `Tests/DiskMapCoreTests/AiryLogoGeometryTests.swift`

**Interfaces:**
- Consumes: `AiryPalette.logoTop/logoBottom/leafSky` (Task 1).
- Produces:
  - `public enum AiryLogoGeometry` con `enum Variant { case full, small }`, `struct Arc: Sendable, Equatable { radius, lineWidth, startDegrees, sweepDegrees, opacity: Double }`, `struct Leaf: Sendable, Equatable { radius, angleDegrees, length, width: Double; tint: UInt32 }`.
  - `static let grid = 1024.0`, `static let squircleInset = 100.0`, `static let squircleRadius = 185.0`, `static let center = 512.0`, `static let unit = 412.0` (mitad del squircle: 1 unidad normalizada).
  - `static func arcs(_: Variant) -> [Arc]`, `static func leaves(_: Variant) -> [Leaf]`, `static func variant(forPixelSize: Double) -> Variant` (≤ 64 ⇒ `.small`).
  - `static func leafPath(length: Double, width: Double) -> CGPath` — centrada en el origen a lo largo de +x: `move(-L/2, 0)`, curva cuadrática a `(L/2, 0)` con control `(0, -W)`, vuelta a `(-L/2, 0)` con control `(0, 0.6·W)`.
  - `static func leafCenter(_: Leaf) -> CGPoint` y `leafRotationDegrees(_: Leaf) = angle + 90` (tangente, sentido horario con y hacia abajo); en coordenadas de la rejilla.
  - `static func launchTargets(count: Int) -> [CGPoint]` — en unidades normalizadas (centro 0, `(rejilla − 512)/412`, y hacia abajo): primero los centros de `leaves(.full)`, luego puntos repartidos por igual a lo largo de `arcs(.full)`.
  - `static var fingerprint: String` — `"airy-logo-v1|"` + cada arco y hoja con sus números (formato libre pero estable).

Geometría (rejilla 1024, ángulos en grados, 0 = +x, y hacia abajo):

| Variante | Arcos (radio, grosor, inicio, barrido, opacidad) | Hojas (radio, ángulo, largo, ancho, tinte) |
|---|---|---|
| `.full` | (300, 34, −20, 250, 0.90) · (220, 30, 70, 250, 0.70) · (140, 26, 160, 250, 0.50) | (300, 230, 132, 62, `0xFFFFFF`) · (220, 320, 112, 52, `0xBFE9FF`) · (140, 50, 92, 44, `0xFFFFFF`) |
| `.small` | (230, 86, −30, 270, 0.95) | (230, 240, 230, 110, `0xFFFFFF`) |

Cada hoja está en el extremo final de su arco (inicio + barrido), como si el viento la soltara.

Icono (`scripts/make-icon.swift`): se conserva el squircle continuo, la sombra, el brillo especular y el filo de luz del script actual; el fondo pasa a un degradado lineal `0x2fd0ff` (arriba-izquierda) → `0x2a3bd9` (abajo-derecha) y el treemap se sustituye por los arcos (trazo blanco con la opacidad de la tabla, extremos redondeados) y las hojas (relleno con su tinte, sombra suave `alpha 0.25`). La geometría se copia de la tabla de arriba con un comentario `// logo-geometry: <AiryLogoGeometry.fingerprint>` (el texto exacto de la huella). Tamaños: `px ≤ 64` (16, 16@2x, 32, 32@2x) se dibujan a su tamaño con `.small` y alineados a píxel; 128…512 con `sips` desde el maestro; 1024 = maestro. `AIRY_ICON_PREVIEW` sigue escribiendo `preview-16/32/64.png`.

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

Copia el texto exacto de `AiryLogoGeometry.fingerprint` (p. ej. con un `print` temporal en una prueba, que luego se quita). Cambia la cabecera del script (ya no hay treemap) y el umbral de la variante pequeña de `px <= 32` a `px <= 64`.

- [ ] **Step 6: Regenerate and inspect the icon**

Run:
```bash
swift scripts/make-icon.swift Resources/
T=$(mktemp -d) && AIRY_ICON_PREVIEW=1 swift scripts/make-icon.swift "$T" && ls "$T"
iconutil -c iconset Resources/Airy.icns -o "$T/check.iconset" && ls "$T/check.iconset" | wc -l
```
Expected: «Icono generado: …», `preview-16.png preview-32.png preview-64.png Airy-1024.png Airy.icns`, y `10`. Abre `Resources/Airy-1024.png` y las tres vistas previas con la herramienta de lectura de imágenes: en grande, squircle turquesa→índigo con tres arcos y tres hojas; a 16/32/64, un arco grueso y una hoja legibles, sin manchas.

- [ ] **Step 7: Run the whole geometry suite**

Run: `swift test --filter AiryLogoGeometryTests`
Expected: PASS (8).

- [ ] **Step 8: Commit**

```bash
git add Sources/DiskMapCore/Design/AiryLogoGeometry.swift Tests/DiskMapCoreTests/AiryLogoGeometryTests.swift scripts/make-icon.swift Resources/Airy.icns Resources/Airy-1024.png
git commit -m "feat: icono remolino con hojas y variante para tamaños pequeños

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `Theme.Airy`, la paleta en toda la app, `RiskBadge` y `AiryLogo`

**Files:**
- Modify: `Sources/Airy/Design/Theme.swift`, `Sources/Airy/Design/Components.swift`, `Sources/Airy/Map/TreemapCanvas.swift:41-66` (`TilePalette`), `Sources/Airy/Shell/RootView.swift` (`DetailBackground`, tinte y jerarquía de texto), `Sources/Airy/Shell/Sidebar.swift:56-95` (marca y `AppGlyph`), `Sources/Airy/Shell/ScanProgressView.swift` (`ScanRing`), `Sources/Airy/Cleanup/FreedCelebration.swift`, `Sources/Airy/Cleanup/CleanupView.swift:160-175` (`HeroCard`), `Sources/Airy/Cleanup/ConfirmSheet.swift:170-178`, `Sources/Airy/Shell/FullDiskAccessBanner.swift:14`
- Create: `Sources/Airy/Design/AiryLogo.swift`

**Interfaces:**
- Consumes: `AiryPalette`, `AiryTokens`, `AiryAppearance` (Task 1); `AiryLogoGeometry` (Task 2); `Risk.label` (plan 1).
- Produces:
  - `extension Theme { enum Airy }` con los miembros de la tabla de interfaces. Los `Color` dinámicos se hacen con `Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? oscuro : claro })` a partir de `AiryPalette.tokens(.dark/.light)`. `accentGradient = [accentFill, logoBottom]`, `destructiveGradient = [destructiveTop, destructiveBottom]`, `logoGradient = [logoTop, logoBottom]` (`topLeading → bottomTrailing`). `riskFill` = color fijo de seguridad; `riskInk` = dinámico con `AiryPalette.riskInk`; `swirlTint(_:) = Color(hex: AiryPalette.swirlTint(heat: WindMotion.heat(for:)))` (añádelo en la Task 4 junto a `WindMotion`; aquí solo `riskFill`/`riskInk` y los tokens).
  - `Theme.color(for: ContentKind)` → `Color(hex: AiryPalette.kind(kind))`; `Theme.color(for: Risk)` → `Theme.Airy.riskFill(risk)` (iconos, puntos, anillos); `Theme.brand` → `Theme.Airy.accentGradient`; `Theme.userFiles` → `Theme.Airy.logoGradient`; `Theme.userFilesColor` → `Theme.Airy.accent`; `Theme.systemColor` → `Color(hex: AiryPalette.kind(.system))`; `Theme.purgeableColor` → `Color(hex: 0x9fb3d9)`.
  - `struct RiskBadge: View { init(risk: Risk, compact: Bool = false, reason: String? = nil) }` — texto `risk.label`, símbolo `Theme.symbol(for:)`, primer plano `Theme.Airy.riskInk(risk)`, fondo `riskFill.opacity(AiryPalette.badgeTintOpacity)`, borde `riskFill.opacity(0.35)`, `.help(reason ?? risk.label)`, `accessibilityLabel` = `risk.label` + («. » + reason si hay). Las tres llamadas existentes (`CleanupRow`, `ConfirmSheet`, `HoverCard`) pasan a mostrar los textos nuevos sin más cambios: es intencionado (el plan 3 agrupa y explica).
  - `struct AiryLogo: View { init(size: CGFloat, animated: Bool = false) }` — squircle continuo (`RoundedRectangle(cornerRadius: size * 185/824, style: .continuous)`) con `logoGradient`, arcos y hojas de `AiryLogoGeometry` escalados a `size/824` desde el squircle; variante por `variant(forPixelSize: size * displayScale)` (`@Environment(\.displayScale)`). `animated` se ignora en esta tarea (lo enciende la Task 5). Sustituye a `AppGlyph` (se borra).

Reglas de aplicación:
- `TilePalette`: degradado = `tileStops(base)`, texto **y** texto secundario = `tileInk(base)` a opacidad 1 (el tamaño se distingue por el peso de la fuente, no por transparencia); «Otros» usa `AiryPalette.others`.
- `RootView`: `.tint(Theme.Airy.accent)` y `.foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)` en la raíz y otra vez en el `Group` de la hoja (así `.secondary`/`.tertiary` heredan tonos AA); `DetailBackground` pinta `Theme.Airy.background` con los dos halos radiales en `accent`/`logoBottom` (opacidad 0.10/0.08 oscuro, 0.06/0.04 claro). La Task 5 lo sustituye por `BreezeBackground`.
- `Sidebar`: `.scrollContentBackground(.hidden)` y fondo `Theme.Airy.backgroundRaised`; marca con `AiryLogo(size: 26)`.
- Texto con color de riesgo (no iconos): `Theme.Airy.riskInk(_:)` en lugar de `Theme.color(for: Risk)` — revisa con `grep -rn "foregroundStyle(Theme.color(for: \." Sources/Airy` y cambia los que tiñen un `Text`.
- `PrimaryButton`: `.destructive` usa `destructiveGradient`; `ConfirmSheet:174` igual; `FullDiskAccessBanner` usa `riskFill(.yourCall)`; `FreedCelebration` anillo `[riskFill(.safe), sky]` y partículas `[safe, sky, accent, leafSky, logoTop]`; `HeroCard` igual que el anillo; `ScanRing` usa `logoGradient`.

- [ ] **Step 1: Implement `Theme.Airy`, the mappings and `RiskBadge`**

- [ ] **Step 2: Implement `AiryLogo` and replace `AppGlyph`**

Run: `grep -rn "AppGlyph" Sources/Airy`
Expected: sin resultados.

- [ ] **Step 3: Apply the palette rules above to the listed files**

Run: `grep -rn "Color(hex: 0x" Sources/Airy | grep -v Design/Theme.swift`
Expected: sin resultados (todo color pasa por `Theme`/`AiryPalette`).

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!` y todas las pruebas en verde.

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
Expected: un PNG por combinación. Ábrelos: fondo noche `#07112a` (oscuro) / `#f3f7ff` (claro), barra lateral elevada, logo nuevo de 26 pt, teselas en gama fría con rótulos legibles, etiquetas «Sin problema / Tú decides / No borrar» en Limpieza, botones azules con texto blanco.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: paleta azul de alto contraste, RiskBadge y logo vectorial

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Movimiento determinista en el núcleo

**Files:**
- Create: `Sources/DiskMapCore/Design/WindMotion.swift`
- Modify: `Sources/Airy/Design/Theme.swift` (añadir `Theme.Airy.swirlTint(_:)`)
- Test: `Tests/DiskMapCoreTests/WindMotionTests.swift`

**Interfaces:**
- Consumes: `AiryLogoGeometry.launchTargets(count:)` (Task 2), `SpringCurve` (`Layout/MapGeometry.swift`).
- Produces (todo `public`, `Sendable`; coordenadas en puntos salvo donde se diga «normalizadas»):
  - `struct LeafPose: Equatable { x, y, rotation /* rad */, scale, opacity: Double }`
  - `enum MotionMode: Equatable { case running, paused, reduced }`
  - `enum AnimationGate { static func ambient(windowVisible: Bool, appActive: Bool, reduceMotion: Bool) -> MotionMode; static func transient(windowVisible: Bool, reduceMotion: Bool) -> MotionMode }` — ambiente: oculta o inactiva ⇒ `.paused`; si no, «Reducir movimiento» ⇒ `.reduced`; si no, `.running`. Transitorio (borrar, ráfaga, arranque): oculta ⇒ `.paused` (se salta al estado final); «Reducir movimiento» ⇒ `.reduced` (fundido); si no, `.running` (aunque la app esté inactiva: el usuario acaba de confirmar).
  - `enum BreezeIntensity { case ambient, scan }`, `struct BreezeStreak: Equatable { yFraction, lengthFraction, thickness, opacity, period /* s */, phase /* 0…1 */: Double }`
  - `enum WindMotion` con:
    - `static func noise(_ index: Int, _ salt: Int) -> Double` — en [0, 1), determinista (mezcla tipo splitmix64 como `ParticleBurst.random`, que puede pasar a usar esta).
    - Arranque: `static let launchLeafCount = 18`; `static func launchTimeline(_ mode: MotionMode) -> (gather: Double, hold: Double, fade: Double)` — `.running` (1.4, 0.25, 0.35), `.reduced` (0.25, 0.2, 0.25), `.paused` (0, 0, 0); `static func launchLeaf(index: Int, count: Int, progress: Double) -> LeafPose` en coordenadas normalizadas: sale de un radio 2,4…3,2, gira en espiral (≈ 1,1 vueltas extra) y llega con salida suave al objetivo `launchTargets(count:)[index]`; opacidad 0 → 1 en el primer 25 %; `progress ≥ 1` ⇒ exactamente el objetivo, opacidad 1, escala 1.
    - Órbita: `static let orbitAngularSpeed = 0.9` (rad/s); `static func orbitLeaf(index: Int, count: Int, time: Double, radius: Double) -> LeafPose` alrededor de (0, 0), radio con vaivén ±6 %, ángulo base repartido por igual.
    - Deshacerse en hojas: `static let dissolveDuration = 0.75`; `static func leafCount(for rect: CGRect) -> Int` = `clamp(Int(área/1800), 6, 24)` (0 si el área no es finita); `static func dissolveLeaf(index: Int, count: Int, progress: Double, in rect: CGRect) -> LeafPose` — nace dentro de `rect`, se va a la derecha (Δx 80…240 con salida suave) y sube un poco con aleteo, opacidad sube hasta el 15 % y baja a 0 en 1, escala 1 → 0,6.
    - Salir volando: `static func leafAwayTransform(progress: Double) -> (dx: Double, dy: Double, rotationDegrees: Double, scale: Double, opacity: Double)` = (220·p², −24·p, 6·p, 1 − 0,12·p, 1 − p), `p` acotado.
    - Ráfaga: `static let gustRowDelay = 0.04`, `gustRowDuration = 0.55`, `gustMaxDuration = 1.2`, `gustBandDuration = 0.9`; `static func gustDuration(rowCount: Int) -> Double` = 0 si no hay filas, si no `min((n−1)·0,04, 0,65) + 0,55`; `static func gustRowOffset(row: Int, rowCount: Int, elapsed: Double) -> Double` = `14·sin(π·q)` con `q` el progreso propio de la fila (retraso `min(row·0,04, 0,65)`), 0 antes y después.
    - Brisa: `static func breezeStreaks(_ intensity: BreezeIntensity) -> [BreezeStreak]` — `.ambient`: 3 trazos, opacidad ≤ 0,06, periodo 18…26 s; `.scan`: 6 trazos, opacidad 0,08…0,14, periodo 4…6 s; valores con `noise`.
    - Remolino: `static func swirlRevolutionsPerSecond(cpuLoad: Double) -> Double` = `0,06 + 0,84·clamp(load, 0, 1)` (`NaN` ⇒ 0,06); `static func heat(for state: ProcessInfo.ThermalState) -> Double` = nominal 0, fair 0,35, serious 0,7, critical 1 (desconocido ⇒ 0).
    - `struct SwirlPhase { var angle: Double; mutating func advance(to time: Double, revolutionsPerSecond: Double) -> Double }` — integra el ángulo (rad, módulo 2π) para que un cambio de velocidad no dé saltos; el primer `advance` solo fija la hora; `dt` se acota a 1/15 s (tras una pausa no salta).
    - Balanceo: `static let swayKeyframes: [(degrees: Double, time: Double)] = [(1.6, 0.12), (-1.1, 0.26), (0.5, 0.42), (0, 0.6)]`.

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
                    == WindMotion.launchLeaf(index: i, count: n, progress: 0.4))   // determinista
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
        let after = phase.advance(to: 120, revolutionsPerSecond: 0.9)   // dos minutos en pausa
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
Expected: PASS (17 en `WindMotionTests`) y todo el resto en verde.

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskMapCore/Design/WindMotion.swift Tests/DiskMapCoreTests/WindMotionTests.swift Sources/Airy/Design/Theme.swift
git commit -m "feat: poses deterministas de las animaciones de viento y portero de movimiento

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Portero de movimiento, brisa de fondo, hojas, logo animado y botones que se mecen

**Files:**
- Create: `Sources/Airy/Design/Motion.swift`, `Sources/Airy/Design/BreezeBackground.swift`, `Sources/Airy/Design/WindLeaves.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (inyección del portero; `DetailBackground` → `BreezeBackground(intensity: .ambient)`), `Sources/Airy/Design/AiryLogo.swift` (`animated`), `Sources/Airy/Design/Components.swift` (`PrimaryButtonBody` con `.hoverSway`), `Sources/Airy/Shell/Sidebar.swift` (`AiryLogo(size: 26, animated: true)`), `Sources/Airy/Shell/DebugSnapshot.swift`

**Interfaces:**
- Consumes: `AnimationGate`, `MotionMode`, `BreezeIntensity`, `WindMotion.*` (Task 4); `Theme.Airy` (Task 3); `FPSMeter` (`Map/TreemapCanvas.swift`, DEBUG).
- Produces:
  - `EnvironmentValues.airyAmbientMotion: MotionMode` (por defecto `.paused`) y `.airyTransientMotion: MotionMode` (por defecto `.reduced`), con `EnvironmentKey` a mano. Por defecto «parado»: una vista que no recibe el portero (p. ej. una hoja nueva que olvidó inyectarlo) no gasta CPU.
  - `struct WindowActivityReader: NSViewRepresentable { var onChange: (_ visible: Bool, _ active: Bool) -> Void }` — toma `view.window` en `viewDidMoveToWindow` y escucha `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturizeNotification`, `didDeminiaturizeNotification` (de esa ventana) y `NSApplication.didBecomeActiveNotification`, `didResignActiveNotification`, `didHideNotification`, `didUnhideNotification`; visible = `occlusionState.contains(.visible) && !isMiniaturized && !NSApp.isHidden`; activo = `NSApp.isActive`.
  - `RootView` guarda `windowVisible`/`appActive` en `@ViewState`, lee `accessibilityReduceMotion` (en DEBUG, `AIRY_REDUCE_MOTION=1` lo fuerza a `true`) e inyecta ambos modos en el contenido **y** en el `Group` de la hoja. En DEBUG con `AIRY_FPS=1`, cada cambio de modo ambiente escribe `[motion] ambiente: running|paused|reduced` con `FPSMeter.log`.
  - `struct BreezeBackground: View { init(intensity: BreezeIntensity = .ambient) }` — `Theme.Airy.background` + halos de Task 3 + los trazos de `WindMotion.breezeStreaks(intensity)`: cápsulas con degradado horizontal transparente → `Theme.Airy.sky.opacity(streak.opacity)` → transparente (sin `.blur`, sin `Canvas`), que cruzan de izquierda a derecha con `.linear(duration: period).repeatForever(autoreverses: false)` animado por el servidor de render (como `ScanRing`), arrancando en `phase`. Con `airyAmbientMotion != .running` se dibuja una vista **distinta** y estática (trazos quietos en su `phase`): así la animación infinita desaparece de verdad. `.allowsHitTesting(false)`, `.ignoresSafeArea()`.
  - `struct WindLeaves: View { enum Mode: Equatable { case orbit(radius: CGFloat); case launch(start: Date); case burst(start: Date, rect: CGRect) }; init(mode: Mode, count: Int = 7) }` — un solo `Canvas(rendersAsynchronously: true)` dentro de `TimelineView(.animation(minimumInterval: nil, paused: …))`; dibuja cada hoja con `Path(AiryLogoGeometry.leafPath(length: 11, width: 5))` (×1,6 en `.launch`) transformada por la pose, alternando blanco y `Theme.Airy.leafSky` (en modo claro, `Theme.Airy.accent` y `sky` para que se vean). `.orbit` usa `orbitLeaf` alrededor del centro de la vista y se pausa con `airyAmbientMotion != .running`; `.launch` y `.burst` usan `launchLeaf`/`dissolveLeaf` con el progreso `(fecha − start)/duración`, se pausan con `airyTransientMotion != .running` y no dibujan nada pasado su final (quien las muestra las retira, como `ParticleBurst`). En DEBUG llama a `FPSMeter.shared.tick()` por fotograma. Vista hoja: solo valores de entrada, nada observable.
  - `AiryLogo(animated: true)`: los arcos giran despacio (una vuelta cada 20 s) con `repeatForever` del servidor de render solo si `airyAmbientMotion == .running`; si no, vista estática.
  - `extension View { func hoverSway(_ hovering: Bool) -> some View }` — al pasar a `true`, `keyframeAnimator(initialValue: 0.0, trigger: contador)` con `WindMotion.swayKeyframes` sobre `.rotationEffect(.degrees(_), anchor: .bottom)`; con `airyTransientMotion != .running` no hace nada.
  - DEBUG en `DebugSnapshot.configure`: `AIRY_HIDE_AT=<s>` llama a `NSApp.hide(nil)` a esos segundos y `AIRY_UNHIDE_AT=<s>` a `NSApp.unhide(nil)` (solo la propia app).

- [ ] **Step 1: Implement `Motion.swift` (keys, reader, `hoverSway`) and wire `RootView`**

- [ ] **Step 2: Implement `BreezeBackground` and replace `DetailBackground`**

- [ ] **Step 3: Implement `WindLeaves`, animated `AiryLogo`, `hoverSway` on `PrimaryButtonBody`, DEBUG hide/unhide**

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, todo en verde.

- [ ] **Step 5: Verify zero CPU when hidden and low CPU when idle-visible**

Run:
```bash
D=$(mktemp -d); AIRY_SUPPORT_DIR=$D AIRY_FPS=1 AIRY_SKIP_LAUNCH=1 AIRY_HIDE_AT=60 AIRY_UNHIDE_AT=90 \
  .build/debug/Airy 2> "$D/log.txt" & PID=$!
sleep 50; ps -o %cpu= -p $PID     # análisis terminado, ventana activa y quieta
sleep 25; ps -o %cpu= -p $PID     # oculta desde el segundo 60
sleep 20; ps -o %cpu= -p $PID     # visible otra vez
kill $PID; grep "\[motion\]" "$D/log.txt"
```
Expected: visible y quieta ≤ 3 %; oculta ≤ 0,3 % (cero en la práctica); al volver, de nuevo ≤ 3 %; el registro muestra `ambiente: running`, `ambiente: paused` y otra vez `ambiente: running`. Si el análisis aún no terminó a los 50 s, alarga la primera espera (el análisis no cuenta como reposo). `AIRY_SKIP_LAUNCH` aún no existe hasta la Task 6: hasta entonces se ignora.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: brisa de fondo, hojas y balanceo con pausa total fuera de la vista

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Arranque (las hojas forman el logo) y análisis (brisa y hojas en órbita)

**Files:**
- Create: `Sources/Airy/Shell/LaunchSwirl.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (capa de arranque), `Sources/Airy/Shell/ScanProgressView.swift` (`hero`), `Sources/Airy/Shell/DebugSnapshot.swift` (`AIRY_SKIP_LAUNCH`)

**Interfaces:**
- Consumes: `WindLeaves(.launch)`, `WindLeaves(.orbit)`, `BreezeBackground(.scan)`, `AiryLogo` (Task 5); `WindMotion.launchTimeline(_:)`, `launchLeafCount` (Task 4).
- Produces:
  - `struct LaunchSwirl: View { var onDone: () -> Void }` — capa opaca `Theme.Airy.background` a pantalla completa; en el centro, `WindLeaves(mode: .launch(start:), count: WindMotion.launchLeafCount)` en un cuadro de 240 pt (unidad normalizada = 120 pt) y `AiryLogo(size: 120)` que aparece con fundido en el último 35 % de `gather`; después `hold` y la capa entera se funde en `fade`; un clic la cierra al momento. Con el modo transitorio `.reduced`: solo el logo con fundido de entrada/salida (tiempos de `launchTimeline(.reduced)`); con `.paused`: `onDone()` inmediato. Termina con `DispatchQueue.main.asyncAfter` (no `Task.sleep`, ver el porqué en `MapScene.scheduleStop`).
  - `RootView`: muestra `LaunchSwirl` una sola vez por proceso (`static var hasPlayed`), por encima de todo; el análisis arranca a la vez (`.task { model.startScan() }` no espera). En DEBUG se salta si `AIRY_SKIP_LAUNCH=1` o si hay alguna variable `AIRY_*_SCRIPT` (los guiones de depuración existentes no deben cambiar sus tiempos).
  - `ScanProgressView.hero`: `BreezeBackground(intensity: .scan)` detrás del contenido del héroe (solo mientras se muestra el héroe) y `WindLeaves(mode: .orbit(radius: 98), count: 7)` en un cuadro de 240 pt centrado en el `ScanRing` de 168 pt. La píldora `.compact` no cambia.

- [ ] **Step 1: Implement `LaunchSwirl` and the `RootView` layer with the DEBUG skip**

- [ ] **Step 2: Add breeze and orbiting leaves to `ScanProgressView.hero`**

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, todo en verde.

- [ ] **Step 4: Capture the launch and the scan, normal and reduced**

Run:
```bash
for R in 0 1; do T=$(mktemp -d); D=$(mktemp -d)
  AIRY_SUPPORT_DIR=$D AIRY_SNAPSHOT_DIR=$T AIRY_SNAPSHOT_PREFIX=rm$R AIRY_SNAPSHOT_TIMES=0.4,1.0,1.6,2.4,4 \
    AIRY_REDUCE_MOTION=$R AIRY_APPEARANCE=dark AIRY_FPS=1 .build/debug/Airy 2> $D/log & PID=$!
  sleep 7; kill $PID; ls $T; grep "\[fps\]" $D/log | tail -3
done
```
Expected (`rm0`): a 0,4 s hojas en espiral; a 1,0 s casi formando el remolino; a 1,6 s logo completo; a 2,4 s la app con el análisis (brisa y hojas alrededor del anillo); con `AIRY_FPS=1`, las líneas `[fps]` de las animaciones ≥ 60 fps. (`rm1`): a 0,4 s solo el logo fundiéndose, a 1,0 s ya la app, nada girando ni hojas en órbita. Abre los PNG para comprobarlo.

- [ ] **Step 5: Commit**

```bash
git add Sources/Airy
git commit -m "feat: arranque con hojas que forman el logo y brisa durante el análisis

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Borrar se lleva el viento: filas y bloques en hojas, contador que sube y ráfaga de tanda

**Files:**
- Create: `Sources/Airy/Design/GustSweep.swift`
- Modify: `Sources/Airy/Design/WindLeaves.swift` (`AnyTransition.leafAway`), `Sources/Airy/Cleanup/CleanupFlow.swift` (`gust`, `batchFreed`), `Sources/Airy/Cleanup/CleanupView.swift` (`GroupSection` y capa de ráfaga y contador), `Sources/Airy/Map/MapScene.swift` (ráfagas de hojas), `Sources/Airy/Map/TreemapCanvas.swift` (`MapRenderer.draw`), `Sources/Airy/Map/MapView.swift` (`TrashCandidate`, `requestTrash`)

**Interfaces:**
- Consumes: `WindMotion.leafAwayTransform`, `dissolveLeaf`, `leafCount(for:)`, `dissolveDuration`, `gustRowOffset`, `gustDuration`, `gustBandDuration` (Task 4); `WindLeaves`, `airyTransientMotion` (Task 5).
- Produces:
  - `extension AnyTransition { static var leafAway: AnyTransition }` = `.asymmetric(insertion: .opacity, removal: .modifier(active: LeafAwayEffect(progress: 1), identity: LeafAwayEffect(progress: 0)))`. `LeafAwayEffect: ViewModifier, Animatable` (`animatableData = progress`): aplica `leafAwayTransform(progress:)` al contenido (`offset`, `rotationEffect`, `scaleEffect`, `opacity`) y superpone un `Canvas` **sin reloj** (lo redibuja la propia interpolación de `progress`) con `leafCount(for:)` hojas de `dissolveLeaf` en el tamaño del contenido (`GeometryReader` en el `overlay`). Lee `airyTransientMotion`: distinto de `.running` ⇒ solo `opacity(1 − progress)`. Sirve igual para «borrar una fila» y para «la fila de una app cerrada sale volando» (plan 4).
  - `CleanupFlow.Gust: Equatable { let id: UUID; let start: Date; let order: [String] }` y `private(set) var gust: Gust?` — se fija en `confirm(_:model:)` para `.items` con ≥ 2 elementos (`order` = ids en el orden de ejecución) y se borra a los `WindMotion.gustDuration(rowCount:) + 0.1` s con `DispatchQueue.main.asyncAfter`. El «Borrar todo» del plan 3 llama a `requestClean` y obtiene la ráfaga sin más.
  - `CleanupFlow.batchFreed: Int64` (`private(set)`) — 0 al empezar cada tanda `.items`; suma los bytes de cada `.freed`/`.movedToTrash`.
  - `struct GustSweep: View { let start: Date }` — banda vertical ancha (≈ 40 % del ancho) con degradado transparente → `Theme.Airy.sky.opacity(0.18)` → transparente y unas pocas hojas, que cruza de izquierda a derecha en `gustBandDuration`; `TimelineView(.animation(paused: airyTransientMotion != .running))`; no dibuja nada pasado su final.
  - `extension View { func gustSway(index: Int?, start: Date?) -> some View }` — si ambos existen y el modo transitorio es `.running`, `offset(x: gustRowOffset(row: index, rowCount:, elapsed:))` dentro de un `TimelineView` que solo existe hasta `gustDuration`; si no, nada.
  - `MapScene.burst(rect: CGRect)` — añade `MapLeafBurst(rect:, start: CACurrentMediaTime())` a `private(set) var bursts: [MapLeafBurst]` y llama a `keepAnimating(fadeEnd: start + WindMotion.dissolveDuration)`; `finishAnimating` quita las terminadas. `MapFrame` gana `bursts`; `MapRenderer.draw` pinta, después de las teselas, las hojas de cada ráfaga viva con `dissolveLeaf` (color: la tinta clara de la tesela, `leafSky`).
  - `TrashCandidate` gana `rect: CGRect?` (rectángulo en el lienzo de la tesela cuyo menú se abrió: `scene.layout?.tile(id: details.id)?.rect`); en `requestTrash`, con `.movedToTrash` o `.freed` y `airyTransientMotion == .running`, se llama a `scene.burst(rect:)` antes de mostrar el aviso.

Cableado en Limpieza: en `GroupSection`, la transición de salida de cada fila pasa de `.opacity.combined(with: .scale(...))` a `.leafAway` y cada fila recibe `.gustSway(index: order.firstIndex(of: item.id), start: flow.gust?.start)`; `CleanupView` superpone `GustSweep(start:)` sobre la lista mientras `flow.gust` existe (`.allowsHitTesting(false)`) y, abajo, mientras `flow.isRunning && flow.batchFreed > 0`, una píldora `leaf.fill` + `BytesCounter(bytes: flow.batchFreed, countsUpOnAppear: false)` + «liberados» que sube con cada fila (`BytesCounter` ya rueda las cifras). El muelle que colapsa la fila (`hiddenIDs` con `Theme.zoomSpring`) no cambia.

- [ ] **Step 1: Implement `.leafAway` and switch the cleanup rows to it**

- [ ] **Step 2: Add `gust`/`batchFreed` to `CleanupFlow`, implement `GustSweep`/`gustSway` and the freed pill in `CleanupView`**

- [ ] **Step 3: Implement the map leaf burst (`MapScene.burst`, renderer, `TrashCandidate.rect`)**

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, todo en verde.

- [ ] **Step 5: Watch it with the DEBUG gallery's fake rows (no real cleanup)**

La verificación visual de esta tarea se hace en la Task 8 (galería con filas falsas que se borran sin tocar el disco). Aquí basta con comprobar que no quedan relojes vivos tras una ráfaga:

Run: `grep -n "repeatForever\|TimelineView" Sources/Airy/Design/*.swift Sources/Airy/Shell/LaunchSwirl.swift`
Expected: cada aparición está detrás de un `paused:` o dentro de una vista que solo existe mientras dura su efecto o mientras el modo es `.running` (revísalas una a una).

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: filas y bloques que se lleva el viento, contador liberado y ráfaga de tanda

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `WindSwirl` para Rendimiento y galería de movimiento (DEBUG)

**Files:**
- Create: `Sources/Airy/Design/WindSwirl.swift`, `Sources/Airy/Design/MotionGallery.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (galería en DEBUG), `Sources/Airy/Shell/DebugSnapshot.swift` (documentar las variables nuevas en su comentario)

**Interfaces:**
- Consumes: `SwirlPhase`, `WindMotion.swirlRevolutionsPerSecond`, `WindMotion.heat(for:)` (Task 4); `Theme.Airy.swirlTint(_:)`; `.leafAway`, `GustSweep`, `gustSway`, `WindLeaves`, `RiskBadge`, `AiryLogo` (Tasks 3–7).
- Produces:
  - `struct WindSwirl: View { init(speed: Double, tint: Color) }` — `speed` en vueltas por segundo; tres arcos concéntricos (`AiryLogoGeometry.arcs(.full)`, trazo `tint` con la opacidad de cada arco) y las tres hojas, girando con el ángulo de un `SwirlPhase` guardado en una clase no observable en `@ViewState` (se avanza dentro del `Canvas` con la fecha del `TimelineView`). `TimelineView(.animation(minimumInterval: nil, paused: airyAmbientMotion != .running))`; con `.reduced`, estático y el tinte cambia con fundido de 0,3 s. Un cambio de `speed` nunca da saltos (lo garantiza `SwirlPhase`). Uso previsto por el plan 4: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: carga), tint: Theme.Airy.swirlTint(ProcessInfo.processInfo.thermalState))`.
  - `MotionGallery` (solo `#if DEBUG`, con `AIRY_MOTION_GALLERY=1` sustituye al contenido de la sección): cuatro `WindSwirl` (carga 0 / 0,5 / 1 con estado nominal, y carga 1 con `.serious`), cinco `RiskBadge` (los tres riesgos, uno compacto, uno con `reason`), `AiryLogo` a 16, 26, 64 y 128 pt, y una lista de 6 filas falsas (solo texto en memoria) con un botón «Simular borrado» que activa `GustSweep`/`gustSway` y luego las quita de una en una cada 0,25 s con `.leafAway`, mientras una píldora con `BytesCounter` sube. No llama a `CleanupFlow`, `AppModel` ni a nada que toque el disco. Con `AIRY_GALLERY_AUTOPLAY=<s>` el botón se pulsa solo a esos segundos (para capturas).

- [ ] **Step 1: Implement `WindSwirl`**

- [ ] **Step 2: Implement `MotionGallery` and its DEBUG switch**

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: `Build complete!`, todo en verde.

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
Expected (`g0`): a 2,5 s cuatro remolinos (el último anaranjado), etiquetas «Sin problema / Tú decides / No borrar» legibles, logos con la variante pequeña a 16/26 pt; a 3,3 s la banda de ráfaga cruzando y las filas desplazadas; a 3,9 s filas saliendo en hojas y la píldora contando; a 5,5 s lista vacía. `[fps]` ≥ 60. (`g1`): nada se desplaza, las filas desaparecen con fundido, remolinos quietos.

- [ ] **Step 5: Final checks for the whole plan**

Run: `swift test && swift build -c release && git status --short`
Expected: todas las pruebas en verde (incluidas `AiryPaletteTests`, `AiryLogoGeometryTests`, `WindMotionTests`), `Build complete!` en release y ningún archivo sin seguimiento inesperado. Repite el paso 5 de la Task 5 (CPU oculta ≤ 0,3 %) ahora con todas las animaciones montadas.

- [ ] **Step 6: Commit**

```bash
git add Sources/Airy
git commit -m "feat: remolino de Rendimiento y galería de movimiento para depurar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
