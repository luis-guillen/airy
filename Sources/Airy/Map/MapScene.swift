import SwiftUI
import QuartzCore
import DiskMapCore

// MARK: - Layout ya calculado

/// Aspecto de una tesela: el color de su tipo o el rayado gris de "Otros".
enum TileStyle: Hashable, Sendable {
    case kind(ContentKind)
    case others
}

/// Una tesela lista para dibujar: geometría, textos ya formateados y su puesto en la entrada.
struct MapTile: Sendable, Identifiable {
    let id: Int
    let rect: CGRect
    /// `nil` en la tesela de grupo "Otros (N elementos)".
    let node: FileNode?
    let style: TileStyle
    let name: String
    let sizeText: String
    let bytes: Int64
    let othersCount: Int
    let isZoomable: Bool
    /// 0 = la primera en aparecer (la más cercana al centro).
    let rank: Int
    /// Clave para emparejar teselas entre dos árboles distintos (reanálisis): el nombre.
    let matchKey: String
    /// Vista previa de su contenido (un nivel), en coordenadas del lienzo. Vacía si no cabe.
    var inner: [InnerTile] = []

    var isOthers: Bool { style == .others }
}

/// Tesela de la vista previa anidada: solo se dibuja (no se señala ni se pulsa por separado).
struct InnerTile: Sendable {
    /// El mismo id que tendrá la tesela al entrar en la carpeta: así el zoom la hace crecer.
    let id: Int
    let rect: CGRect
    let style: TileStyle
    let name: String
}

/// Teselas de un nodo para un tamaño de lienzo, con su índice de búsqueda por posición.
struct MapLayout: Sendable {
    let nodeID: Int
    let bounds: CGRect
    let tiles: [MapTile]
    let hitIndex: TileHitIndex
    /// Milisegundos que tardó el cálculo (para el registro de rendimiento).
    let milliseconds: Double

    func tile(id: Int) -> MapTile? { tiles.first { $0.id == id } }

    func tile(at point: CGPoint) -> MapTile? {
        hitIndex.hit(point).map { tiles[$0] }
    }

    var maxEntranceDelay: Double {
        min(Double(max(tiles.count - 1, 0)) * Theme.staggerStep, Theme.staggerMaxDelay)
    }

    func entranceDelay(_ tile: MapTile) -> Double {
        min(Double(tile.rank) * Theme.staggerStep, Theme.staggerMaxDelay)
    }
}

/// Lo que se necesita del árbol para calcular un layout, copiado en el hilo principal
/// (dueño del árbol) para que el cálculo en segundo plano no lea `FileNode` mientras cambia.
struct LayoutInput: Sendable {
    struct Meta: Sendable {
        let name: String
        let kind: ContentKind
        let isDirectory: Bool
        let aggregatedCount: Int
    }

    /// Hijos de una carpeta hija, para su vista previa.
    struct Inner: Sendable {
        let snapshot: Treemap.Snapshot
        let metas: [Int: Meta]
    }

    /// Solo las carpetas más grandes pueden tener tesela con sitio para la vista previa.
    static let previewedFolders = 60

    let snapshot: Treemap.Snapshot
    let metas: [Int: Meta]
    let inner: [Int: Inner]

    @MainActor init(node: FileNode) {
        snapshot = Treemap.Snapshot(of: node)
        metas = Self.metas(of: node)
        var inner: [Int: Inner] = [:]
        let folders = node.children
            .filter { $0.isDirectory && $0.aggregatedCount == 0 && $0.allocatedSize > 0 && !$0.children.isEmpty }
            .sorted { $0.allocatedSize > $1.allocatedSize }
            .prefix(Self.previewedFolders)
        for folder in folders {
            inner[folder.id] = Inner(snapshot: Treemap.Snapshot(of: folder), metas: Self.metas(of: folder))
        }
        self.inner = inner
    }

    @MainActor private static func metas(of node: FileNode) -> [Int: Meta] {
        var metas: [Int: Meta] = [:]
        metas.reserveCapacity(node.children.count)
        for child in node.children where child.allocatedSize > 0 {
            metas[child.id] = Meta(name: child.name,
                                   kind: child.isDirectory ? child.dominantKind : child.kind,
                                   isDirectory: child.isDirectory,
                                   aggregatedCount: child.aggregatedCount)
        }
        return metas
    }

