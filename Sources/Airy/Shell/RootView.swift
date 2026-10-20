import SwiftUI
import DiskMapCore

/// Ventana principal: barra lateral translúcida y contenido de la sección bajo la barra de título oculta.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var bannerDismissed = false
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.all
    /// Confirmaciones, tandas de limpieza, Papelera y celebración (compartido con la barra lateral).
    @ViewState private var cleanupFlow = CleanupFlow()
    /// Portero de movimiento: hasta que la ventana informa, todo quieto.
    @ViewState private var windowVisible = false
    @ViewState private var appActive = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        #if DEBUG
        if DebugSnapshot.forcesReduceMotion { return true }
        #endif
        return systemReduceMotion
    }

    private var ambientMotion: MotionMode {
        AnimationGate.ambient(windowVisible: windowVisible, appActive: appActive, reduceMotion: reduceMotion)
    }

    private var transientMotion: MotionMode {
        AnimationGate.transient(windowVisible: windowVisible, reduceMotion: reduceMotion)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 720)
        .tint(Theme.Airy.accent)
        .foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)
        .environment(cleanupFlow)
        .environment(\.airyAmbientMotion, ambientMotion)
        .environment(\.airyTransientMotion, transientMotion)
        .background {
            WindowActivityReader { visible, active in
                windowVisible = visible
                appActive = active
            }
        }
        .logAmbientMotion(ambientMotion)
        .sheet(item: $cleanupFlow.sheet) { sheet in
            Group {
                switch sheet {
                case .confirm(let request): ConfirmSheet(request: request)
                case .snapshots(let notice): SnapshotsSheet(notice: notice)
                }
            }
            .tint(Theme.Airy.accent)
            .foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)
            .environment(model)
            .environment(cleanupFlow)
            .environment(\.airyAmbientMotion, ambientMotion)
            .environment(\.airyTransientMotion, transientMotion)
        }
        .task { model.startScan() }
        .task(id: model.pendingURLCommand?.id) {
            if let pending = model.pendingURLCommand { await model.run(pending, flow: cleanupFlow) }
        }
    }

    private var showsBanner: Bool { !model.hasFullDiskAccess && !bannerDismissed }

    /// El error de análisis ocupa la pantalla cuando no hay nada que enseñar; si no, va como aviso.
    private var visibleNotices: [Notice] {
        model.notices.filter { !($0.kind == .scan && model.scan == nil) }
    }

    private var detail: some View {
        ZStack(alignment: .top) {
            BreezeBackground(intensity: .ambient)

            VStack(spacing: 0) {
                if showsBanner {
                    FullDiskAccessBanner { withAnimation(Theme.sectionSpring) { bannerDismissed = true } }
                        .padding(.horizontal, Theme.contentPadding)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(visibleNotices) { notice in
                    NoticeBanner(notice: notice) {
                        withAnimation(Theme.sectionSpring) { model.dismiss(notice.kind) }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    if model.scan == nil, model.isScanning {
                        ScanProgressView(style: .hero)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if model.scan == nil, let error = model.scanError {
                        ScanErrorView(message: error)
                    } else {
                        SectionContent(section: model.section)
                            .id(model.section)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 10)),
                                removal: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(Theme.sectionSpring, value: model.section)
            .animation(Theme.sectionSpring, value: model.scan == nil)
            .animation(Theme.sectionSpring, value: showsBanner)
            .animation(Theme.sectionSpring, value: model.notices)

            if model.isScanning, model.scan != nil {
                ScanProgressView(style: .compact)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.sectionSpring, value: model.isScanning)
        .overlay { celebrationLayer }
        .ignoresSafeArea(edges: .top)
        .toolbar(removing: .sidebarToggle)
    }
}

extension RootView {
    /// Celebración al liberar espacio, encima del contenido (venga de Limpieza o de la barra lateral).
    @ViewBuilder fileprivate var celebrationLayer: some View {
        if let celebration = cleanupFlow.celebration {
            FreedCelebration(bytes: celebration.bytes) {
                withAnimation(.easeOut(duration: 0.25)) {
                    if cleanupFlow.celebration == celebration { cleanupFlow.celebration = nil }
                }
            }
            .id(celebration.id)
            .transition(.opacity)
        }
    }
}

/// Contenido de cada sección. Las tareas 10–11 sustituyen los marcadores de la limpieza y el asistente.
private struct SectionContent: View {
    @Environment(AppModel.self) private var model
    let section: Section

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        switch section {
        case .map:
            MapView(subtitle: mapSubtitle(now: now))
        case .cleanup:
            CleanupView()
        case .assistant:
            AssistantView()
        default:
            SectionPlaceholder(section: section, subtitle: "Próximamente", line: "Llegará en la fase 2.")
        }
    }

    private func mapSubtitle(now: Date) -> String {
        guard let scan = model.scan else { return "Sin análisis todavía" }
        let date = model.lastScanDate.map { " · Último análisis: \(Theme.relative($0, now: now))" } ?? ""
        return "\(Format.bytes(scan.root.allocatedSize)) analizados en \(model.currentVolume.name)\(date)"
    }
}

/// Marcador cuidado para las secciones aún sin construir: cabecera real y una tarjeta de cristal.
private struct SectionPlaceholder: View {
    @Environment(AppModel.self) private var model
    let section: Section
    let subtitle: String
    let line: String

    @ViewState private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader(title: section.title, subtitle: subtitle) {
                if !model.isScanning {
                    PrimaryButton("Analizar de nuevo", systemImage: "arrow.clockwise", style: .secondary) {
                        model.startScan()
                    }
                    .fixedSize()
                }
            }

            GlassCard {
                HStack(alignment: .top, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.brand)
                        Image(systemName: section.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, value: appeared)
                    }
                    .frame(width: 54, height: 54)
                    .shadow(color: Theme.userFilesColor.opacity(0.3), radius: 10, y: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                        Text(line)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Theme.zoomSpring) { appeared = true } }
    }
}

/// Aviso descartable para problemas que no bloquean la app (reanálisis fallido, índice sin guardar…).
private struct NoticeBanner: View {
    let notice: Notice
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.kind == .scan ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
            Text(notice.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Ocultar aviso")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.color(for: .yourCall).opacity(0.35), lineWidth: 0.75)
        }
    }
}

private struct ScanErrorView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            PrimaryButton("Reintentar", systemImage: "arrow.clockwise") { model.startScan() }
                .fixedSize()
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}
