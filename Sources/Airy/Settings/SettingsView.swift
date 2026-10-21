import AppKit
import SwiftUI
import DiskMapCore

/// Settings (⌘,): cleanup mode, agents and what the user protected. Everything is saved to
/// `settings.json`, which `airy-mcp` reads too.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let notice = model.unreadableSettingsNotice {
                SwiftUI.Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    HStack {
                        Spacer()
                        PrimaryButton("Reset Settings", systemImage: "arrow.counterclockwise", style: .secondary) {
                            model.resetSettings()
                        }
                        .fixedSize()
                    }
                }
            }

            Group {
                SwiftUI.Section {
                    Picker("Cleanup Mode", selection: modeBinding) {
                        ForEach(CleanupMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Cleanup Mode")
                } footer: {
                    Text(model.settings.mode == .aggressive
                         ? "Also deletes what gets downloaded again or rebuilt by itself."
                         : "Only the most obvious items, with nothing marked “Your call” preselected.")
                        .foregroundStyle(.secondary)
                }

                SwiftUI.Section("Agents") {
                    Toggle("Allow agents to run safe cleanups", isOn: agentsBinding)
                }

                SwiftUI.Section("Protected by You") {
                    if model.settings.protectedPaths.isEmpty {
                        Text("Nothing yet. Use “Protect This” in Map or Cleanup.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.settings.protectedPaths, id: \.self) { pattern in
                            HStack {
                                Label(pattern, systemImage: "lock.fill")
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    model.unprotect(pattern)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop Protecting")
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add Folder…", systemImage: "plus") { addFolder() }
                    }
                }
            }
            // With an unreadable `settings.json` nothing is saved over it until it is reset.
            .disabled(model.settingsLoad.isUnreadable)
        }
        .formStyle(.grouped)
        // The latest from disk (another process or a hand edit) when the window opens.
        .onAppear { model.reloadSettings() }
        .frame(width: 520)
        .frame(minHeight: 420)
    }

    private var modeBinding: Binding<CleanupMode> {
        Binding(get: { model.settings.mode }, set: { mode in model.updateSettings { $0.mode = mode } })
    }

    private var agentsBinding: Binding<Bool> {
        Binding(get: { model.settings.agentsEnabled },
                set: { enabled in model.updateSettings { $0.agentsEnabled = enabled } })
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        panel.message = String(localized: "Airy and agents won’t touch anything you choose.")
        guard panel.runModal() == .OK else { return }
        model.protect(paths: panel.urls.map(\.path))
    }
}