    /// Hueco para la vista previa dentro de una tesela: bajo la etiqueta, con un margen fino.
    static func previewRect(in rect: CGRect) -> CGRect? {
        guard rect.width >= 48, rect.height >= 44 else { return nil }
        let labeled = rect.width >= 70 && rect.height >= 36
        let large = rect.width >= 180 && rect.height >= 104
        let header: CGFloat = labeled ? (large ? 58 : 36) : 5
        let r = CGRect(x: rect.minX + 5, y: rect.minY + header,
                       width: rect.width - 10, height: rect.height - header - 5)
        return r.width >= 24 && r.height >= 18 ? r : nil
    }

    /// La vista previa se calcula con la forma del lienzo (la misma disposición que tendrá la
    /// carpeta al abrirla) y se encoge al hueco: así el zoom es casi una escala pura y ningún
    /// bloque se cruza con otro por el camino.
    private static func innerTiles(_ input: Inner, in area: CGRect, canvas: CGRect) -> [InnerTile] {
        let sx = area.width / canvas.width, sy = area.height / canvas.height
        // Solo lo que mida al menos ~30 pt² ya encogido; el resto va al grupo "Otros".
        let minArea = 30 / max(sx * sy, 0.0001)
        return Treemap.tiles(for: input.snapshot, in: canvas, gap: 0, minTileArea: minArea).compactMap { tile in
            let r = RectMath.map(tile.rect, from: canvas, to: area).insetBy(dx: 0.75, dy: 0.75)
            guard r.width >= 0.5, r.height >= 0.5 else { return nil }
            let meta = input.metas[tile.id]
            let isOthers = tile.node == nil || (meta?.aggregatedCount ?? 0) > 0
            return InnerTile(id: tile.id, rect: r, style: isOthers ? .others : .kind(meta?.kind ?? .other),
                             name: isOthers ? "Otros" : (meta?.name ?? ""))
        }
    }

    /// Cálculo puro (se ejecuta fuera del hilo principal).
    func layout(in bounds: CGRect) -> MapLayout {
        let start = CACurrentMediaTime()
        let raw = Treemap.tiles(for: snapshot, in: bounds, gap: 2, minTileArea: 36)
        let ranks = EntranceOrder.ranks(for: raw.map(\.rect), in: bounds)
        var tiles: [MapTile] = []
        tiles.reserveCapacity(raw.count)
        for (index, tile) in raw.enumerated() {
            let bytes = tile.size
            let meta = metas[tile.id]
            let aggregated = meta?.aggregatedCount ?? 0
            let isOthers = tile.node == nil || aggregated > 0
            let count = tile.node == nil ? tile.othersCount : aggregated
            var preview: [InnerTile] = []
            if let inner = inner[tile.id], let area = Self.previewRect(in: tile.rect) {
                preview = Self.innerTiles(inner, in: area, canvas: bounds)
            }
            tiles.append(MapTile(
                id: tile.id,
                rect: tile.rect,
                node: tile.node,
                style: isOthers ? .others : .kind(meta?.kind ?? .other),
                name: isOthers ? "Otros (\(Theme.count(count)) elementos)" : (meta?.name ?? ""),
                sizeText: Format.bytes(bytes),
                bytes: bytes,
                othersCount: count,
                isZoomable: !isOthers && (meta?.isDirectory ?? false),
                rank: ranks[index],
                matchKey: isOthers ? "\u{0}otros" : (meta?.name ?? "\(tile.id)"),
                inner: preview))
        }
        return MapLayout(nodeID: snapshot.parentID, bounds: bounds, tiles: tiles,
                         hitIndex: TileHitIndex(rects: tiles.map(\.rect), bounds: bounds),
                         milliseconds: (CACurrentMediaTime() - start) * 1000)
    }
}

// MARK: - Transiciones

/// Una animación en curso del lienzo. Los tiempos son `CACurrentMediaTime()`.
struct MapTransition: Sendable {
    enum Kind: String, Sendable { case entrance, zoomIn, zoomOut, morph }

    let kind: Kind
    let start: Double
    /// Nivel que se va (zoom y morph). En la entrada, `nil`.
    let from: MapLayout?
    /// Nivel que llega. En el zoom hacia dentro puede tardar unos milisegundos en calcularse.
    var to: MapLayout?
    /// Cuándo arranca la entrada escalonada de `to`.
    var toStart: Double
    /// Tesela que hace de "ventana" del zoom: en `from` al entrar, en `to` al salir.
    let focusID: Int?
    var focusRect: CGRect

