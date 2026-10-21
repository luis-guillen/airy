import SwiftUI
import QuartzCore
import DiskMapCore

// MARK: - Precomputed layout

/// A tile's look: its kind's color or the gray stripes of "Other".
enum TileStyle: Hashable, Sendable {
    case kind(ContentKind)
    case others
}

/// A tile ready to draw: geometry, preformatted texts and its place in the entrance.
struct MapTile: Sendable, Identifiable {
    let id: Int
    let rect: CGRect
    /// `nil` on the "Other (N items)" group tile.
    let node: FileNode?
    let style: TileStyle
    let name: String
    let sizeText: String
    let bytes: Int64
    let othersCount: Int
    let isZoomable: Bool
    /// 0 = the first to appear (the closest to the center).
    let rank: Int
    /// Key to match tiles between two different trees (rescan): the name.
    let matchKey: String
    /// Preview of its content (one level), in canvas coordinates. Empty if it doesn't fit.
    var inner: [InnerTile] = []

    var isOthers: Bool { style == .others }
}

/// Tile of the nested preview: only drawn (not hovered or clicked separately).
struct InnerTile: Sendable {
    /// The same id the tile will have when entering the folder: that way the zoom makes it grow.
    let id: Int
    let rect: CGRect
    let style: TileStyle
    let name: String
}

/// Tiles of a node for a canvas size, with their position lookup index.
struct MapLayout: Sendable {
    let nodeID: Int
    let bounds: CGRect
    let tiles: [MapTile]
    let hitIndex: TileHitIndex
    /// Milliseconds the computation took (for the performance log).
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

/// What is needed from the tree to compute a layout, copied on the main thread
/// (owner of the tree) so the background computation doesn't read `FileNode` while it changes.
struct LayoutInput: Sendable {
    struct Meta: Sendable {
        let name: String
        let kind: ContentKind
        let isDirectory: Bool
        let aggregatedCount: Int
    }

    /// Children of a child folder, for its preview.
    struct Inner: Sendable {
        let snapshot: Treemap.Snapshot
        let metas: [Int: Meta]
    }

    /// Only the largest folders can have a tile with room for the preview.
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

    /// Space for the preview inside a tile: below the label, with a thin margin.
    static func previewRect(in rect: CGRect) -> CGRect? {
        guard rect.width >= 48, rect.height >= 44 else { return nil }
        let labeled = rect.width >= 70 && rect.height >= 36
        let large = rect.width >= 180 && rect.height >= 104
        let header: CGFloat = labeled ? (large ? 58 : 36) : 5
        let r = CGRect(x: rect.minX + 5, y: rect.minY + header,
                       width: rect.width - 10, height: rect.height - header - 5)
        return r.width >= 24 && r.height >= 18 ? r : nil
    }

    /// The preview is computed with the canvas's shape (the same arrangement the folder will
    /// have when opened) and shrunk into the space: that way the zoom is almost a pure scale and no
    /// block crosses another along the way.
    private static func innerTiles(_ input: Inner, in area: CGRect, canvas: CGRect) -> [InnerTile] {
        let sx = area.width / canvas.width, sy = area.height / canvas.height
        // Only what measures at least ~30 pt² once shrunk; the rest goes into the "Other" group.
        let minArea = 30 / max(sx * sy, 0.0001)
        return Treemap.tiles(for: input.snapshot, in: canvas, gap: 0, minTileArea: minArea).compactMap { tile in
            let r = RectMath.map(tile.rect, from: canvas, to: area).insetBy(dx: 0.75, dy: 0.75)
            guard r.width >= 0.5, r.height >= 0.5 else { return nil }
            let meta = input.metas[tile.id]
            let isOthers = tile.node == nil || (meta?.aggregatedCount ?? 0) > 0
            return InnerTile(id: tile.id, rect: r, style: isOthers ? .others : .kind(meta?.kind ?? .other),
                             name: isOthers ? String(localized: "Other") : (meta?.name ?? ""))
        }
    }

    /// Pure computation (runs off the main thread).
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
                name: isOthers ? String(localized: "Other (\(Theme.count(count)) items)") : (meta?.name ?? ""),
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

// MARK: - Transitions

/// An animation in progress on the canvas. Times are `CACurrentMediaTime()`.
struct MapTransition: Sendable {
    enum Kind: String, Sendable { case entrance, zoomIn, zoomOut, morph }

    let kind: Kind
    let start: Double
    /// Outgoing level (zoom and morph). On entrance, `nil`.
    let from: MapLayout?
    /// Incoming level. On zoom-in it may take a few milliseconds to compute.
    var to: MapLayout?
    /// When the staggered entrance of `to` starts.
    var toStart: Double
    /// Tile acting as the zoom's "window": in `from` when zooming in, in `to` when zooming out.
    let focusID: Int?
    var focusRect: CGRect

