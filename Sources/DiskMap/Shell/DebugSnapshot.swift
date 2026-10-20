#if DEBUG
import AppKit

/// Solo en Debug: captura la propia ventana a PNG para revisar la interfaz sin permiso de
/// Grabación de pantalla (una app puede capturar sus propias ventanas).
///
/// - `DISKMAP_SNAPSHOT_DIR`: carpeta de salida; sin ella no hace nada.
/// - `DISKMAP_SNAPSHOT_TIMES`: segundos tras el arranque, separados por comas (por defecto "2,6").
/// - `DISKMAP_SNAPSHOT_PREFIX`: prefijo del nombre (por defecto "shot").
/// - `DISKMAP_APPEARANCE`: "dark" o "light" para forzar el modo.
/// - `DISKMAP_SECTION`: sección inicial ("map", "cleanup", "assistant").
/// - `DISKMAP_SUPPORT_DIR` (en `AppModel`): carpeta de datos alternativa.
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func configure(_ model: AppModel) {
        switch environment["DISKMAP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let raw = environment["DISKMAP_SECTION"], let section = Section(rawValue: raw) {
            model.section = section
        }
        guard let directory = environment["DISKMAP_SNAPSHOT_DIR"] else { return }
        let prefix = environment["DISKMAP_SNAPSHOT_PREFIX"] ?? "shot"
        let times = (environment["DISKMAP_SNAPSHOT_TIMES"] ?? "2,6")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        for time in times {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                capture(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(prefix)-\(Int(time))s.png"))
            }
        }
    }

    /// `CGWindowListCreateImage` (no disponible en Swift desde macOS 15, de ahí `dlsym`) sí compone
    /// materiales y capas de SwiftUI, y una app puede capturar sus propias ventanas sin permiso.
    /// `cacheDisplay` queda de reserva, aunque no dibuja el contenido de SwiftUI.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?
                .takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
