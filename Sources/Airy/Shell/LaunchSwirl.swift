import SwiftUI
import DiskMapCore

/// Launch: over an opaque full-screen layer, the leaves spiral in and form the logo
/// (`WindLeaves(.launch)`, on a canvas that fills the layer); the logo fades in during the
/// last 35% of `gather`, holds for `hold` and the whole layer fades out over `fade`. A click
/// dismisses it at once. With "Reduce motion", only the logo, fading in and out.
///
/// The transient mode is read at the start. The gatekeeper starts at `.paused` until the window says
/// it is visible: the layer waits still for at most `visibilityGrace`; if it stays paused (window covered
/// or hidden) or is paused once started, it finishes at once.
/// Delays use `DispatchQueue.main.asyncAfter`, not `Task.sleep` (see `MapScene.scheduleStop`).
struct LaunchSwirl: View {
    var onDone: () -> Void

    @Environment(\.airyTransientMotion) private var motion
    @ViewState private var start: Date?
    @ViewState private var playing = MotionMode.paused
    @ViewState private var logoOpacity = 0.0
    @ViewState private var layerOpacity = 1.0
    @ViewState private var finished = false

    static let visibilityGrace = 1.5

    var body: some View {
        ZStack {
            Theme.Airy.background
            if let start, playing == .running {
                WindLeaves(mode: .launch(start: start), count: WindMotion.launchLeafCount)
            }
            AiryLogo(size: WindLeaves.launchLogoSize)
                .opacity(logoOpacity)
        }
        .ignoresSafeArea()
        .opacity(layerOpacity)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityHidden(true)
        .onAppear {
            after(Self.visibilityGrace) { if start == nil { finish() } }
        }
        .onChange(of: motion, initial: true) { _, mode in
            #if DEBUG
            if FPSMeter.isEnabled { FPSMeter.log("[motion] launch: \(mode)") }
            #endif
            if start == nil {
                if mode != .paused { begin(mode) }
            } else if mode == .paused {
                finish()
            }
        }
    }

    private func begin(_ mode: MotionMode) {
        let timeline = WindMotion.launchTimeline(mode)
        start = Date()
        playing = mode
        if mode == .running {
            #if DEBUG
            FPSMeter.shared.begin("launch")
            #endif
            after(0.65 * timeline.gather) {
                withAnimation(.easeOut(duration: 0.35 * timeline.gather)) { logoOpacity = 1 }
            }
        } else {
            withAnimation(.easeOut(duration: timeline.gather)) { logoOpacity = 1 }
        }
        after(timeline.gather + timeline.hold) {
            withAnimation(.easeIn(duration: timeline.fade)) { layerOpacity = 0 }
        }
        after(timeline.gather + timeline.hold + timeline.fade) { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        #if DEBUG
        if playing == .running { FPSMeter.shared.end() }
        #endif
        onDone()
    }

    private func after(_ delay: Double, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { block() }
        }
    }
}
