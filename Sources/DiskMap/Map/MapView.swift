import SwiftUI
import AppKit
import DiskMapCore

/// Sección Mapa: cabecera, ruta de navegación, el mapa de bloques animado y la leyenda por tipo.
struct MapView: View {
    @Environment(AppModel.self) private var model
    let subtitle: String

    @ViewState private var scene = MapScene()
    @ViewState private var tracker = HoverTracker()
    @ViewState private var canvasSize: CGSize = .zero
    /// La confirmación única de la app (la misma hoja que Limpieza y el asistente).
    @Environment(CleanupFlow.self) private var flow: CleanupFlow?
    @ViewState private var toast: MapToast?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Mapa", subtitle: subtitle) {
                if !model.isScanning {
                    PrimaryButton("Analizar de nuevo", systemImage: "arrow.clockwise", style: .secondary) {
                        model.startScan()
                    }
                    .fixedSize()
                }
            }

            Breadcrumb(items: model.navigation.breadcrumb, onBack: goBack, onJump: jump(to:))

            canvas

            if let current = model.navigation.current {
                KindLegend(node: current) { scene.setDim($0) }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 34)
        // Durante un reanálisis la píldora de progreso ocupa el pie: la leyenda sube por encima.
        .padding(.bottom, model.isScanning && model.scan != nil ? 76 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand(perform: goBack)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            tracker.menuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            tracker.menuOpen = false
        }
        .onAppear {
            focused = true
            scene.show(model.navigation.current, revision: model.treeRevision)
        }
        .onChange(of: model.navigation.current?.id) { _, _ in
            clearHover()
            scene.show(model.navigation.current, revision: model.treeRevision)
        }
        .onChange(of: scene.settledCount) { _, _ in
            // Al acabar un zoom, si el puntero sigue encima, vuelve la tarjeta de lo que hay debajo.
            if tracker.pointerInside { hover(at: tracker.location) }
        }
        .onChange(of: model.treeRevision) { _, revision in
            clearHover()
            scene.show(model.navigation.current, revision: revision)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .diskMapDebugToast)) { note in
            guard let outcome = note.userInfo?["outcome"] as? CleanupOutcome,
                  let title = note.userInfo?["title"] as? String else { return }
            showToast(MapToast(outcome: outcome, title: title))
        }
        .task { await MapDebugScript.run(scene: scene, tracker: tracker, model: model,
                                         openTrash: { requestTrash($0) }) }
        #endif
    }

    // MARK: Lienzo

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                TreemapCanvas(scene: scene)
                    .onAppear { updateSize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in updateSize(size) }
                    #if DEBUG
                    .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                        scene.canvasFrameInWindow = frame
                    }
                    #endif
            }

            if let layout = scene.layout, layout.tiles.isEmpty, scene.transition == nil {
                ContentUnavailableView("Carpeta vacía", systemImage: "folder",
                                       description: Text("Aquí no hay nada que ocupe espacio."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HoverCardLayer(tracker: tracker, canvasSize: canvasSize)

            if let toast {
                MapToastView(toast: toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }

            #if DEBUG
            if FPSMeter.isEnabled { FPSBadge().frame(maxWidth: .infinity, alignment: .topTrailing).padding(8) }
            #endif
        }
        .animation(Theme.sectionSpring, value: toast?.id)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                tracker.pointerInside = true
                hover(at: point)
            case .ended:
                tracker.pointerInside = false
                clearHover()
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { point in tap(at: point) }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Subir un nivel") { goBack() }
    }

    private func updateSize(_ size: CGSize) {
        canvasSize = size
        scene.resize(to: size)
    }

    // MARK: Ratón

    private func hover(at point: CGPoint) {
        tracker.location = point
        let tile = scene.tile(at: point)
        guard tile?.id != tracker.details?.id else { return }
        if let tile {
            tracker.details = TileDetails(tile: tile, parent: model.navigation.current, catalog: model.catalog)
            if tile.isZoomable, let node = tile.node { scene.prefetch(node) }
        } else {
            tracker.details = nil
        }
        scene.setHover(tile?.id)
    }

    private func clearHover() {
        tracker.details = nil
        scene.setHover(nil)
    }

    private func tap(at point: CGPoint) {
        focused = true
        guard let tile = scene.tile(at: point), tile.isZoomable, let node = tile.node else { return }
        clearHover()
        model.navigation.zoom(into: node)
    }

    private func goBack() {
        guard model.navigation.canZoomOut else { return }
        clearHover()
        model.navigation.zoomOut()
    }

    private func jump(to index: Int) {
        clearHover()
        model.navigation.jump(to: index)
    }

    // MARK: Menú contextual

    @ViewBuilder private var contextMenu: some View {
        if let details = tracker.details, let path = details.path, let tildePath = details.tildePath {
            Button("Mostrar en Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Explicar con IA", systemImage: "sparkles") {
                model.pendingAssistantQuestion = "¿Qué es \(tildePath) y puedo borrarlo?"
                model.section = .assistant
            }
            if let risk = details.risk, risk != .doNotTouch {
                Divider()
                Button("Mover a la Papelera…", systemImage: "trash", role: .destructive) {
                    requestTrash(TrashCandidate(title: details.title, path: path, tildePath: tildePath,
                                                bytes: details.bytes))
                }
                .disabled(flow == nil || flow?.isBusy == true)
            }
        }
    }

    /// Abre `ConfirmSheet` (`.trashPaths`); al terminar, el aviso del mapa cuenta el resultado.
    private func requestTrash(_ candidate: TrashCandidate) {
        let title = candidate.title
        flow?.requestTrash(paths: [candidate.path], title: title, onOutcome: { outcome in
            showToast(MapToast(outcome: outcome, title: title))
        })
    }

    private func showToast(_ shown: MapToast) {
        toast = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated { if toast?.id == shown.id { toast = nil } }
        }
    }

    // MARK: Accesibilidad

    private var accessibilitySummary: String {
        guard let current = model.navigation.current else { return "Mapa del disco sin análisis" }
        let name = model.navigation.breadcrumb.last ?? current.name
        let biggest = current.children.filter { $0.allocatedSize > 0 }
            .sorted { $0.allocatedSize > $1.allocatedSize }
            .prefix(5)
            .map { "\($0.aggregatedCount > 0 ? "Otros" : $0.name), \(Format.bytes($0.allocatedSize))" }
        let list = biggest.isEmpty ? "Está vacía." : "Lo que más ocupa: \(biggest.joined(separator: "; "))."
        return "Mapa de \(name), \(Format.bytes(current.allocatedSize)). \(list)"
    }
}

