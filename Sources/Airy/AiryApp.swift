import AppKit
import SwiftUI
import DiskMapCore

@main
struct AiryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("Airy") {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                #if DEBUG
                .onAppear { DebugSnapshot.configure(model) }
                #endif
        }
        // Una URL `airy://` reutiliza la ventana abierta en vez de crear otra.
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de Airy") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Análisis") {
                Button("Analizar de nuevo") { model.startScan() }
                    .keyboardShortcut("r")
                Button("Detener análisis") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Un ejecutable de SwiftPM arranca como proceso sin Dock: se convierte en app normal y se trae al frente.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }

    /// Panel estándar con el crédito a Mole (GPL-3.0): se adaptan ideas y listas de rutas, no código.
    @MainActor static func showAbout() {
        let credits = NSAttributedString(
            string: "Software libre bajo GPL-3.0 · github.com/luis-guillen/airy\nAiry adapta ideas y listas de rutas de Mole (github.com/tw93/Mole, GPL-3.0). No incluye código de Mole.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "Airy", .credits: credits])
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
