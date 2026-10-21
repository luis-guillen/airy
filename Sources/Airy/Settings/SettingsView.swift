import AppKit
import SwiftUI
import DiskMapCore

/// The groups of Settings, in the order they appear.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case general, permissions, scanning, cleanup, agents, ai, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .permissions: String(localized: "Permissions")
        case .scanning: String(localized: "Scanning")
        case .cleanup: String(localized: "Cleanup")
        case .agents: String(localized: "Agents & MCP")
        case .ai: String(localized: "AI")
        case .data: String(localized: "Data")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .permissions: "lock.shield"
        case .scanning: "magnifyingglass"
        case .cleanup: "sparkles"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .ai: "brain.head.profile"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

/// Settings: the last sidebar section and the ⌘, window (the same view). Everything is saved to
/// `settings.json` as it changes; `airy-mcp` reads the same file.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Absent in the ⌘, window: then nothing is running there and Restart is always allowed.
    @Environment(CleanupFlow.self) private var flow: CleanupFlow?
    /// `true` in the ⌘, window (smaller margins, no sidebar).
    var standalone = false

    @ViewState private var restartError: String?
    @ViewState private var dataMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(title: Section.settings.title,
                                  subtitle: String(localized: "Saved as you change them. Agents connected over MCP read the same settings."))
                    GroupChips { group in
                        withAnimation(Theme.sectionSpring) { proxy.scrollTo(group.id, anchor: .top) }
                    }
                    if let notice = model.unreadableSettingsNotice { unreadableCard(notice) }

                    Group {
                        general.id(SettingsGroup.general.id)
                        permissions.id(SettingsGroup.permissions.id)
                        scanning.id(SettingsGroup.scanning.id)
                        cleanup.id(SettingsGroup.cleanup.id)
                        agents.id(SettingsGroup.agents.id)
                        ai.id(SettingsGroup.ai.id)
                    }
                    // With an unreadable `settings.json` nothing is saved over it until it is reset.
                    .disabled(model.settingsLoad.isUnreadable)
                    data.id(SettingsGroup.data.id)
                    about.id(SettingsGroup.about.id)
                }
                .padding(.horizontal, standalone ? 24 : Theme.contentPadding)
                .padding(.top, standalone ? 20 : 34)
                .padding(.bottom, model.isScanning && model.scan != nil && !standalone ? 76 : 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            #if DEBUG
            // `AIRY_SETTINGS_GROUP=<group>` (DEBUG only): opens scrolled to that group, for UI checks.
            .task {
                guard let raw = ProcessInfo.processInfo.environment["AIRY_SETTINGS_GROUP"],
                      let group = SettingsGroup(rawValue: raw) else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(group.id, anchor: .top)
            }
            #endif
        }
        // The latest from disk (another process or a hand edit) when it opens.
        .onAppear {
            model.reloadSettings()
            model.refreshSystemState()
            model.assistant.locateIfNeeded()
        }
    }

    // MARK: Unreadable

    private func unreadableCard(_ notice: String) -> some View {
        GlassCard {
            HStack(spacing: 12) {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryButton("Reset Settings", systemImage: "arrow.counterclockwise", style: .secondary) {
                    model.resetSettings()
                }
                .fixedSize()
            }
        }
    }

    // MARK: 1. General

    private var general: some View {
        SettingsCard(group: .general) {
            SettingsRow("Language", detail: "Airy’s menus, buttons and messages.") {
                Picker("Language", selection: Binding(get: { model.settings.language },
                                                      set: { model.setLanguage($0) })) {
                    Text("System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.en)
                    Text(verbatim: "Español").tag(AppLanguage.es)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.languageNeedsRestart {
                Callout(symbol: "arrow.clockwise.circle.fill",
                        text: restartError ?? String(localized: "Restart Airy to apply the new language.")) {
                    PrimaryButton("Restart Now", systemImage: "arrow.clockwise") {
                        restartError = model.relaunch(busy: flow?.isRunning == true)
                    }
                    .fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SettingsDivider()
            SettingsRow("Animations", detail: motionDetail) {
                Picker("Animations", selection: binding(\.motion)) {
                    Text("Follow System").tag(MotionPreference.system)
                    Text("Reduced").tag(MotionPreference.reduced)
                    Text("Full").tag(MotionPreference.full)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .animation(Theme.sectionSpring, value: model.languageNeedsRestart)
    }

    private var motionDetail: LocalizedStringKey {
        switch model.settings.motion {
        case .system: "Follows Reduce Motion in System Settings › Accessibility."
        case .reduced: "Only gentle fades, whatever the system says."
        case .full: "The breeze and wind effects even with Reduce Motion on."
        }
    }

    // MARK: 2. Permissions

    private var permissions: some View {
        SettingsCard(group: .permissions) {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(ok: model.hasFullDiskAccess)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hasFullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off")
                        .font(.callout.weight(.semibold))
                    Text(model.hasFullDiskAccess
                         ? "Airy can measure everything, including Mail, Messages and the Trash."
                         : "Without it some folders can’t be read, so their sizes are marked with “+”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryButton("Open Privacy Settings", systemImage: "hand.raised", style: .secondary) {
                    model.openFullDiskAccessSettings()
                }
                .fixedSize()
            }
            Text("After you turn it on in System Settings › Privacy & Security › Full Disk Access, come back to Airy and the status updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 3. Scanning

    private var scanning: some View {
        SettingsCard(group: .scanning) {
            SettingsRow("Rescan automatically on launch",
                        detail: "Off, Airy shows the last scan until you scan again (⌘R).") {
                Toggle("Rescan automatically on launch", isOn: binding(\.autoRescanOnLaunch))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow("Only if the last scan is older than", detail: "A newer scan is shown as it is.") {
                Picker("Only if the last scan is older than", selection: binding(\.rescanAge)) {
                    Text("1 hour").tag(RescanAge.oneHour)
                    Text("6 hours").tag(RescanAge.sixHours)
                    Text("24 hours").tag(RescanAge.oneDay)
                    Text("Never").tag(RescanAge.never)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!model.settings.autoRescanOnLaunch)
            SettingsDivider()
            SettingsRow("Default disk", detail: "The disk Airy opens with.") {
                Picker("Default disk", selection: binding(\.defaultVolume)) {
                    Text("Startup Disk").tag(String?.none)
                    ForEach(model.volumes.filter { !$0.isStartup }) { volume in
                        Text(volume.name).tag(Optional(volume.url.path))
                    }
                    if let saved = model.settings.defaultVolume,
                       !model.volumes.contains(where: { $0.url.path == saved }) {
                        Text("\(URL(fileURLWithPath: saved).lastPathComponent) (not connected)").tag(Optional(saved))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            PathList(title: "Excluded folders",
                     detail: "Airy never opens these folders when it scans, so their contents don’t appear in the map. Changes apply from the next scan.",
                     empty: "No excluded folders.",
                     symbol: "eye.slash",
                     paths: model.settings.excludedPaths,
                     removeHelp: "Scan This Folder Again",
                     onRemove: { model.unexclude($0) },
                     onAdd: addExcluded)
        }
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Exclude")
        panel.message = String(localized: "Airy won’t scan the folders you choose.")
        guard panel.runModal() == .OK else { return }
        model.exclude(paths: panel.urls.map(\.path))
    }

    // MARK: 4. Cleanup

    private var cleanup: some View {
        SettingsCard(group: .cleanup) {
            SettingsRow("Cleanup mode",
                        detail: model.settings.mode == .aggressive
                            ? "Also deletes what gets downloaded again or rebuilt by itself."
                            : "Only the most obvious items, with nothing marked “Your call” preselected.") {
                Picker("Cleanup mode", selection: binding(\.mode)) {
                    ForEach(CleanupMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            PathList(title: "Protected by you",
                     detail: "Airy and agents never select, clean or move these to the Trash.",
                     empty: "Nothing yet. Use “Protect This” in Map or Cleanup.",
                     symbol: "lock.fill",
                     paths: model.settings.protectedPaths,
                     removeHelp: "Stop Protecting",
                     onRemove: { model.unprotect($0) },
                     onAdd: addProtected)
        }
    }

    private func addProtected() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        panel.message = String(localized: "Airy and agents won’t touch anything you choose.")
        guard panel.runModal() == .OK else { return }
        model.protect(paths: panel.urls.map(\.path))
    }

    // MARK: 5. Agents & MCP

    private var agents: some View {
        let server = AgentsView.serverPath
        let exists = FileManager.default.isExecutableFile(atPath: server)
        return SettingsCard(group: .agents) {
            SettingsRow("Allow agents to run safe cleanups",
                        detail: "Only items marked “Safe to remove”. Everything else is always proposed to you.") {
                Toggle("Allow agents to run safe cleanups", isOn: binding(\.agentsEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("MCP server (airy-mcp)")
                    .font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    PathField(text: server)
                    CopyButton(text: server)
                }
                if !exists {
                    Label("airy-mcp wasn’t found next to Airy. Package it again with scripts/build-app.sh.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                }
            }
            HStack(spacing: 10) {
                PrimaryButton("Show Connection Instructions", systemImage: "link", style: .secondary) {
                    model.assistant.mode = .agents
                    model.section = .assistant
                    if standalone { AppModel.bringMainWindowForward() }
                }
                .fixedSize()
                PrimaryButton("Open Operation Log", systemImage: "list.bullet.rectangle", style: .secondary) {
                    model.revealDataFolder(selecting: model.paths.operationsFile)
                }
                .fixedSize()
            }
        }
    }

    // MARK: 6. AI

    private var ai: some View {
        SettingsCard(group: .ai) {
            SettingsRow("Enable AI features",
                        detail: "The assistant’s report and chat, “Explain with AI” and “Why is it slow?”. They use Claude Code on this Mac and only send paths, sizes and dates.") {
                Toggle("Enable AI features", isOn: binding(\.aiEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsDivider()
            HStack(alignment: .center, spacing: 12) {
                claudeStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryButton("Look Again", systemImage: "arrow.clockwise", style: .secondary) {
                    model.assistant.locate()
                }
                .fixedSize()
                .disabled(model.assistant.claude == .searching)
            }
        }
    }

    @ViewBuilder private var claudeStatus: some View {
        switch model.assistant.claude {
        case .unknown, .searching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for Claude Code…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .ready(let path):
            HStack(alignment: .top, spacing: 10) {
                StatusDot(ok: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code found")
                        .font(.callout.weight(.semibold))
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .missing(let chosen):
            HStack(alignment: .top, spacing: 10) {
                StatusDot(ok: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code not found")
                        .font(.callout.weight(.semibold))
                    Text(chosen.map { String(localized: "The chosen executable doesn’t respond: \($0)") }
                         ?? String(localized: "Install Claude Code to use the AI features."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: 7. Data

    private var data: some View {
        SettingsCard(group: .data) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Data folder")
                    .font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    PathField(text: Format.tildePath(model.dataFolder.path, home: NSHomeDirectory()))
                    Button("Show in Finder", systemImage: "folder") { model.revealDataFolder() }
                        .controlSize(.small)
                }
                Text("These actions only touch Airy’s own files in this folder, never yours. Each one asks first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            DataAction(title: "Delete scan index", detail: "Airy scans every disk again the next time it opens.",
                       button: "Delete Index…", symbol: "square.grid.3x3.square") {
                dataMessage = model.deleteScanIndex() ?? dataMessage
            }
            .disabled(model.isScanning)
            DataAction(title: "Clear operation log", detail: "Deletes the record of what Airy and your agents cleaned.",
                       button: "Clear Log…", symbol: "list.bullet.rectangle") {
                dataMessage = model.clearOperationLog() ?? dataMessage
            }
            DataAction(title: "Reset all settings",
                       detail: "Every setting goes back to its default. Your “Protected by you” list is kept.",
                       button: "Reset…", symbol: "arrow.counterclockwise") {
                dataMessage = model.resetAllSettings() ?? dataMessage
            }
            if let dataMessage {
                Label(dataMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(Theme.sectionSpring, value: dataMessage)
    }

    // MARK: 8. About

    private var about: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        return SettingsCard(group: .about) {
            HStack(spacing: 14) {
                AiryLogo(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Airy")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    if let version, let build {
                        Text("Version \(version) (\(build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Development build")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            SettingsDivider()
            SettingsRow("License", detail: "Free and open-source software.") {
                Link(destination: Self.licenseURL) {
                    Label { Text(verbatim: "GPL-3.0") } icon: { Image(systemName: "doc.text") }
                }
            }
            HStack(spacing: 18) {
                Link(destination: Self.repositoryURL) {
                    Label { Text(verbatim: "github.com/luis-guillen/airy") } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Link(destination: Self.issuesURL) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
            }
            .font(.callout)
            HStack(spacing: 4) {
                Text("Airy adapts ideas and path lists from Mole (GPL-3.0). It contains no Mole code.")
                Link(destination: Self.moleURL) { Text(verbatim: "github.com/tw93/Mole") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/luis-guillen/airy")!
    private static let licenseURL = URL(string: "https://github.com/luis-guillen/airy/blob/main/LICENSE")!
    private static let issuesURL = URL(string: "https://github.com/luis-guillen/airy/issues/new")!
    private static let moleURL = URL(string: "https://github.com/tw93/Mole")!

    // MARK: Bindings

    /// A setting as a binding: reads the effective value and saves every change.
    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<AirySettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Pieces

/// Row of capsules that scrolls to each group.
private struct GroupChips: View {
    var onSelect: (SettingsGroup) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(SettingsGroup.allCases) { group in
                    Chip(group: group) { onSelect(group) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private struct Chip: View {
        let group: SettingsGroup
        var action: () -> Void
        @ViewState private var hovering = false

        var body: some View {
            Button(action: action) {
                Label(group.title, systemImage: group.symbol)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.Airy.accent.opacity(hovering ? 0.18 : 0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(Theme.pressSpring) { self.hovering = hovering } }
        }
    }
}

/// One group: an icon, its title and its rows in a glass card.
private struct SettingsCard<Content: View>: View {
    let group: SettingsGroup
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: group.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(group.title)
                        .font(.headline)
                }
                content
            }
        }
    }
}

/// A title with an optional explanation on the left and its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().opacity(0.5) }
}

/// A path in a monospaced, selectable field.
private struct PathField: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Green or amber status light.
private struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.Airy.riskInk(ok ? .safe : .yourCall))
    }
}

/// An inline note with an action (e.g. "Restart now").
private struct Callout<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Airy.accent)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(10)
        .background(Theme.Airy.accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }
}

/// Editable list of folders (excluded or protected): add with a panel, remove one by one.
private struct PathList: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let empty: LocalizedStringKey
    let symbol: String
    let paths: [String]
    let removeHelp: LocalizedStringKey
    var onRemove: (String) -> Void
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryButton("Add Folder…", systemImage: "plus", style: .secondary, action: onAdd)
                    .fixedSize()
            }
            VStack(spacing: 0) {
                if paths.isEmpty {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button { onRemove(path) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(removeHelp)
                            .accessibilityLabel(Text(removeHelp))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        if path != paths.last { Divider().opacity(0.4).padding(.leading, 34) }
                    }
                }
            }
            .background(.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
    }
}

/// A Data action: what it does and its button (the confirmation alert comes from `AppModel`).
private struct DataAction: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let button: LocalizedStringKey
    let symbol: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PrimaryButton(button, style: .secondary, action: action)
                .fixedSize()
        }
    }
}
