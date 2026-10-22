import SwiftUI
import DiskMapCore

/// Main window: translucent sidebar and the section content under the hidden title bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var bannerDismissed = false
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.all
    /// Confirmations, cleanup batches, Trash and celebration (shared with the sidebar).
    @ViewState private var cleanupFlow = CleanupFlow()
    /// Motion gatekeeper: until the window reports, everything stays still.
    @ViewState private var windowVisible = false
    @ViewState private var appActive = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Launch layer (`LaunchSwirl`): only once per process, even if another window opens.
    @ViewState private var launching = RootView.launchPending
    static var hasPlayed = false

    private static var launchPending: Bool {
        #if DEBUG
        if DebugSnapshot.skipsLaunch { return false }
        #endif
        return !hasPlayed
    }

    private var reduceMotion: Bool {
        #if DEBUG
        if DebugSnapshot.forcesReduceMotion { return true }
        #endif
        // Settings › General › Animations: follow the system, always reduced, or full even with Reduce Motion.
        return model.settings.motion.reducesMotion(systemReduceMotion: systemReduceMotion)
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
                // The system toggle is removed, so when the sidebar is folded away this is the way back.
                .overlay(alignment: .topLeading) { showSidebarButton.ignoresSafeArea(.container, edges: .top) }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 720)
        .tint(Theme.Airy.accent)
        .foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)
        // Above everything; the scan starts at the same time (`.task` doesn't wait for it).
        .overlay { launchLayer }
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
        .task {
            #if DEBUG
            if DebugSnapshot.showsGallery { return }
            #endif
            await model.startLaunchScan()
        }
        .task(id: model.pendingURLCommand?.id) {
            if let pending = model.pendingURLCommand { await model.run(pending, flow: cleanupFlow) }
        }
    }

    private var showsGallery: Bool {
        #if DEBUG
        DebugSnapshot.showsGallery
        #else
        false
        #endif
    }

    private var showsBanner: Bool { !model.hasFullDiskAccess && !bannerDismissed }

    /// The scan error fills the screen when there is nothing to show; otherwise it goes as a notice.
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
                    NoticeBanner(notice: notice,
                                 // Unreadable settings: nothing is deleted until they are reset (asked here).
                                 resetSettings: notice.kind == .settings && model.settingsLoad.isUnreadable
                                     ? { withAnimation(Theme.sectionSpring) { model.resetSettings() } } : nil) {
                        withAnimation(Theme.sectionSpring) { model.dismiss(notice.kind) }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    if showsGallery {
                        #if DEBUG
                        MotionGallery()
                        #endif
                    } else if model.scan == nil, model.isScanning, !model.section.worksWithoutScan {
                        ScanProgressView(style: .hero)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if model.scan == nil, !model.section.worksWithoutScan, let error = model.scanError {
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
    /// A floating button next to the window controls, shown only while the sidebar is hidden.
    @ViewBuilder fileprivate var showSidebarButton: some View {
        if columnVisibility != .all {
            Button {
                withAnimation(Theme.sectionSpring) { columnVisibility = .all }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Show sidebar")
            .accessibilityLabel("Show sidebar")
            // Same row as the window controls (traffic lights), so it never covers a section title.
            .padding(.leading, 80)
            .padding(.top, 1)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    @ViewBuilder fileprivate var launchLayer: some View {
        if launching {
            LaunchSwirl { launching = false }
                .onAppear { RootView.hasPlayed = true }
        }
    }

    /// Celebration when space is freed, above the content (whether from Cleanup or the sidebar).
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

/// Content of each section.
private struct SectionContent: View {
    @Environment(AppModel.self) private var model
    let section: Section

    @ViewBuilder var body: some View {
        switch section {
        case .map:
            // Only the map's "Last scan: … ago" needs the 30 s clock; the other sections are not rebuilt by it.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                MapView(subtitle: mapSubtitle(now: context.date))
            }
        case .cleanup:
            CleanupView()
        case .performance:
            PerformanceView()
        case .assistant:
            AssistantView()
        case .largeOld:
            LargeOldView()
        case .types:
            FileTypesView()
        case .duplicates:
            DuplicatesView()
        case .uninstaller:
            UninstallerView()
        case .settings:
            SettingsView()
        }
    }

    private func mapSubtitle(now: Date) -> String {
        guard let scan = model.scan else { return String(localized: "No scan yet") }
        let scanned = String(localized: "\(Format.bytes(scan.root.allocatedSize, partial: !scan.inaccessible.isEmpty)) scanned on \(model.currentVolume.name)")
        guard let last = model.lastScanDate else { return scanned }
        return String(localized: "\(scanned) · Last scan: \(Theme.relative(last, now: now))")
    }
}

/// Dismissible notice for problems that don't block the app (failed rescan, unsaved index…).
private struct NoticeBanner: View {
    let notice: Notice
    var resetSettings: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.kind == .scan ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
            Text(notice.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let resetSettings {
                PrimaryButton("Reset Settings", systemImage: "arrow.counterclockwise", style: .secondary,
                              action: resetSettings)
                    .fixedSize()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Hide Notice")
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
            PrimaryButton("Try Again", systemImage: "arrow.clockwise") { model.startScan() }
                .fixedSize()
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}

extension Section {
    /// Sections that don't depend on the disk scan (shown even while scanning or after a failure).
    var worksWithoutScan: Bool { self == .performance || self == .settings }
}
