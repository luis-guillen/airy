import SwiftUI
import QuartzCore
import Synchronization
import DiskMapCore

/// El mapa de bloques: un único `Canvas` (rasterizado con Metal por `drawingGroup`) que dibuja
/// todas las teselas. Mientras hay animación, un `TimelineView(.animation)` pide un fotograma
/// por refresco de pantalla; en reposo queda en pausa y no gasta nada.
struct TreemapCanvas: View {
    let scene: MapScene

    var body: some View {
        // Se lee aquí (en `body`) para que Observation sepa qué redibujar; el lienzo recibe valores.
        let frame = MapFrame(layout: scene.layout, transition: scene.transition,
                             hover: scene.hover, dim: scene.dim)
        TimelineView(.animation(minimumInterval: nil, paused: !scene.isAnimating)) { timeline in
            // El lienzo depende de la fecha del fotograma: si no, SwiftUI no lo vuelve a pintar.
            let tick = timeline.date
            Canvas { context, size in
                _ = tick
                FPSMeter.shared.tick()
                MapRenderer.draw(&context, size: size, frame: frame, now: CACurrentMediaTime())
            }
            .drawingGroup()
        }
    }
}

/// Todo lo que el lienzo necesita para pintar un fotograma.
struct MapFrame {
    let layout: MapLayout?
    let transition: MapTransition?
    let hover: Fade<Int>
    let dim: Fade<ContentKind>
}

// MARK: - Paleta de las teselas

private struct TilePalette {
    let gradient: Gradient
    let text: Color
    let secondaryText: Color

    init(base: Color, darkText: Bool) {
        gradient = Gradient(colors: [base.mix(with: .white, by: 0.24), base, base.mix(with: .black, by: 0.10)])
        text = darkText ? Color.black.opacity(0.82) : .white
        secondaryText = darkText ? Color.black.opacity(0.58) : Color.white.opacity(0.78)
    }

    static let kinds: [TilePalette] = ContentKind.allCases.map { kind in
        // Amarillo, celeste y verde son claros: texto oscuro para que se lea.
        let darkText = kind == .documents || kind == .aiModels || kind == .caches
        return TilePalette(base: Theme.color(for: kind), darkText: darkText)
    }

    static let others = TilePalette(base: Color(hex: 0x86868B), darkText: false)

    static func of(_ style: TileStyle) -> TilePalette {
        switch style {
        case .kind(let kind): kinds[ContentKind.allCases.firstIndex(of: kind) ?? 0]
        case .others: others
        }
    }
}

// MARK: - Dibujo

enum MapRenderer {
    private static var spring: SpringCurve { Theme.springCurve }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    static func draw(_ context: inout GraphicsContext, size: CGSize, frame: MapFrame, now: Double) {
        let canvas = CGRect(origin: .zero, size: size)
        if let transition = frame.transition, now < transition.end {
            drawTransition(transition, context: context, canvas: canvas, frame: frame, now: now)
        } else if let layout = frame.layout {
            let fit = fitter(layout, canvas)
            for tile in layout.tiles {
                drawTile(tile, in: fit(tile.rect), context: context, opacity: 1, labelOpacity: 1,
                         frame: frame, now: now)
            }
        }
    }

    /// Si el lienzo cambió de tamaño y el layout nuevo aún no ha llegado, se estira el anterior.
    private static func fitter(_ layout: MapLayout, _ canvas: CGRect) -> (CGRect) -> CGRect {
        guard layout.bounds.size != canvas.size, layout.bounds.width > 0 else { return { $0 } }
        return { RectMath.map($0, from: layout.bounds, to: canvas) }
    }

