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
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Análisis") {
                Button("Analizar de nuevo") { model.startScan() }
                    .keyboardShortcut("r")
                Button("Detener análisis") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
