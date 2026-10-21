import AppKit
import SwiftUI
import DiskMapCore

// MARK: - Motion gatekeeper

/// Ambient motion (breeze, logo, orbit). Stopped by default: a view that doesn't receive the
/// gatekeeper (e.g. a new sheet that forgot to inject it) spends no CPU.
private struct AiryAmbientMotionKey: EnvironmentKey {
    static let defaultValue: MotionMode = .paused
}

/// Transient motion (deletion, gust, launch, sway). Reduced by default: fades only.
private struct AiryTransientMotionKey: EnvironmentKey {
    static let defaultValue: MotionMode = .reduced
}

private struct AiryQuietShadowsKey: EnvironmentKey {
    static let defaultValue = false
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
    /// No soft shadows (e.g. during a Cleanup batch): nothing to blur again
    /// every frame while the list collapses.
    var airyQuietShadows: Bool {
        get { self[AiryQuietShadowsKey.self] }
        set { self[AiryQuietShadowsKey.self] = newValue }
    }
}

// MARK: - Window activity

/// Reports whether its containing window is visible (not covered, minimized, or the app hidden) and
/// whether the app is active. It reports on entering the window and on every change.
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

// MARK: - Sway on hover

extension View {
    /// A brief sway, like a leaf in the breeze, every time `hovering` becomes `true`.
    /// Without transient motion (`airyTransientMotion != .running`) it does nothing.
    func hoverSway(_ hovering: Bool) -> some View {
        modifier(HoverSway(hovering: hovering))
    }

    /// Debug only with `AIRY_FPS=1`: logs every ambient mode change.
    func logAmbientMotion(_ mode: MotionMode) -> some View {
        #if DEBUG
        onChange(of: mode, initial: true) { _, mode in
            guard FPSMeter.isEnabled else { return }
            FPSMeter.log("[motion] ambient: \(mode)")
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
                // `swayKeyframes` holds cumulative instants; each keyframe wants its duration.
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

// MARK: - Render server animation

extension CAAnimation {
    /// Frame cap for ambient motion (breeze, logo, glint, orbit): everything is slow
    /// (≤ 1 revolution/s), and at 30 fps it looks as smooth as at 120 Hz with a quarter of the
    /// frames to composite in WindowServer (including the blur of the glass on top).
    static let ambientFrameRate = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)

    /// Local time of `layer` from which a periodic animation of `period` seconds
    /// continues where it was: `timeOffset` so its phase depends only on the layer's clock (plus
    /// `phase`, in turns), and a rebuild (size, scale, appearance) doesn't send it back to the start.
    static func continuousOffset(in layer: CALayer, period: Double, phase: Double = 0) -> CFTimeInterval {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let turns = (now / period + phase).truncatingRemainder(dividingBy: 1)
        return (turns < 0 ? turns + 1 : turns) * period
    }
}

/// Core Animation layer whose endless animations the render server interpolates: the app does
/// nothing per frame. A SwiftUI `repeatForever`, by contrast, recomputes the graph every
/// frame (≈ 10% CPU at 120 Hz per animation, measured). Whoever uses it removes it when there is no
/// ambient motion, and the animation goes away with it.
struct RenderServerLayer: NSViewRepresentable {
    /// When it changes, the layer is rebuilt (in addition to every size change).
    var key: AnyHashable
    /// Freezes the animations in place (speed 0: the render server doesn't interpolate them) and,
    /// when removed, they continue from there without a jump. Layers rebuilt in the meantime are born frozen.
    var paused = false
    /// Fills `container` (coordinates with y pointing down, like SwiftUI) for the given size;
    /// `container.contentsScale` is the screen scale.
    var build: @MainActor (_ container: CALayer, _ size: CGSize) -> Void

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.build = build
        view.key = key
        view.setPaused(paused)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.build = build
        view.setPaused(paused)
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

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if builtSize != bounds.size { rebuild() }
        }

        /// Hand-made layers don't inherit the screen scale: they are rebuilt when it changes.
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if builtSize != nil { rebuild() }
        }

        /// Standard Core Animation recipe to pause and resume a layer and its sublayers.
        func setPaused(_ paused: Bool) {
            guard paused != (container.speed == 0) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if paused {
                let now = container.convertTime(CACurrentMediaTime(), from: nil)
                container.speed = 0
                container.timeOffset = now
            } else {
                let frozen = container.timeOffset
                container.speed = 1
                container.timeOffset = 0
                container.beginTime = 0
                container.beginTime = container.convertTime(CACurrentMediaTime(), from: nil) - frozen
            }
            CATransaction.commit()
        }

        func rebuild() {
            builtSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            // The builder copies this scale into its rasterized layers (strokes, shapes).
            container.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            container.sublayers?.forEach { $0.removeFromSuperlayer() }
            if bounds.width > 0, bounds.height > 0 { build?(container, bounds.size) }
            CATransaction.commit()
        }
    }
}