    private static func drawTransition(_ t: MapTransition, context: GraphicsContext, canvas: CGRect,
                                       frame: MapFrame, now: Double) {
        let s = spring.value(at: now - t.start)
        switch t.kind {
        case .entrance:
            if let to = t.to { drawEntrance(to, window: canvas, t: t, context: context, frame: frame, now: now) }

        case .zoomIn:
            // La tesela pulsada crece hasta ocupar el lienzo; las demás se escalan con ella y se apagan.
            let window = RectMath.lerp(t.focusRect, canvas, s)
            var origins: [Int: CGRect] = [:]
            if let from = t.from {
                let fade = 1 - clamp(s * 1.35)
                if fade > 0.004 {
                    for tile in from.tiles where tile.id != t.focusID {
                        let r = RectMath.map(tile.rect, from: t.focusRect, to: window)
                        guard r.intersects(canvas) else { continue }
                        drawTile(tile, in: r, context: context, opacity: fade, labelOpacity: fade,
                                 frame: frame, now: now)
                    }
                }
                if let focus = from.tile(id: t.focusID ?? .min) {
                    // Su vista previa son los hijos: cada uno crecerá desde ahí hasta su sitio.
                    for inner in focus.inner {
                        origins[inner.id] = RectMath.map(inner.rect, from: focus.rect, to: window)
                    }
                    let backdrop = t.to == nil ? 1 : 1 - clamp(spring.value(at: now - t.toStart - 0.12))
                    if backdrop > 0.004 {
                        drawTile(focus, in: window, context: context, opacity: backdrop,
                                 labelOpacity: 1 - clamp(s * 2.6), frame: frame, now: now, hoverable: false,
                                 previewOpacity: t.to == nil ? 1 : 0)
                    }
                }
            }
            if let to = t.to {
                drawEntrance(to, window: window, t: t, context: context, frame: frame, now: now, origins: origins)
            }

        case .zoomOut:
            // Lo inverso: el nivel actual se encoge hasta su tesela (cada hijo vuelve a su sitio
            // en la vista previa) y el padre vuelve a su escala.
            let window = RectMath.lerp(canvas, t.focusRect, s)
            let settle = clamp((s - 0.86) / 0.14)   // relevo final: hijos → vista previa
            var targets: [Int: CGRect] = [:]
            if let to = t.to {
                let appear = clamp(s * 1.3)
                for tile in to.tiles where tile.id != t.focusID {
                    let r = RectMath.map(tile.rect, from: t.focusRect, to: window)
                    guard r.intersects(canvas), appear > 0.004 else { continue }
                    drawTile(tile, in: r, context: context, opacity: appear, labelOpacity: appear,
                             frame: frame, now: now)
                }
                if let focus = to.tile(id: t.focusID ?? .min) {
                    for inner in focus.inner {
                        targets[inner.id] = RectMath.map(inner.rect, from: focus.rect, to: window)
                    }
                    drawTile(focus, in: window, context: context, opacity: 1,
                             labelOpacity: clamp((s - 0.35) * 2.5), frame: frame, now: now,
                             previewOpacity: targets.isEmpty ? clamp((s - 0.2) * 1.6) : settle)
                }
            }
            if let from = t.from {
                let fade = 1 - clamp(s * 1.8)
                for tile in from.tiles {
                    let base = RectMath.map(tile.rect, from: canvas, to: window)
                    if let target = targets[tile.id] {
                        drawTile(tile, in: RectMath.lerp(base, target, s), context: context,
                                 opacity: 1 - settle, labelOpacity: fade, frame: frame, now: now, hoverable: false)
                    } else if fade > 0.004 {
                        drawTile(tile, in: base, context: context, opacity: fade, labelOpacity: fade,
                                 frame: frame, now: now, hoverable: false)
                    }
                }
            }

        case .morph:
            guard let to = t.to else { return }
            var old: [String: CGRect] = [:]
            if let from = t.from {
                let fit = fitter(from, canvas)
                for tile in from.tiles { old[tile.matchKey] = fit(tile.rect) }
                let kept = Set(to.tiles.map(\.matchKey))
                let fade = 1 - clamp(s * 1.5)
                for tile in from.tiles where !kept.contains(tile.matchKey) && fade > 0.004 {
                    drawTile(tile, in: fit(tile.rect), context: context, opacity: fade, labelOpacity: fade,
                             frame: frame, now: now, hoverable: false)
                }
            }
            for tile in to.tiles {
                if let before = old[tile.matchKey] {
                    drawTile(tile, in: RectMath.lerp(before, tile.rect, s), context: context, opacity: 1,
                             labelOpacity: 1, frame: frame, now: now)
                } else {
                    let e = clamp(s)
                    drawTile(tile, in: RectMath.scaled(tile.rect, by: 0.85 + 0.15 * s), context: context,
                             opacity: e, labelOpacity: e, frame: frame, now: now)
                }
            }
        }
    }

