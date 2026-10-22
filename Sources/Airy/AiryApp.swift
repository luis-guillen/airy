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
        // An `airy://` URL reuses the open window instead of creating another.
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Airy") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Scan") {
                Button("Scan Again") { model.startScan() }
                    .keyboardShortcut("r")
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
        }

        // ⌘,: the same view as the sidebar's Settings section.
        Settings {
            SettingsView(standalone: true)
                .environment(model)
                .tint(Theme.Airy.accent)
                .foregroundStyle(Theme.Airy.text, Theme.Airy.textSecondary, Theme.Airy.textSecondary)
                .frame(width: 680, height: 760)
                .background(Theme.Airy.background)
        }
    }
}

/// A SwiftPM executable starts as a process without a Dock icon: turn it into a regular app and bring it to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.dropNarrowSidebarState()
    }

    /// AppKit restores the split view's saved column widths, and it can restore one below the sidebar's
    /// minimum (a stale or dragged value), which truncates every label. Forget any saved width under the minimum
    /// before the window is built, so the sidebar always opens at its normal width.
    static let sidebarMinimumWidth: Double = 250

    static func dropNarrowSidebarState(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames") {
            guard let frames = defaults.stringArray(forKey: key), let first = frames.first else { continue }
            // Each entry is "x, y, width, height, hidden, ..."; the first subview is the sidebar.
            let parts = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let width = Double(parts[2]), width < sidebarMinimumWidth {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }

    /// Standard panel with the credit to Mole (GPL-3.0): ideas and path lists are adapted, not code.
    @MainActor static func showAbout() {
        let credits = NSAttributedString(
            string: String(localized: "Open source under the GPL-3.0 license · github.com/luis-guillen/airy\nAiry adapts ideas and path lists from Mole (github.com/tw93/Mole, GPL-3.0). It contains no Mole code."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "Airy", .credits: credits])
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
