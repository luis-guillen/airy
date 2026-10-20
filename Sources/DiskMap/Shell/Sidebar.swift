import SwiftUI
import DiskMapCore

/// Barra lateral translúcida: marca, secciones, selector de disco y tarjeta de uso.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            SwiftUI.Section {
                ForEach(Section.available) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }

            SwiftUI.Section("Próximamente") {
                ForEach(Section.comingSoon) { section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                        Spacer()
                        Text("Próximamente")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                    .help("Llegará en la fase 2")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
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
    private var selection: Binding<Section?> {
        Binding(
            get: { model.section },
            set: { newValue in
                guard let newValue, newValue.isAvailable, newValue != model.section else { return }
                withAnimation(Theme.sectionSpring) { model.section = newValue }
            })
    }

    private var brand: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 26)
            Text("DiskMap")
                .font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// Pequeño logotipo de bloques del treemap con los colores de la paleta.
struct AppGlyph: View {
    var size: CGFloat = 26

    var body: some View {
        let gap = size * 0.07
        let radius = size * 0.12
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C1C2E), Color(hex: 0x2C2C44)],
                                     startPoint: .top, endPoint: .bottom))
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.gradient(for: .code))
                    .frame(width: size * 0.38)
                VStack(spacing: gap) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.gradient(for: .video))
                    HStack(spacing: gap) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.gradient(for: .caches))
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.gradient(for: .images))
                    }
                }
            }
            .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
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
    @ViewState private var confirmingEmpty = false
    @ViewState private var emptying = false

    var body: some View {
        let usage = model.diskUsage
        // En el primer análisis "Tus archivos" cambia cada 100 ms: cifras fijas para que se lean.
        let live = model.isScanning && model.scan == nil
        GlassCard(padding: 14, radius: 16, material: .thinMaterial) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    UsageRing(userFiles: usage.userFiles, system: usage.systemAndPurgeable, total: usage.total)
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
                    LegendRow(color: Theme.userFilesColor, title: "Tus archivos", bytes: usage.userFiles, rolls: !live)
                    LegendRow(color: Theme.systemColor, title: "Sistema y purgable", bytes: usage.systemAndPurgeable,
                              rolls: !live)
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
                    PrimaryButton("Vaciar Papelera", systemImage: "trash.slash", style: .secondary,
                                  isBusy: emptying) {
                        confirmingEmpty = true
                    }
                    .disabled(model.trashBytes == 0)

                    HStack(spacing: 6) {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(Theme.color(for: .caches))
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
        .confirmationDialog("¿Vaciar la Papelera?", isPresented: $confirmingEmpty) {
            Button(model.trashBytes.map { "Vaciar Papelera (\(Format.bytes($0)))" } ?? "Vaciar con Finder",
                   role: .destructive) {
                emptying = true
                Task {
                    await model.emptyTrash()
                    emptying = false
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if let trash = model.trashBytes {
                Text("Se borrarán definitivamente \(Format.bytes(trash)). No se puede deshacer. Si DiskMap no puede leer la Papelera, se la pedirá a Finder, que vacía también la de los discos externos.")
            } else {
                Text("DiskMap no puede leer la Papelera, así que no sabe cuánto ocupa. Se la pedirá a Finder, que la vacía definitivamente en todos los discos, también los externos. No se puede deshacer.")
            }
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let title: String
    let bytes: Int64
    /// `false` mientras el valor cambia cada 100 ms (primer análisis): cifras fijas, sin rodar.
    var rolls = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.bytes(bytes))
                .monospacedDigit()
                .contentTransition(rolls ? .numericText(value: Double(bytes)) : .identity)
        }
        .font(.caption)
        .animation(rolls ? Theme.counterSpring : nil, value: bytes)
    }
}

/// Anillo de uso: "Tus archivos" y "Sistema y purgable" sobre una pista que representa lo libre.
struct UsageRing: View {
    let userFiles: Int64
    let system: Int64
    let total: Int64
    var lineWidth: CGFloat = 9

    @ViewState private var appeared = false

    var body: some View {
        let total = Double(max(total, 1))
        let userFraction = appeared ? Double(userFiles) / total : 0
        let systemFraction = appeared ? Double(system) / total : 0
        let usedFraction = userFraction + systemFraction
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: userFraction, to: usedFraction)
                .stroke(Theme.systemColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: userFraction)
                .stroke(Theme.userFiles, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((usedFraction * 100).rounded())) %")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: usedFraction))
                Text("usado")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .animation(Theme.counterSpring, value: userFiles)
        .animation(Theme.counterSpring, value: system)
        .onAppear { withAnimation(Theme.counterSpring.delay(0.15)) { appeared = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disco: \(Format.bytes(userFiles)) tus archivos, \(Format.bytes(system)) sistema y purgable")
    }
}