    var end: Double {
        let settle = Theme.springCurve.settlingDuration
        switch kind {
        case .entrance:
            return toStart + (to?.maxEntranceDelay ?? 0) + settle
        case .zoomIn:
            // Hasta tener los hijos no se sabe cuánto dura la cascada.
            guard let to else { return start + settle + Theme.staggerMaxDelay + settle }
            return max(start + settle, toStart + to.maxEntranceDelay + settle)
        case .zoomOut, .morph:
            return start + settle
        }
    }
}

/// Una tesela que se deshace en hojas tras mandarla a la Papelera. `rect` en coordenadas del
/// lienzo; `start` en `CACurrentMediaTime()`. Dura `WindMotion.dissolveDuration`.
struct MapLeafBurst: Sendable, Equatable {
    let rect: CGRect
    let start: Double

    func isAlive(at time: Double) -> Bool { time < start + WindMotion.dissolveDuration }
}

// MARK: - Escena

/// Estado del mapa animado: el layout del nivel visible, la transición en curso, la tesela
/// iluminada y el tipo resaltado desde la leyenda. Solo pide fotogramas mientras algo se mueve.
@MainActor @Observable
final class MapScene {
    private(set) var layout: MapLayout?
    private(set) var transition: MapTransition?
    /// `true` solo mientras hay algo que animar: con `false` el `TimelineView` queda en pausa.
    private(set) var isAnimating = false
    private(set) var hover = Fade<Int>()
    /// Sube cada vez que termina un zoom: la vista vuelve a mirar qué hay bajo el puntero.
    private(set) var settledCount = 0
    private(set) var dim = Fade<ContentKind>()
    /// Teselas que se están deshaciendo en hojas; `finishAnimating` quita las terminadas.
    private(set) var bursts: [MapLeafBurst] = []

    @ObservationIgnored private(set) var canvasSize: CGSize = .zero
    /// Marco del lienzo en la ventana (coordenadas de SwiftUI); solo lo usa el guion de depuración.
    @ObservationIgnored var canvasFrameInWindow: CGRect = .zero
    @ObservationIgnored private var displayed: FileNode?
    @ObservationIgnored private var displayedPath = ""
    @ObservationIgnored private var pending: FileNode?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cache = LayoutCache()
    /// Fin de la transición en curso (se puede acortar al llegar el layout) y de los fundidos.
    @ObservationIgnored private var transitionUntil: Double = 0
    @ObservationIgnored private var fadesUntil: Double = 0
    private var animatingUntil: Double { max(transitionUntil, fadesUntil) }
    @ObservationIgnored private var stopToken = 0
    /// Hay un cambio de nivel esperando su layout: mientras, no se señala ninguna tesela
    /// (el layout visible aún es el del nivel anterior).
    @ObservationIgnored private var awaitingLayout = false

    var isZooming: Bool {
        guard let transition, transition.kind == .zoomIn || transition.kind == .zoomOut else { return false }
        return CACurrentMediaTime() < transition.end
    }

    // MARK: Entrada desde la vista