// MARK: - Papelera y aviso

struct TrashCandidate: Equatable {
    let title: String
    let path: String
    let tildePath: String
    let bytes: Int64
}

struct MapToast: Equatable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let message: String

    init(outcome: CleanupOutcome, title: String) {
        switch outcome {
        case .movedToTrash(let bytes):
            symbol = "trash.fill"
            tint = Theme.color(for: .safe)
            message = "«\(title)» está en la Papelera (\(Format.bytes(bytes))). Se libera al vaciarla."
        case .freed(let bytes):
            symbol = "checkmark.circle.fill"
            tint = Theme.color(for: .safe)
            message = "Liberados \(Format.bytes(bytes))."
        case .blocked(let reason):
            symbol = "hand.raised.fill"
            tint = Theme.color(for: .yourCall)
            message = "No se ha movido: \(reason)"
        case .failed(let reason):
            symbol = "exclamationmark.triangle.fill"
            tint = Theme.color(for: .doNotTouch)
            message = reason
        }
    }
}

private struct MapToastView: View {
    let toast: MapToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.tint)
            Text(toast.message)
                .font(.callout.weight(.medium))
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(toast.tint.opacity(0.35), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .allowsHitTesting(false)
    }
}

#if DEBUG
@MainActor private func postKey(_ name: String) {
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
    let (characters, code, flags): (String, UInt16, NSEvent.ModifierFlags) =
        name == "cmd-[" ? ("[", 33, .command) : ("\u{1b}", 53, [])
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}

@MainActor private func postMouse(_ action: String, at canvasPoint: CGPoint, scene: MapScene) {
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
          let content = window.contentView else { return }
    let frame = scene.canvasFrameInWindow
    let location = CGPoint(x: frame.minX + canvasPoint.x, y: content.bounds.height - (frame.minY + canvasPoint.y))
    let types: [NSEvent.EventType] = switch action {
    case "click": [.mouseMoved, .leftMouseDown, .leftMouseUp]
    case "rclick": [.mouseMoved, .rightMouseDown, .rightMouseUp]
    default: [.mouseMoved]
    }
    for type in types {
        if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}

extension Notification.Name {
    static let diskMapDebugToast = Notification.Name("DiskMapDebugToast")
}

/// Contador de fotogramas en pantalla (solo con DISKMAP_FPS=1).
private struct FPSBadge: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("\(FPSMeter.shared.currentFPS) fps")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }
}

