import AppKit
import SwiftUI
import DiskMapCore

/// Performance: a swirl driven by CPU and temperature, verdict, memory, temperature, CPU, the heaviest apps,
/// extras and maintenance. It only measures while visible (appeared + window visible).
struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var appeared = false
    /// nil until the window reader reports (I3): it isn't assumed visible.
    @ViewState private var windowVisible: Bool?
    @ViewState private var showsAI = false

    private var session: PerformanceSession { model.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: Section.performance.title, subtitle: subtitle) {
                    if model.settings.aiEnabled, case .ready = model.assistant.claude, session.snapshot != nil {
                        PrimaryButton("Why Is It Slow?", systemImage: "sparkles", style: .secondary) { showsAI = true }
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
            if model.settings.aiEnabled { model.assistant.locateIfNeeded() }
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

    /// Measures only with the section in view and the window visible; maintenance is checked then (with a cache).
    private func updateSampling() {
        if PerformanceSamplingGate.shouldSample(appeared: appeared, windowVisible: windowVisible) {
            session.start()
            Task { await session.refreshMaintenanceIfStale() }
        } else {
            session.stop()
        }
    }

    private var subtitle: String {
        guard let snapshot = session.snapshot else { return String(localized: "Measuring…") }
        let cpu = snapshot.cpu.map { String(localized: "Processor at \(Int($0.total.rounded()))%") } ?? String(localized: "Processor: —")
        return String(localized: "\(cpu) · Memory used \(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total))")
    }
}

/// Header: swirl (faster with more CPU, warmer with a hot Mac), sentence and traffic light.
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
                    Text(verdict?.sentence ?? String(localized: "Measuring your Mac…"))
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
        case .poor: String(localized: "Problem")
        case .fair: String(localized: "Attention")
        case .good: String(localized: "Doing Well")
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

/// Help icon with its text on hover.
struct HelpDot: View {
    let text: LocalizedStringKey
    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// Reports when the window stops being visible (covered, minimized, app hidden) or becomes visible again. Unlike
/// `WindowActivityReader`, it doesn't report on entering the window (not shown yet, it would say "not visible"): only on
/// each change, and the section starts measuring when it appears.
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
                        // On return, the occlusion state updates a moment later.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.report() }
                    }
                })
            }
            // I3: the initial state counts too (a minimized or hidden window reports nothing when the view
            // is created). Outside SwiftUI's update cycle.
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
