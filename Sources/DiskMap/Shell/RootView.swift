import SwiftUI
import DiskMapCore

/// Ventana principal: barra lateral translúcida y contenido de la sección bajo la barra de título oculta.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var bannerDismissed = false
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 720)
        .task { model.startScan() }
    }

    private var showsBanner: Bool { !model.hasFullDiskAccess && !bannerDismissed }

    /// El error de análisis ocupa la pantalla cuando no hay nada que enseñar; si no, va como aviso.
    private var visibleNotices: [Notice] {
        model.notices.filter { !($0.kind == .scan && model.scan == nil) }
    }

    private var detail: some View {
        ZStack(alignment: .top) {
            DetailBackground()

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
        .ignoresSafeArea(edges: .top)
        .toolbar(removing: .sidebarToggle)
    }
}

/// Fondo del contenido: color de ventana con un halo muy suave de la marca.
private struct DetailBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(hex: 0x0A84FF, opacity: colorScheme == .dark ? 0.10 : 0.06), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(hex: 0x5E5CE6, opacity: colorScheme == .dark ? 0.08 : 0.04), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

/// Contenido de cada sección. Las tareas 9–11 sustituyen los marcadores por el mapa, la limpieza y el asistente.
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
            SectionPlaceholder(
                section: section,
                subtitle: mapSubtitle(now: now),
                line: "Aquí verás el disco como un mapa de bloques: cada rectángulo es una carpeta, a escala de lo que ocupa. Haz clic para entrar y usa la ruta de arriba para volver.")
        case .cleanup:
            SectionPlaceholder(
                section: section,
                subtitle: cleanupSubtitle,
                line: "Cachés, registros y restos que se pueden borrar, cada uno con qué es, cuánto ocupa y su riesgo.")
        case .assistant:
            SectionPlaceholder(
                section: section,
                subtitle: "Informe y chat sobre tu disco",
                line: "Claude revisa el análisis (solo rutas, tamaños y fechas, nunca el contenido) y te dice qué borrar sin riesgo, qué depende de ti y qué no tocar.")
        default:
            SectionPlaceholder(section: section, subtitle: "Próximamente", line: "Llegará en la fase 2.")
        }
    }

    private var cleanupSubtitle: String {
        if model.catalogError != nil { return "No disponible: no se pudo cargar el catálogo" }
        if model.isRefreshingCleanup { return "Buscando cachés y restos…" }
        return "\(Theme.count(model.cleanupItems.count)) elementos detectados"
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

            if section == .map, let root = model.scan?.root {
                KindSummary(root: root)
                    .frame(maxWidth: 680, alignment: .leading)
            }

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

/// Reparto por tipo del análisis: barra apilada con la paleta y leyenda escalonada.
private struct KindSummary: View {
    let root: FileNode
    @ViewState private var appeared = false

    private var slices: [(kind: ContentKind, bytes: Int64)] {
        zip(ContentKind.allCases, root.kindBytes)
            .map { (kind: $0, bytes: $1) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        let total = Double(max(root.allocatedSize, 1))
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Qué ocupa el espacio")
                    .font(.headline)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(Array(slices.enumerated()), id: \.element.kind) { index, slice in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.gradient(for: slice.kind))
                                .frame(width: max(appeared ? proxy.size.width * Double(slice.bytes) / total - 2 : 0, 0))
                                .animation(Theme.stagger(index: index), value: appeared)
                                .help("\(slice.kind.title): \(Format.bytes(slice.bytes))")
                        }
                    }
                }
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(slices.enumerated()), id: \.element.kind) { index, slice in
                        HStack(spacing: 8) {
                            Image(systemName: Theme.symbol(for: slice.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.color(for: slice.kind))
                                .frame(width: 16)
                            Text(slice.kind.title)
                                .font(.callout)
                            Spacer(minLength: 4)
                            Text(Format.bytes(slice.bytes))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.trailing, 10)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 6)
                        .animation(Theme.stagger(index: index), value: appeared)
                    }
                }
            }
        }
        .onAppear { appeared = true }
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
                .foregroundStyle(Theme.color(for: .yourCall))
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
                .foregroundStyle(Theme.color(for: .yourCall))
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