/// Solo en Debug: acciones programadas sobre el mapa para revisarlo sin ratón.
/// `DISKMAP_MAP_SCRIPT="zoom@3,hover@5,legend:video@6,back@7"`. Acciones: `zoom[:nombre]`,
/// `back`, `jump:N`, `hover[:nombre]`, `unhover`, `legend:<tipo>|none`, `trash[:nombre]` (abre la confirmación).
@MainActor
enum MapDebugScript {
    static func run(scene: MapScene, tracker: HoverTracker, model: AppModel,
                    openTrash: @escaping (TrashCandidate) -> Void) async {
        guard let script = ProcessInfo.processInfo.environment["DISKMAP_MAP_SCRIPT"] else { return }
        let start = DebugSnapshot.start
        let steps = script.split(separator: ",").compactMap { raw -> (String, String?, Double)? in
            let parts = raw.split(separator: "@")
            guard parts.count == 2, let time = Double(parts[1]) else { return nil }
            let action = parts[0].split(separator: ":", maxSplits: 1).map(String.init)
            return (action[0], action.count > 1 ? action[1] : nil, time)
        }
        // Cada paso va en su propio `asyncAfter` (exacto al fotograma; `Task.sleep` llega tarde mientras anima).
        for (action, argument, time) in steps {
            let wait = max(time - Date().timeIntervalSince(start), 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    perform(action, argument, time, scene: scene, tracker: tracker, model: model, openTrash: openTrash)
                }
            }
        }
    }

    private static func perform(_ action: String, _ argument: String?, _ time: Double, scene: MapScene,
                                tracker: HoverTracker, model: AppModel,
                                openTrash: @escaping (TrashCandidate) -> Void) {
        do {
            FPSMeter.log("[script] \(action) \(argument ?? "") (previsto a \(time) s)")
            let tiles = scene.layout?.tiles ?? []
            func pick(_ zoomable: Bool) -> MapTile? {
                if let argument { return tiles.first { $0.name == argument } }
                return tiles.filter { !zoomable || $0.isZoomable }.max { $0.bytes < $1.bytes }
            }
            switch action {
            case "zoom":
                if let node = pick(true)?.node { model.navigation.zoom(into: node) }
            case "back":
                model.navigation.zoomOut()
            case "open":
                let path = (argument ?? "").replacingOccurrences(of: "~", with: NSHomeDirectory())
                if let node = model.node(atPath: path) { model.navigation.zoom(into: node) }
            case "key":
                // Teclas de verdad en la cola de eventos de la app: "esc" o "cmd-[".
                postKey(argument ?? "esc")
            case "move", "click", "rclick":
                // Ratón de verdad sobre el centro de una tesela (hover, clic, menú contextual).
                if let tile = pick(action == "click") {
                    postMouse(action, at: CGPoint(x: tile.rect.midX, y: tile.rect.midY), scene: scene)
                }
            case "busiest":
                // La carpeta con más hijos directos del análisis (prueba de miles de teselas).
                var best: FileNode?
                var stack = model.scan.map { [$0.root] } ?? []
                while let node = stack.popLast() {
                    if node.isDirectory, node.aggregatedCount == 0,
                       node.children.count > (best?.children.count ?? 0) { best = node }
                    stack.append(contentsOf: node.children.filter(\.isDirectory))
                }
                if let best {
                    FPSMeter.log("[script] carpeta con más hijos: \(best.path) (\(best.children.count))")
                    model.navigation.zoom(into: best)
                }
            case "jump":
                model.navigation.jump(to: Int(argument ?? "0") ?? 0)
            case "hover":
                if let tile = pick(false) {
                    tracker.location = CGPoint(x: tile.rect.midX - 20, y: tile.rect.midY - 30)
                    tracker.details = TileDetails(tile: tile, parent: model.navigation.current, catalog: model.catalog)
                    scene.setHover(tile.id)
                }
            case "unhover":
                tracker.details = nil
                scene.setHover(nil)
            case "legend":
                scene.setDim(ContentKind(rawValue: argument ?? ""))
            case "trash":
                if let tile = pick(false), let node = tile.node {
                    openTrash(TrashCandidate(title: tile.name, path: node.path,
                                             tildePath: Format.tildePath(node.path), bytes: tile.bytes))
                }
            default:
                FPSMeter.log("[script] acción desconocida: \(action)")
            }
        }
    }
}
#endif
