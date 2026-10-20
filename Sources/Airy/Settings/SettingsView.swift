import AppKit
import SwiftUI
import DiskMapCore

/// Ajustes (⌘,): modo de limpieza, agentes y lo protegido por el usuario. Todo se guarda en
/// `settings.json`, que también lee `airy-mcp`.
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
                        PrimaryButton("Restablecer ajustes", systemImage: "arrow.counterclockwise", style: .secondary) {
                            model.resetSettings()
                        }
                        .fixedSize()
                    }
                }
            }

            Group {
                SwiftUI.Section {
                    Picker("Modo de limpieza", selection: modeBinding) {
                        ForEach(CleanupMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Modo de limpieza")
                } footer: {
                    Text(model.settings.mode == .aggressive
                         ? "Borra también lo que se vuelve a descargar o reconstruir solo."
                         : "Solo lo más evidente, sin nada «Depende de ti» preseleccionado.")
                        .foregroundStyle(.secondary)
                }

                SwiftUI.Section("Agentes") {
                    Toggle("Permitir que los agentes ejecuten limpiezas seguras", isOn: agentsBinding)
                }

                SwiftUI.Section("Protegido por ti") {
                    if model.settings.protectedPaths.isEmpty {
                        Text("Nada todavía. Usa «Proteger esto» en el Mapa o en Limpieza.")
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
                                .help("Dejar de proteger")
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Añadir carpeta…", systemImage: "plus") { addFolder() }
                    }
                }
            }
            // Con `settings.json` ilegible no se guarda nada encima hasta restablecerlo.
            .disabled(model.settingsLoad.isUnreadable)
        }
        .formStyle(.grouped)
        // Lo último del disco (otro proceso o una edición a mano) al abrir la ventana.
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
        panel.prompt = "Proteger"
        panel.message = "Airy y los agentes no tocarán nada de lo que elijas."
        guard panel.runModal() == .OK else { return }
        model.protect(paths: panel.urls.map(\.path))
    }
}