    /// Cada tesela de `layout` aparece con escala 0,85→1 y opacidad 0→1, del centro hacia fuera,
    /// colocada dentro de `window` (el lienzo, o la tesela que está creciendo en un zoom).
    /// Las que ya se veían en la vista previa (`origins`) no aparecen: crecen desde allí.
    private static func drawEntrance(_ layout: MapLayout, window: CGRect, t: MapTransition,
                                     context: GraphicsContext, frame: MapFrame, now: Double,
                                     origins: [Int: CGRect] = [:]) {
        let canvas = layout.bounds
        let riding = window != canvas
        for tile in layout.tiles {
            let e = spring.value(at: now - t.toStart - layout.entranceDelay(tile))
            let base = riding ? RectMath.map(tile.rect, from: canvas, to: window) : tile.rect
            if let origin = origins[tile.id] {
                drawTile(tile, in: RectMath.lerp(origin, base, e), context: context, opacity: 1,
                         labelOpacity: clamp(e * 1.2), frame: frame, now: now)
                continue
            }
            guard e > 0.002 else { continue }
            let opacity = clamp(e)
            drawTile(tile, in: RectMath.scaled(base, by: 0.85 + 0.15 * e), context: context,
                     opacity: opacity, labelOpacity: opacity, frame: frame, now: now)
        }
    }

    // MARK: Una tesela

    private static func drawTile(_ tile: MapTile, in rect: CGRect, context: GraphicsContext,
                                 opacity: Double, labelOpacity: Double,
                                 frame: MapFrame, now: Double, hoverable: Bool = true,
                                 previewOpacity: Double = 1) {
        guard rect.width >= 0.5, rect.height >= 0.5, opacity > 0.002 else { return }
        let palette = TilePalette.of(tile.style)

        // Leyenda: los tipos que no se resaltan se atenúan.
        let kindOfTile: ContentKind? = if case .kind(let k) = tile.style { k } else { nil }
        let dimFactor = dimming(kindOfTile, frame: frame, now: now)
        let glow = hoverable ? frame.hover.weight(of: tile.id, at: now) : 0

        var c = context
        c.opacity = opacity * dimFactor

        let shortSide = min(rect.width, rect.height)
        let radius = min(shortSide < 60 ? 4 : 8, shortSide / 2)

        // Diminutas: un relleno plano basta (y ahorra miles de degradados).
        if shortSide < 3 {
            c.fill(Path(rect), with: .color(Theme.color(for: kindOfTile ?? .system).opacity(tile.isOthers ? 0.6 : 1)))
            return
        }

        let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        if glow > 0.01 {
            c.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.45 * glow), radius: 14 * glow, x: 0, y: 4 * glow))
                layer.fill(path, with: .color(.black))
            }
        }

        c.fill(path, with: .linearGradient(palette.gradient,
                                           startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

        if tile.isOthers { drawStripes(in: rect, clip: path, context: c) }

        if !tile.inner.isEmpty, previewOpacity > 0.004 {
            var p = context
            p.opacity = opacity * previewOpacity
            drawPreview(tile, in: rect, context: p, frame: frame, now: now)
        }

        if glow > 0.01 {
            // +8 % de brillo al pasar el ratón.
            c.fill(path, with: .color(.white.opacity(0.08 * glow)))
        }

        if shortSide >= 6 {
            let border = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                              cornerRadius: max(radius - 0.5, 0), style: .continuous)
            c.stroke(border, with: .color(.white.opacity(0.12 + 0.30 * glow)), lineWidth: 1)
        }

        if rect.width >= 70, rect.height >= 36, labelOpacity > 0.01 {
            drawLabel(tile, in: rect, palette: palette, context: c, opacity: labelOpacity)
        }
    }

    /// Atenuación por la leyenda: 1 si el tipo está resaltado (o no hay ninguno), 0,18 si no.
    private static func dimming(_ kind: ContentKind?, frame: MapFrame, now: Double) -> Double {
        let lit = min(frame.dim.weight(of: nil, at: now) + (kind.map { frame.dim.weight(of: $0, at: now) } ?? 0), 1)
        return 0.18 + 0.82 * lit
    }

    /// Vista previa anidada: los hijos de la carpeta, más pequeños, dentro de su tesela.
    private static func drawPreview(_ tile: MapTile, in rect: CGRect, context: GraphicsContext,
                                    frame: MapFrame, now: Double) {
        let same = rect == tile.rect
        for inner in tile.inner {
            let r = same ? inner.rect : RectMath.map(inner.rect, from: tile.rect, to: rect)
            guard r.width >= 0.5, r.height >= 0.5 else { continue }
            let kind: ContentKind? = if case .kind(let k) = inner.style { k } else { nil }
            var c = context
            c.opacity *= dimming(kind, frame: frame, now: now)
            let short = min(r.width, r.height)
            if short < 3 {
                c.fill(Path(r), with: .color(Theme.color(for: kind ?? .system).opacity(0.85)))
                continue
            }
            let palette = TilePalette.of(inner.style)
            let path = Path(roundedRect: r, cornerRadius: min(short < 40 ? 3 : 5, short / 2), style: .continuous)
            c.fill(path, with: .linearGradient(palette.gradient, startPoint: CGPoint(x: r.minX, y: r.minY),
                                               endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            if inner.style == .others { drawStripes(in: r, clip: path, context: c) }
            if short >= 8 {
                c.stroke(path, with: .color(.black.opacity(0.16)), lineWidth: 0.75)
            }
            if r.width >= 84, r.height >= 28 {
                var l = c
                l.clip(to: Path(r.insetBy(dx: 2, dy: 2)))
                l.draw(Text(inner.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.secondaryText),
                       in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: 14))
            }
        }
    }

    private static func drawStripes(in rect: CGRect, clip: Path, context: GraphicsContext) {
        var c = context
        c.clip(to: clip)
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 10
        }
        c.stroke(stripes, with: .color(.white.opacity(0.16)), lineWidth: 3.5)
    }

    private static func drawLabel(_ tile: MapTile, in rect: CGRect, palette: TilePalette,
                                  context: GraphicsContext, opacity: Double) {
        var c = context
        c.opacity *= opacity
        c.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
        let large = rect.width >= 180 && rect.height >= 104
        let pad: CGFloat = large ? 12 : 8
        let width = rect.width - pad * 2
        if large {
            let name = Text(tile.name).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.text)
            c.draw(name, in: CGRect(x: rect.minX + pad, y: rect.minY + pad - 1, width: width, height: 18))
            let size = Text(tile.sizeText).font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryText)
            c.draw(size, in: CGRect(x: rect.minX + pad, y: rect.minY + pad + 18, width: width, height: 28))
        } else {
            let name = Text(tile.name).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.text)
            c.draw(name, in: CGRect(x: rect.minX + pad, y: rect.minY + pad - 2, width: width, height: 15))
            let size = Text(tile.sizeText).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            c.draw(size, in: CGRect(x: rect.minX + pad, y: rect.minY + pad + 12, width: width, height: 14))
        }
    }
}

