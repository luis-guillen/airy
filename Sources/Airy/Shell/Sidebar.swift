import SwiftUI
import DiskMapCore

/// Barra lateral translúcida: marca, secciones, selector de disco y tarjeta de uso.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                brand
                    .padding(.horizontal, -10)
                    .padding(.top, 34)
                    .padding(.bottom, 6)
                ForEach(Section.available) { section in
                    SidebarRow(section: section, selected: model.section == section) { select(section) }
                }

                Text("Próximamente")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                ForEach(Section.comingSoon) { section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .help("Llegará en la fase 2")
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Próximamente")
                    .accessibilityAddTraits(.isStaticText)
                    .disabled(true)
                }
            }
            .padding(.horizontal, 10)
        }
        .ignoresSafeArea(.container, edges: .top)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let sections = Section.available
            guard let index = sections.firstIndex(of: model.section) else { return }
            switch direction {
            case .up where index > 0: select(sections[index - 1])
            case .down where index < sections.count - 1: select(sections[index + 1])
            default: break
            }
        }
        .background(Theme.Airy.backgroundRaised)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                VolumePicker()
                DiskCard()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 330)
        .toolbar(removing: .sidebarToggle)
    }

    /// Las secciones de la fase 2 no se pueden elegir.
    private func select(_ section: Section) {
        guard section.isAvailable, section != model.section else { return }
        withAnimation(Theme.sectionSpring) { model.section = section }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            AiryLogo(size: 26, animated: true)
            Text("Airy")
                .font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Fila de sección

/// Fila de la barra lateral con selección propia en azul Airy (la de `List` usa el acento del sistema).
private struct SidebarRow: View {
    let section: Section
    let selected: Bool
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .foregroundStyle(selected ? Theme.Airy.onAccent : Theme.Airy.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Theme.Airy.accentFill)
                                       : AnyShapeStyle(Theme.Airy.accent.opacity(hovering ? 0.12 : 0)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Selector de disco

private struct VolumePicker: View {
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        let current = model.currentVolume
        Menu {
            ForEach(model.volumes) { volume in
                Button {
                    model.selectedVolume = volume.url
                } label: {
                    Label(volume.name, systemImage: volume.url == model.selectedVolume ? "checkmark" : volume.symbol)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current.symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.userFiles)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    // Se redibuja cada 30 s para que "hace X" no se quede viejo.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(lastScanLine(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.primary.opacity(hovering ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering in withAnimation(Theme.pressSpring) { self.hovering = hovering } }
        .help("Elegir el disco que se analiza")
    }

    private func lastScanLine(now: Date) -> String {
        if model.isScanning && model.scan == nil { return "Analizando…" }
        guard let date = model.lastScanDate else { return "Sin analizar" }
        return "Analizado \(Theme.relative(date, now: now))"
    }
}

// MARK: - Tarjeta del disco

private struct DiskCard: View {
    @Environment(AppModel.self) private var model
    /// Opcional: sin `CleanupFlow` en el entorno (vistas sueltas, vistas previas) no se cae; el botón queda inactivo.
    @Environment(CleanupFlow.self) private var flow: CleanupFlow?

    var body: some View {
        let usage = model.diskUsage
        // En el primer análisis "Analizado" cambia cada 100 ms: cifras fijas para que se lean.
        let live = model.isScanning && model.scan == nil
        GlassCard(padding: 14, radius: 16, material: .thinMaterial) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    UsageRing(usage: usage)
                        .frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.bytes(usage.free))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(usage.free)))
                        Text("libres de \(Format.bytes(usage.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .animation(Theme.counterSpring, value: usage.free)
                }

                VStack(alignment: .leading, spacing: 5) {
                    LegendRow(color: Theme.userFilesColor, title: "Analizado", bytes: usage.analyzed, rolls: !live)
                        .help("Lo que suma el análisis de este disco (al analizar el disco de arranque incluye macOS y las apps).")
                    // Si lo analizado ya cubre lo usado, el resto no se puede saber: "—", nunca "0 kB".
                    LegendRow(color: Theme.systemColor, title: "Sistema y otros", bytes: usage.other, rolls: !live)
                        .help(usage.other == nil
                              ? "El análisis ya cubre todo lo ocupado: no queda un resto que se pueda medir."
                              : "Lo ocupado que el análisis no ve: partes del sistema, otros usuarios y lo que no se pudo leer.")
                    LegendRow(color: Theme.purgeableColor, title: "Purgable", bytes: usage.purgeable, rolls: !live)
                        .help("Espacio que macOS libera solo cuando hace falta (instantáneas locales, cachés purgables).")
                    LegendRow(color: .primary.opacity(0.18), title: "Libre", bytes: usage.free, rolls: !live)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 8) {
                    if let trash = model.trashBytes {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("En la Papelera:")
                                .foregroundStyle(.secondary)
                            BytesCounter(bytes: trash, font: .callout.weight(.semibold))
                        }
                        .font(.callout)
                    } else {
                        // Sin permiso para leer ~/.Trash no se sabe cuánto hay: nunca "0 kB".
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("En la Papelera: no se puede leer sin Acceso total al disco")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    // Activo también si no se puede leer: entonces lo vacía Finder.
                    // La confirmación (qué, cuánto y el aviso de Finder) la abre `CleanupFlow`.
                    PrimaryButton("Vaciar Papelera…", systemImage: "trash.slash", style: .secondary,
                                  isBusy: flow?.isEmptyingTrash ?? false) {
                        flow?.requestEmptyTrash(model)
                    }
                    .disabled(flow == nil || model.trashBytes == 0 || flow?.isRunning == true)

                    HStack(spacing: 6) {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(Theme.Airy.riskInk(.safe))
                        Text("Liberado en total:")
                            .foregroundStyle(.secondary)
                        if model.totalFreedKnown {
                            BytesCounter(bytes: model.totalFreed, font: .callout.weight(.semibold))
                        } else {
                            Text("—").font(.callout.weight(.semibold))
                                .help("No se pudo leer el historial de limpiezas")
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let title: String
    /// `nil`: no se puede saber ("—").
    let bytes: Int64?
    /// `false` mientras el valor cambia cada 100 ms (primer análisis): cifras fijas, sin rodar.
    var rolls = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(bytes.map(Format.bytes) ?? "—")
                .monospacedDigit()
                .contentTransition(rolls ? .numericText(value: Double(bytes ?? 0)) : .identity)
        }
        .font(.caption)
        .animation(rolls ? Theme.counterSpring : nil, value: bytes)
    }
}

/// Anillo de uso: "Analizado", "Sistema y otros" y "Purgable" sobre una pista que representa lo libre.
/// Las tres partes suman lo usado (véase `DiskUsageBreakdown`).
struct UsageRing: View {
    let usage: DiskUsageBreakdown
    var lineWidth: CGFloat = 9

    @ViewState private var appeared = false

    var body: some View {
        let ring = usage.ringFractions
        let analyzed = appeared ? ring.analyzed : 0
        let other = appeared ? ring.analyzed + ring.other : 0
        let used = appeared ? usage.usedFraction : 0
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: other, to: used)
                .stroke(Theme.purgeableColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: analyzed, to: other)
                .stroke(Theme.systemColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: analyzed)
                .stroke(Theme.userFiles, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((used * 100).rounded())) %")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: used))
                Text("usado")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .animation(Theme.counterSpring, value: usage)
        .onAppear { withAnimation(Theme.counterSpring.delay(0.15)) { appeared = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disco: \(Format.bytes(usage.used)) usados de \(Format.bytes(usage.total)); \(Format.bytes(usage.analyzed)) analizados, \(Format.bytes(usage.purgeable)) purgables")
    }
}