    /// Muestra `node`: decide la animación según su relación con el nivel anterior
    /// (hijo → zoom hacia dentro, antepasado → hacia fuera, mismo sitio → morph, otro → entrada).
    func show(_ node: FileNode?, revision newRevision: Int) {
        guard let node else {
            displayed = nil; layout = nil; transition = nil
            return
        }
        guard canvasSize.width >= 1, canvasSize.height >= 1 else {
            pending = node
            revision = newRevision
            return
        }
        let previous = displayed
        let previousLayout = currentlyVisibleLayout()
        let revisionChanged = newRevision != revision
        revision = newRevision
        if previous === node && !revisionChanged { return }

        displayed = node
        let path = node.path
        defer { displayedPath = path }
        // Árbol nuevo (reanálisis) o cambiado (Papelera): fuera los layouts viejos, que
        // retendrían nodos del árbol anterior o lo ya borrado.
        if let previous, Self.root(of: previous) !== Self.root(of: node) {
            cache.removeAll()
        } else if revisionChanged {
            cache.removeAll(exceptRevision: newRevision)
        }

        let kind: MapTransition.Kind
        var focusID: Int?
        if let previous, previous !== node, previousLayout != nil {
            if let child = Self.directChild(of: previous, toward: node) {
                kind = .zoomIn; focusID = child.id
            } else if let child = Self.directChild(of: node, toward: previous) {
                kind = .zoomOut; focusID = child.id
            } else {
                kind = path == displayedPath ? .morph : .entrance
            }
        } else if previous === node || (previous != nil && path == displayedPath) {
            kind = .morph
        } else {
            kind = .entrance
        }

        // Una animación anterior a medias se da por terminada: se parte de su estado final.
        transition = nil
        generation += 1
        let gen = generation
        awaitingLayout = true

        if kind == .zoomIn, let from = previousLayout, let focusID, let focus = from.tile(id: focusID) {
            let now = CACurrentMediaTime()
            transition = MapTransition(kind: .zoomIn, start: now, from: from, to: nil,
                                       toStart: now, focusID: focusID, focusRect: focus.rect)
            #if DEBUG
            FPSMeter.shared.begin("zoom hacia dentro")
            #endif
            keepAnimating(transitionEnd: transition!.end)
            requestLayout(for: node, generation: gen) { [weak self] layout in
                guard let self else { return }
                self.awaitingLayout = false
                guard var running = self.transition, running.kind == .zoomIn else {
                    self.layout = layout
                    return
                }
                running.to = layout
                // Los hijos entran cuando la tesela ya ha crecido un poco.
                running.toStart = max(CACurrentMediaTime(), running.start + 0.12)
                self.transition = running
                self.layout = layout
                self.keepAnimating(transitionEnd: running.end)
            }
            return
        }

        requestLayout(for: node, generation: gen) { [weak self] layout in
            guard let self else { return }
            self.awaitingLayout = false
            let now = CACurrentMediaTime()
            var effective = kind
            var focusRect = CGRect.zero
            if kind == .zoomOut {
                if let focusID, let focus = layout.tile(id: focusID) {
                    focusRect = focus.rect
                } else {
                    effective = .entrance
                }
            }
            if kind == .zoomIn { effective = .entrance }   // sin tesela de origen visible
            if effective == .morph, previousLayout == nil { effective = .entrance }
            let transition = MapTransition(
                kind: effective, start: now,
                from: effective == .entrance ? nil : previousLayout,
                to: layout, toStart: now,
                focusID: effective == .zoomOut ? focusID : nil, focusRect: focusRect)
            self.layout = layout
            self.transition = transition
            #if DEBUG
            FPSMeter.shared.begin(effective.label)
            #endif
            self.keepAnimating(transitionEnd: transition.end)
        }
    }

    /// Cambio de tamaño del lienzo: se recalcula sin animación (mientras llega, se escala el anterior).
    func resize(to size: CGSize) {
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != canvasSize, rounded.width >= 1, rounded.height >= 1 else { return }
        let first = canvasSize == .zero
        canvasSize = rounded
        if first || displayed == nil {
            let node = pending ?? displayed
            pending = nil
            displayed = nil
            show(node, revision: revision)
            return
        }
        guard let node = displayed else { return }
        generation += 1
        let gen = generation
        requestLayout(for: node, generation: gen) { [weak self] layout in
            guard let self else { return }
            // Este layout es del nivel mostrado: ya no se espera nada (el cambio de nivel que
            // lo pedía pudo quedar anulado al subir `generation`).
            if layout.nodeID == self.displayed?.id { self.awaitingLayout = false }
            // Un zoom hacia dentro que aún esperaba a sus hijos los recibe aquí y sigue.
            if var running = self.transition, running.kind == .zoomIn, running.to == nil,
               layout.nodeID == self.displayed?.id {
                running.to = layout
                running.toStart = max(CACurrentMediaTime(), running.start + 0.12)
                self.transition = running
                self.layout = layout
                self.keepAnimating(transitionEnd: running.end)
                return
            }
            // Una animación en curso sigue, ya con el layout del tamaño nuevo.
            if var running = self.transition, CACurrentMediaTime() < running.end,
               running.to?.nodeID == layout.nodeID {
                running.to = layout
                if running.kind == .zoomOut, let id = running.focusID, let focus = layout.tile(id: id) {
                    running.focusRect = focus.rect
                }
                self.transition = running
            } else {
                self.transition = nil
            }
            self.layout = layout
        }
    }

    // MARK: Ratón y leyenda

    func setHover(_ id: Int?) {
        guard id != hover.current else { return }
        hover = hover.moving(to: id, at: CACurrentMediaTime())
        keepAnimating(fadeEnd: hover.start + Fade<Int>.duration)
    }

