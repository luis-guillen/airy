import AppKit
import SwiftUI
import DiskMapCore

// MARK: - Portero de movimiento

/// Movimiento ambiente (brisa, logo, órbita). Por defecto parado: una vista que no recibe el
/// portero (p. ej. una hoja nueva que olvidó inyectarlo) no gasta CPU.
private struct AiryAmbientMotionKey: EnvironmentKey {
    static let defaultValue: MotionMode = .paused
}

/// Movimiento transitorio (borrar, ráfaga, arranque, balanceo). Por defecto reducido: solo fundidos.
private struct AiryTransientMotionKey: EnvironmentKey {
    static let defaultValue: MotionMode = .reduced
}

extension EnvironmentValues {
    var airyAmbientMotion: MotionMode {
        get { self[AiryAmbientMotionKey.self] }
        set { self[AiryAmbientMotionKey.self] = newValue }
    }

    var airyTransientMotion: MotionMode {
        get { self[AiryTransientMotionKey.self] }
        set { self[AiryTransientMotionKey.self] = newValue }
    }
}

// MARK: - Actividad de la ventana

/// Avisa de si la ventana que lo contiene se ve (no tapada, ni minimizada, ni la app oculta) y de
/// si la app está activa. Informa al entrar en la ventana y en cada cambio.
struct WindowActivityReader: NSViewRepresentable {
    var onChange: (_ visible: Bool, _ active: Bool) -> Void

    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ActivityView, context: Context) {
        view.onChange = onChange
    }

    final class ActivityView: NSView {
        var onChange: ((Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            guard let window else { return }
            let windowNames: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                                    NSWindow.didMiniaturizeNotification,
                                                    NSWindow.didDeminiaturizeNotification]
            let appNames: [Notification.Name] = [NSApplication.didBecomeActiveNotification,
                                                 NSApplication.didResignActiveNotification,
                                                 NSApplication.didHideNotification,
                                                 NSApplication.didUnhideNotification]
            for (name, object) in windowNames.map({ ($0, window as AnyObject) }) + appNames.map({ ($0, NSApp as AnyObject) }) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
            onChange?(visible, NSApp.isActive)
        }
    }
}

// MARK: - Balanceo al pasar el ratón

extension View {
    /// Balanceo breve, como una hoja con la brisa, cada vez que `hovering` pasa a `true`.
    /// Sin movimiento transitorio (`airyTransientMotion != .running`) no hace nada.
    func hoverSway(_ hovering: Bool) -> some View {
        modifier(HoverSway(hovering: hovering))
    }

    /// Solo en Debug con `AIRY_FPS=1`: registra cada cambio del modo ambiente.
    func logAmbientMotion(_ mode: MotionMode) -> some View {
        #if DEBUG
        onChange(of: mode, initial: true) { _, mode in
            guard FPSMeter.isEnabled else { return }
            FPSMeter.log("[motion] ambiente: \(mode)")
        }
        #else
        self
        #endif
    }
}

private struct HoverSway: ViewModifier {
    let hovering: Bool
    @Environment(\.airyTransientMotion) private var motion
    @ViewState private var trigger = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, degrees in
                view.rotationEffect(.degrees(degrees), anchor: .bottom)
            } keyframes: { _ in
                // `swayKeyframes` lleva instantes acumulados; cada fotograma clave quiere su duración.
                KeyframeTrack {
                    for (index, frame) in WindMotion.swayKeyframes.enumerated() {
                        let previous = index == 0 ? 0 : WindMotion.swayKeyframes[index - 1].time
                        CubicKeyframe(frame.degrees, duration: frame.time - previous)
                    }
                }
            }
            .onChange(of: hovering) { _, now in
                if now, motion == .running { trigger += 1 }
            }
    }
}

// MARK: - Animación del servidor de render

/// Capa de Core Animation cuyas animaciones infinitas interpola el servidor de render: la app no
/// hace nada por fotograma. Un `repeatForever` de SwiftUI, en cambio, recalcula el grafo en cada
/// fotograma (≈ 10 % de CPU a 120 Hz por animación, medido). Quien la usa la retira cuando no hay
/// movimiento ambiente, y con ella desaparece la animación.
struct RenderServerLayer: NSViewRepresentable {
    /// Cuando cambia, la capa se reconstruye (además de con cada cambio de tamaño).
    var key: AnyHashable
    /// Llena `container` (coordenadas con y hacia abajo, como SwiftUI) para el tamaño dado.
    var build: @MainActor (_ container: CALayer, _ size: CGSize) -> Void

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.build = build
        view.key = key
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.build = build
        if view.key != key {
            view.key = key
            view.rebuild()
        }
    }

    final class HostView: NSView {
        var build: (@MainActor (CALayer, CGSize) -> Void)?
        var key: AnyHashable?
        private let container = CALayer()
        private var builtSize: CGSize?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(container)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if builtSize != bounds.size { rebuild() }
        }

        func rebuild() {
            builtSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            container.sublayers?.forEach { $0.removeFromSuperlayer() }
            if bounds.width > 0, bounds.height > 0 { build?(container, bounds.size) }
            CATransaction.commit()
        }
    }
}