    var end: Double {
        let settle = Theme.springCurve.settlingDuration
        switch kind {
        case .entrance:
            return toStart + (to?.maxEntranceDelay ?? 0) + settle
        case .zoomIn:
            // Until the children are there, how long the cascade lasts is unknown.
            guard let to else { return start + settle + Theme.staggerMaxDelay + settle }
            return max(start + settle, toStart + to.maxEntranceDelay + settle)
        case .zoomOut, .morph:
            return start + settle
        }
    }
}

/// A tile breaking up into leaves after being moved to the Trash. `rect` in canvas
/// coordinates; `start` in `CACurrentMediaTime()`. Lasts `WindMotion.dissolveDuration`.
struct MapLeafBurst: Sendable, Equatable {
    let rect: CGRect
    let start: Double

    func isAlive(at time: Double) -> Bool { time < start + WindMotion.dissolveDuration }
}

// MARK: - Scene

/// State of the animated map: the visible level's layout, the transition in progress, the
/// highlighted tile and the kind highlighted from the legend. It only requests frames while something moves.
@MainActor @Observable
final class MapScene {
    private(set) var layout: MapLayout?
    private(set) var transition: MapTransition?
    /// `true` only while there is something to animate: with `false` the `TimelineView` stays paused.
    private(set) var isAnimating = false
    private(set) var hover = Fade<Int>()
    /// Bumps every time a zoom ends: the view looks again at what is under the pointer.
    private(set) var settledCount = 0
    private(set) var dim = Fade<ContentKind>()
    /// Tiles breaking up into leaves; `finishAnimating` removes the finished ones.
    private(set) var bursts: [MapLeafBurst] = []

    @ObservationIgnored private(set) var canvasSize: CGSize = .zero
    /// The canvas frame in the window (SwiftUI coordinates); only the debug script uses it.
    @ObservationIgnored var canvasFrameInWindow: CGRect = .zero
    @ObservationIgnored private var displayed: FileNode?
    @ObservationIgnored private var displayedPath = ""
    @ObservationIgnored private var pending: FileNode?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cache = LayoutCache()
    /// End of the transition in progress (it can be shortened when the layout arrives) and of the fades.
    @ObservationIgnored private var transitionUntil: Double = 0
    @ObservationIgnored private var fadesUntil: Double = 0
    private var animatingUntil: Double { max(transitionUntil, fadesUntil) }
    @ObservationIgnored private var stopToken = 0
    /// A level change is waiting for its layout: meanwhile, no tile is highlighted
    /// (the visible layout is still the previous level's).
    @ObservationIgnored private var awaitingLayout = false

    var isZooming: Bool {
        guard let transition, transition.kind == .zoomIn || transition.kind == .zoomOut else { return false }
        return CACurrentMediaTime() < transition.end
    }

    // MARK: Input from the view

    /// Shows `node`: picks the animation by its relation to the previous level
    /// (child → zoom in, ancestor → zoom out, same place → morph, other → entrance).
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
        // New tree (rescan) or changed tree (Trash): drop the old layouts, which
        // would retain nodes of the previous tree or what was already deleted.
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

        // A previous animation halfway through is considered finished: start from its final state.
        transition = nil
        generation += 1
        let gen = generation
        awaitingLayout = true