    func setDim(_ kind: ContentKind?) {
        guard kind != dim.current else { return }
        dim = dim.moving(to: kind, at: CACurrentMediaTime())
        keepAnimating(fadeEnd: dim.start + Fade<ContentKind>.duration)
    }

    /// La tesela de `rect` (coordenadas del lienzo) se deshace en hojas. Solo pinta: quien llama ya
    /// sabe que se borró y que hay movimiento transitorio.
    func burst(rect: CGRect) {
        let start = CACurrentMediaTime()
        bursts.append(MapLeafBurst(rect: rect, start: start))
        keepAnimating(fadeEnd: start + WindMotion.dissolveDuration)
    }

    /// Tesela bajo el punto en el layout asentado (durante un zoom, ninguna).
    func tile(at point: CGPoint) -> MapTile? {
        guard !isZooming, !awaitingLayout, let layout else { return nil }
        let p = scaledToLayout(point, layout)
        return layout.tile(at: p)
    }

    /// Precalcula el layout de una carpeta (al pasar el ratón por encima) para que el zoom no espere.
    func prefetch(_ node: FileNode) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        guard bounds.width >= 1, cache.get(LayoutCache.Key(node.id, bounds.size, revision)) == nil else { return }
        let input = LayoutInput(node: node)
        let key = LayoutCache.Key(node.id, bounds.size, revision)
        let root = Self.root(of: node)
        Self.compute(input, in: bounds, qos: .utility) { [weak self] layout in
            // Si mientras tanto cambió el árbol o su revisión, el resultado ya no vale.
            guard let self, self.isCurrent(root: root, revision: key.revision) else { return }
            self.cache.put(key, layout)
        }
    }

    // MARK: Internos

    private func scaledToLayout(_ point: CGPoint, _ layout: MapLayout) -> CGPoint {
        guard layout.bounds.size != canvasSize, canvasSize.width > 0, canvasSize.height > 0 else { return point }
        return CGPoint(x: point.x * layout.bounds.width / canvasSize.width,
                       y: point.y * layout.bounds.height / canvasSize.height)
    }

    /// Lo que se ve ahora mismo como nivel "de llegada" (para encadenar animaciones).
    private func currentlyVisibleLayout() -> MapLayout? {
        if let transition, let to = transition.to { return to }
        if let transition, transition.kind == .zoomIn { return transition.from }
        return layout
    }

    private func requestLayout(for node: FileNode, generation gen: Int,
                               then apply: @escaping @MainActor (MapLayout) -> Void) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let key = LayoutCache.Key(node.id, bounds.size, revision)
        if let cached = cache.get(key) {
            apply(cached)
            return
        }
        let input = LayoutInput(node: node)
        let root = Self.root(of: node)
        #if DEBUG
        let path = FPSMeter.isEnabled ? node.path : ""
        #endif
        Self.compute(input, in: bounds, qos: .userInteractive) { [weak self] layout in
            guard let self else { return }
            if self.isCurrent(root: root, revision: key.revision) { self.cache.put(key, layout) }
            #if DEBUG
            if FPSMeter.isEnabled {
                FPSMeter.log(String(format: "[layout] %@ · %d teselas · %.2f ms (%.0f×%.0f)",
                                    path, layout.tiles.count, layout.milliseconds,
                                    bounds.width, bounds.height))
            }
            #endif
            // Cálculos viejos (otro zoom o tamaño posterior) se guardan en caché pero no se aplican.
            guard gen == self.generation else { return }
            apply(layout)
        }
    }

    /// El layout pedido para `root`/`revision` sigue siendo del árbol que se muestra.
    private func isCurrent(root: FileNode, revision requested: Int) -> Bool {
        guard requested == revision, let displayed else { return false }
        return Self.root(of: displayed) === root
    }

    /// Cola propia para los layouts, con la vuelta por `DispatchQueue.main` en vez de `Task`/`await`:
    /// durante un análisis el *pool* cooperativo va saturado de E/S, y mientras el lienzo anima a
    /// 120 fps los trabajos del actor principal llegaban con 200–330 ms de retraso (medido). Así el
    /// cálculo (≈ 1 ms) sale del hilo principal y vuelve en el siguiente ciclo.
    private nonisolated static let layoutQueue = DispatchQueue(label: "local.airy.layout",
                                                               qos: .userInteractive, attributes: .concurrent)

    private nonisolated static func compute(_ input: LayoutInput, in bounds: CGRect, qos: DispatchQoS,
                                            then deliver: @escaping @MainActor (MapLayout) -> Void) {
        // `.enforceQoS`: la prioridad pedida manda aunque la cola tenga otra (la precarga es `.utility`).
        layoutQueue.async(qos: qos, flags: .enforceQoS) {
            let layout = input.layout(in: bounds)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(layout) }
            }
        }
    }

    private func keepAnimating(transitionEnd: Double? = nil, fadeEnd: Double? = nil) {
        if let transitionEnd { transitionUntil = transitionEnd }
        if let fadeEnd { fadesUntil = max(fadesUntil, fadeEnd) }
        if !isAnimating { isAnimating = true }
        scheduleStop()
    }

    /// Para el reloj de fotogramas al acabar. `asyncAfter` y no `Task.sleep`: con el lienzo a
    /// 120 fps las tareas del actor principal despertaban hasta medio segundo tarde (medido).
    private func scheduleStop() {
        // Cada aviso nuevo invalida los anteriores (el fin pudo adelantarse o retrasarse).
        stopToken &+= 1
        let token = stopToken
        let remaining = max(animatingUntil - CACurrentMediaTime(), 0) + 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.stopToken else { return }
                if CACurrentMediaTime() < self.animatingUntil {
                    self.scheduleStop()
                } else {
                    self.finishAnimating()
                }
            }
        }
    }

    private func finishAnimating() {
        if let transition, transition.kind == .zoomIn || transition.kind == .zoomOut,
           CACurrentMediaTime() >= transition.end {
            settledCount += 1
        }
        if let transition, CACurrentMediaTime() >= transition.end { self.transition = nil }
        let now = CACurrentMediaTime()
        if bursts.contains(where: { !$0.isAlive(at: now) }) { bursts.removeAll { !$0.isAlive(at: now) } }
        isAnimating = false
        #if DEBUG
        FPSMeter.shared.end()
        #endif
    }

    static func root(of node: FileNode) -> FileNode {
        var cursor = node
        while let parent = cursor.parent { cursor = parent }
        return cursor
    }

    static func directChild(of ancestor: FileNode, toward node: FileNode) -> FileNode? {
        var cursor: FileNode? = node
        while let step = cursor {
            if step.parent === ancestor { return step }
            cursor = step.parent
        }
        return nil
    }
}

