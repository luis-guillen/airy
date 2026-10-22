import SwiftUI
import DiskMapCore

/// Translucent sidebar: brand, sections, disk picker and usage card.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // No ScrollView: with it, the clickable area ended up shorter than the drawn rows
        // (the ones below Cleanup didn't respond). Eight rows always fit in the minimum height.
        VStack(alignment: .leading, spacing: 2) {
            brand
                .padding(.horizontal, -10)
                .padding(.top, 34)
                .padding(.bottom, 6)
            ForEach(Section.available) { section in
                SidebarRow(section: section, selected: model.section == section) { select(section) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    private func select(_ section: Section) {
        guard section != model.section else { return }
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

// MARK: - Section row

/// Sidebar row with its own selection in Airy blue (`List`'s uses the system accent).
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

// MARK: - Disk picker

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
                    // Redrawn every 30 s so "X ago" doesn't go stale.
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
        .help("Choose the disk to scan")
    }

    private func lastScanLine(now: Date) -> String {
        if model.isScanning && model.scan == nil { return String(localized: "Scanning…") }
        guard let date = model.lastScanDate else { return String(localized: "Not scanned") }
        return String(localized: "Scanned \(Theme.relative(date, now: now))")
    }
}

// MARK: - Disk card

private struct DiskCard: View {
    @Environment(AppModel.self) private var model
    /// Optional: without a `CleanupFlow` in the environment (standalone views, previews) it doesn't crash; the button stays disabled.
    @Environment(CleanupFlow.self) private var flow: CleanupFlow?

    var body: some View {
        let usage = model.diskUsage
        // During the first scan "Scanned" changes every 100 ms: fixed digits so it can be read.
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
                        Text("free of \(Format.bytes(usage.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .animation(Theme.counterSpring, value: usage.free)
                }

                VStack(alignment: .leading, spacing: 5) {
                    LegendRow(color: Theme.userFilesColor, title: "Scanned", bytes: usage.analyzed, rolls: !live)
                        .help("What this disk’s scan adds up to (for the startup disk it includes macOS and the apps).")
                    // If the scanned part already covers what is used, the rest can't be known: "—", never "0 kB".
                    LegendRow(color: Theme.systemColor, title: "System & Other", bytes: usage.other, rolls: !live)
                        .help(usage.other == nil
                              ? "The scan already covers all used space: there’s no remainder left to measure."
                              : "Used space the scan doesn’t see: parts of the system, other users and whatever couldn’t be read.")
                    LegendRow(color: Theme.purgeableColor, title: "Purgeable", bytes: usage.purgeable, rolls: !live)
                        .help("Space macOS frees by itself only when needed (local snapshots, purgeable caches).")
                    LegendRow(color: .primary.opacity(0.18), title: "Free", bytes: usage.free, rolls: !live)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 8) {
                    if let trash = model.trashBytes {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("In the Trash:")
                                .foregroundStyle(.secondary)
                            BytesCounter(bytes: trash, font: .callout.weight(.semibold))
                        }
                        .font(.callout)
                    } else {
                        // Without permission to read ~/.Trash, how much is there is unknown: never "0 kB".
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("In the Trash: can’t be read without Full Disk Access")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    // Enabled even if it can't be read: then Finder empties it.
                    // `CleanupFlow` opens the confirmation (what, how much and the Finder warning).
                    PrimaryButton("Empty Trash…", systemImage: "trash.slash", style: .secondary,
                                  isBusy: flow?.isEmptyingTrash ?? false) {
                        flow?.requestEmptyTrash(model)
                    }
                    .disabled(flow == nil || model.trashBytes == 0 || flow?.isRunning == true)

                    HStack(spacing: 6) {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(Theme.Airy.riskInk(.safe))
                        Text("Total freed:")
                            .foregroundStyle(.secondary)
                        if model.totalFreedKnown {
                            BytesCounter(bytes: model.totalFreed, font: .callout.weight(.semibold))
                        } else {
                            Text("—").font(.callout.weight(.semibold))
                                .help("Couldn’t read the cleanup history")
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
    let title: LocalizedStringKey
    /// `nil`: can't be known ("—").
    let bytes: Int64?
    /// `false` while the value changes every 100 ms (first scan): fixed digits, no rolling.
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

/// Usage ring: "Scanned", "System & Other" and "Purgeable" over a track that stands for free space.
/// The three parts add up to what is used (see `DiskUsageBreakdown`).
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
                Text("\(Int((used * 100).rounded()))%")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: used))
                Text("used")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .animation(Theme.counterSpring, value: usage)
        .onAppear { withAnimation(Theme.counterSpring.delay(0.15)) { appeared = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk: \(Format.bytes(usage.used)) used of \(Format.bytes(usage.total)); \(Format.bytes(usage.analyzed)) scanned, \(Format.bytes(usage.purgeable)) purgeable")
    }
}