        if kind == .zoomIn, let from = previousLayout, let focusID, let focus = from.tile(id: focusID) {
            let now = CACurrentMediaTime()
            transition = MapTransition(kind: .zoomIn, start: now, from: from, to: nil,
                                       toStart: now, focusID: focusID, focusRect: focus.rect)
            #if DEBUG
            FPSMeter.shared.begin("zoom in")
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
                // The children enter once the tile has grown a little.
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
            if kind == .zoomIn { effective = .entrance }   // no visible source tile
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

    /// Canvas size change: recomputed without animation (until it arrives, the previous one is scaled).
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
            // This layout belongs to the shown level: nothing is awaited anymore (the level change
            // that requested it may have been cancelled when `generation` went up).
            if layout.nodeID == self.displayed?.id { self.awaitingLayout = false }
            // A zoom-in still waiting for its children receives them here and continues.
            if var running = self.transition, running.kind == .zoomIn, running.to == nil,
               layout.nodeID == self.displayed?.id {
                running.to = layout
                running.toStart = max(CACurrentMediaTime(), running.start + 0.12)
                self.transition = running
                self.layout = layout
                self.keepAnimating(transitionEnd: running.end)
                return
            }
            // An animation in progress continues, now with the new size's layout.
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

    // MARK: Pointer and legend

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

    /// The tile at `rect` (canvas coordinates) breaks up into leaves. It only paints: the caller already
    /// knows it was deleted and that there is transient motion.
    func burst(rect: CGRect) {
        let start = CACurrentMediaTime()
        bursts.append(MapLeafBurst(rect: rect, start: start))
        keepAnimating(fadeEnd: start + WindMotion.dissolveDuration)
    }

    /// Tile under the point in the settled layout (during a zoom, none).
    func tile(at point: CGPoint) -> MapTile? {
        guard !isZooming, !awaitingLayout, let layout else { return nil }
        let p = scaledToLayout(point, layout)
        return layout.tile(at: p)
    }

    /// Precomputes a folder's layout (on hover) so the zoom doesn't wait.
    func prefetch(_ node: FileNode) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        guard bounds.width >= 1, cache.get(LayoutCache.Key(node.id, bounds.size, revision)) == nil else { return }
        let input = LayoutInput(node: node)
        let key = LayoutCache.Key(node.id, bounds.size, revision)
        let root = Self.root(of: node)
        Self.compute(input, in: bounds, qos: .utility) { [weak self] layout in
            // If the tree or its revision changed meanwhile, the result is no longer valid.
            guard let self, self.isCurrent(root: root, revision: key.revision) else { return }
            self.cache.put(key, layout)
        }
    }

    // MARK: Internals

    private func scaledToLayout(_ point: CGPoint, _ layout: MapLayout) -> CGPoint {
        guard layout.bounds.size != canvasSize, canvasSize.width > 0, canvasSize.height > 0 else { return point }
        return CGPoint(x: point.x * layout.bounds.width / canvasSize.width,
                       y: point.y * layout.bounds.height / canvasSize.height)
    }

    /// What is shown right now as the "incoming" level (to chain animations).
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
                FPSMeter.log(String(format: "[layout] %@ · %d tiles · %.2f ms (%.0f×%.0f)",
                                    path, layout.tiles.count, layout.milliseconds,
                                    bounds.width, bounds.height))
            }
            #endif
            // Old computations (a later zoom or size) are cached but not applied.
            guard gen == self.generation else { return }
            apply(layout)
        }
    }

    /// The layout requested for `root`/`revision` still belongs to the tree being shown.
    private func isCurrent(root: FileNode, revision requested: Int) -> Bool {
        guard requested == revision, let displayed else { return false }
        return Self.root(of: displayed) === root
    }

    /// Dedicated queue for layouts, returning via `DispatchQueue.main` instead of `Task`/`await`:
    /// during a scan the cooperative *pool* is saturated with I/O, and while the canvas animates at
    /// 120 fps main-actor jobs arrived 200–330 ms late (measured). This way the
    /// computation (≈ 1 ms) leaves the main thread and comes back on the next cycle.
    private nonisolated static let layoutQueue = DispatchQueue(label: "local.airy.layout",
                                                               qos: .userInteractive, attributes: .concurrent)

    private nonisolated static func compute(_ input: LayoutInput, in bounds: CGRect, qos: DispatchQoS,
                                            then deliver: @escaping @MainActor (MapLayout) -> Void) {
        // `.enforceQoS`: the requested priority wins even if the queue has another (prefetch is `.utility`).
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

    /// Stops the frame clock when done. `asyncAfter` and not `Task.sleep`: with the canvas at
    /// 120 fps main-actor tasks woke up to half a second late (measured).
    private func scheduleStop() {
        // Each new notice invalidates the previous ones (the end may have moved earlier or later).
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
        case .entrance: "entrance"
        case .zoomIn: "zoom in"
        case .zoomOut: "zoom out"
        case .morph: "morph"
        }
    }
}

/// Short fade between two values (highlighted tile, highlighted kind).
struct Fade<Value: Hashable & Sendable>: Sendable {
    static var duration: Double { 0.18 }
    var previous: Value?
    var current: Value?
    var start: Double = 0

    func moving(to value: Value?, at time: Double) -> Fade {
        Fade(previous: current, current: value, start: time)
    }

    /// 0…1 with a smooth ease-out.
    func progress(at time: Double) -> Double {
        let t = min(max((time - start) / Self.duration, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    /// How much `value` gets right now (1 = fully).
    func weight(of value: Value?, at time: Double) -> Double {
        let p = progress(at: time)
        return (current == value ? p : 0) + (previous == value ? 1 - p : 0)
    }
}

/// Small layout cache keyed by (node, size in whole points, tree revision).
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

    /// Removes what was computed for other tree revisions (they would retain deleted subtrees).
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
