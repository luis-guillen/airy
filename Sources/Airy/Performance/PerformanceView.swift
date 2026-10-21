import AppKit
import SwiftUI
import DiskMapCore

/// Rendimiento: remolino según CPU y temperatura, veredicto, memoria, temperatura, CPU, lo que más pesa,
/// extras y mantenimiento. Mide solo mientras se ve (aparece + ventana visible).
struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var appeared = false
    /// nil hasta que el lector de la ventana informe (I3): no se supone visible.
    @ViewState private var windowVisible: Bool?
    @ViewState private var showsAI = false

    private var session: PerformanceSession { model.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Rendimiento", subtitle: subtitle) {
                    if case .ready = model.assistant.claude, session.snapshot != nil {
                        PrimaryButton("¿Por qué va lento?", systemImage: "sparkles", style: .secondary) { showsAI = true }
                            .fixedSize()
                    }
                }
                VerdictCard()
                HStack(alignment: .top, spacing: Theme.spacing) {
                    MemoryCard()
                    VStack(spacing: Theme.spacing) {
                        ThermalCard()
                        CPUCard()
                    }
                }
                HeavyAppsList()
                ExtrasCard()
                MaintenanceCard()
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            .padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { VisibilityReader { windowVisible = $0 } }
        .onAppear {
            appeared = true
            model.assistant.locateIfNeeded()
            updateSampling()
        }
        .onDisappear {
            appeared = false
            session.stop()
        }
        .onChange(of: windowVisible) { _, _ in
            guard appeared else { return }
            updateSampling()
        }
        .sheet(isPresented: $showsAI) {
            SlowAISheet()
                .environment(model)
                .tint(Theme.Airy.accent)
        }
    }

    /// Mide solo con la sección a la vista y la ventana visible; el mantenimiento se comprueba entonces (con caché).
    private func updateSampling() {
        if PerformanceSamplingGate.shouldSample(appeared: appeared, windowVisible: windowVisible) {
            session.start()
            Task { await session.refreshMaintenanceIfStale() }
        } else {
            session.stop()
        }
    }

    private var subtitle: String {
        guard let snapshot = session.snapshot else { return "Midiendo…" }
        let cpu = snapshot.cpu.map { "Procesador al \(Int($0.total.rounded())) %" } ?? "Procesador: —"
        return "\(cpu) · Memoria usada \(Format.bytes(snapshot.memory.used)) de \(Format.bytes(snapshot.memory.total))"
    }
}

/// Cabecera: remolino (más rápido con más CPU, más cálido con el Mac caliente), frase y semáforo.
private struct VerdictCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.performance
        let snapshot = session.snapshot
        let verdict = session.verdict
        GlassCard {
            HStack(alignment: .top, spacing: 18) {
                WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: (snapshot?.cpu?.total ?? 0) / 100),
                          tint: Theme.Airy.swirlTint((snapshot?.thermal.level ?? .nominal).processInfoState))
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.Airy.riskFill(light(verdict?.level))).frame(width: 12, height: 12)
                        Text(lightLabel(verdict?.level))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.Airy.riskInk(light(verdict?.level)))
                    }
                    Text(verdict?.sentence ?? "Midiendo tu Mac…")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .lineLimit(nil)
                    let others = Array((verdict?.findings ?? []).dropFirst().prefix(4))
                    ForEach(others) { finding in
                        Label(finding.sentence, systemImage: "circle.fill")
                            .labelStyle(BulletLabel())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func light(_ level: HealthLevel?) -> Risk {
        switch level {
        case .poor: .doNotTouch
        case .fair: .yourCall
        default: .safe
        }
    }

    private func lightLabel(_ level: HealthLevel?) -> String {
        switch level {
        case .poor: "Problema"
        case .fair: "Atención"
        case .good: "Va bien"
        case nil: "—"
        }
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4))
            configuration.title
        }
    }
}

/// Icono de ayuda con su texto al pasar el ratón.
struct HelpDot: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// Avisa cuando la ventana deja de verse (tapada, minimizada, app oculta) o vuelve a verse. A diferencia de
/// `WindowActivityReader`, no informa al entrar en la ventana (aún sin mostrar, diría «no visible»): solo en
/// cada cambio, y la sección empieza a medir al aparecer.
private struct VisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
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
            let appNames: [Notification.Name] = [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            for (name, object) in windowNames.map({ ($0, window as AnyObject) }) + appNames.map({ ($0, NSApp as AnyObject) }) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.report()
                        // Al volver, el estado de oclusión se actualiza un instante después.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.report() }
                    }
                })
            }
            // I3: el estado de partida también cuenta (una ventana minimizada u oculta no avisa de nada al crearse
            // la vista). Fuera del ciclo de actualización de SwiftUI.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
            PerformanceSession.debugLog("visible=\(visible) occlusion=\(window.occlusionState.rawValue) hidden=\(NSApp.isHidden)")
            onChange?(visible)
        }
    }
}