extension MapTransition.Kind {
    var label: String {
        switch self {
        case .entrance: "entrada"
        case .zoomIn: "zoom hacia dentro"
        case .zoomOut: "zoom hacia fuera"
        case .morph: "morph"
        }
    }
}

/// Fundido corto entre dos valores (tesela iluminada, tipo resaltado).
struct Fade<Value: Hashable & Sendable>: Sendable {
    static var duration: Double { 0.18 }
    var previous: Value?
    var current: Value?
    var start: Double = 0

    func moving(to value: Value?, at time: Double) -> Fade {
        Fade(previous: current, current: value, start: time)
    }

    /// 0…1 con salida suave.
    func progress(at time: Double) -> Double {
        let t = min(max((time - start) / Self.duration, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    /// Cuánto le corresponde a `value` ahora mismo (1 = del todo).
    func weight(of value: Value?, at time: Double) -> Double {
        let p = progress(at: time)
        return (current == value ? p : 0) + (previous == value ? 1 - p : 0)
    }
}

/// Caché pequeña de layouts por (nodo, tamaño en puntos enteros, revisión del árbol).
struct LayoutCache {
    struct Key: Hashable {
        let node: Int, width: Int, height: Int, revision: Int
        init(_ node: Int, _ size: CGSize, _ revision: Int) {
            self.node = node
            width = Int(size.width.rounded())
            height = Int(size.height.rounded())
            self.revision = revision
        }
    }

    private var storage: [Key: MapLayout] = [:]
    private var order: [Key] = []
    private let capacity = 48

    func get(_ key: Key) -> MapLayout? { storage[key] }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    /// Quita lo calculado para otras revisiones del árbol (retendrían subárboles ya borrados).
    mutating func removeAll(exceptRevision revision: Int) {
        order.removeAll { $0.revision != revision }
        storage = storage.filter { $0.key.revision == revision }
    }

    mutating func put(_ key: Key, _ layout: MapLayout) {
        if storage[key] == nil { order.append(key) }
        storage[key] = layout
        while order.count > capacity { storage[order.removeFirst()] = nil }
    }
}