// MARK: - Contador de FPS (solo Debug con DISKMAP_FPS=1)

/// Cuenta los fotogramas que dibuja el lienzo durante cada animación y los escribe en stderr.
/// Fuera de Debug, o sin `DISKMAP_FPS=1`, cada llamada sale en la primera línea.
final class FPSMeter: Sendable {
    static let shared = FPSMeter()

    static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["DISKMAP_FPS"] == "1"
        #else
        false
        #endif
    }()

    private struct State {
        var label: String?
        var frames = 0
        var start: Double = 0
        var last: Double = 0
        var recent: [Double] = []
        var longestGap: Double = 0
    }

    private let state = Mutex(State())

    func begin(_ label: String) {
        guard Self.isEnabled else { return }
        end()
        Self.log("[anim] empieza \(label)")
        state.withLock { s in
            s.label = label; s.frames = 0; s.start = CACurrentMediaTime(); s.last = s.start; s.longestGap = 0
        }
    }

    func tick() {
        guard Self.isEnabled else { return }
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.recent.append(now)
            s.recent.removeAll { now - $0 > 1 }
            guard s.label != nil else { return }
            s.frames += 1
            s.longestGap = max(s.longestGap, now - s.last)
            s.last = now
        }
    }

    func end() {
        guard Self.isEnabled else { return }
        let line: String? = state.withLock { s in
            guard let label = s.label else { return nil }
            defer { s.label = nil }
            let duration = s.last - s.start
            guard duration > 0 else { return nil }
            return String(format: "[fps] %@: %d fotogramas en %.3f s = %.1f fps (hueco máx. %.1f ms)",
                          label, s.frames, duration, Double(s.frames) / duration, s.longestGap * 1000)
        }
        if let line { Self.log(line) }
    }

    /// Fotogramas dibujados en el último segundo.
    var currentFPS: Int {
        let now = CACurrentMediaTime()
        return state.withLock { s in s.recent.filter { now - $0 <= 1 }.count }
    }

    static func log(_ line: String) {
        #if DEBUG
        let elapsed = Date().timeIntervalSince(DebugSnapshot.start)
        #else
        let elapsed = 0.0
        #endif
        FileHandle.standardError.write(Data((String(format: "%6.2f ", elapsed) + line + "\n").utf8))
    }

}
