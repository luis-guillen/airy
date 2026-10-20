import SwiftUI
import DiskMapCore

/// Arranque: sobre una capa opaca a pantalla completa, las hojas llegan en espiral y forman el
/// logo (`WindLeaves(.launch)`, en un lienzo que llena la capa); el logo aparece con fundido en el
/// último 35 % de `gather`, se sostiene `hold` y la capa entera se funde en `fade`. Un clic la
/// cierra al momento. Con «Reducir movimiento», solo el logo con fundido de entrada y salida.
///
/// El modo transitorio se lee al empezar. El portero arranca en `.paused` hasta que la ventana dice
/// que se ve: la capa espera quieta como mucho `visibilityGrace`; si sigue en pausa (ventana tapada
/// u oculta) o se pausa ya empezada, termina al momento.
/// Los plazos van con `DispatchQueue.main.asyncAfter`, no con `Task.sleep` (ver `MapScene.scheduleStop`).
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
            if FPSMeter.isEnabled { FPSMeter.log("[motion] arranque: \(mode)") }
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
            FPSMeter.shared.begin("arranque")
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
