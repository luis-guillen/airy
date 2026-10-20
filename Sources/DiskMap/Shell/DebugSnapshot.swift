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
    /// Reloj común de capturas y guiones de depuración (p. ej. `DISKMAP_MAP_SCRIPT`).
    nonisolated(unsafe) static private(set) var start = Date()
    private static var activity: NSObjectProtocol?

    static func configure(_ model: AppModel) {
        start = Date()
        switch environment["DISKMAP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let raw = environment["DISKMAP_SECTION"], let section = Section(rawValue: raw) {
            model.section = section
        }
        guard let directory = environment["DISKMAP_SNAPSHOT_DIR"] else { return }
        // Sin App Nap: con la ventana tapada, macOS retrasa los temporizadores y las capturas no llegan.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Capturas de depuración")
        let prefix = environment["DISKMAP_SNAPSHOT_PREFIX"] ?? "shot"
        let times = (environment["DISKMAP_SNAPSHOT_TIMES"] ?? "2,6")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        for time in times {
            at(time) {
                capture(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(prefix)-\(time == time.rounded() ? String(Int(time)) : String(time))s.png"))
            }
        }
    }

    /// Ejecuta `block` a `time` segundos del arranque con un `Timer` sin tolerancia: `asyncAfter` con
    /// plazos de decenas de segundos lleva segundos de holgura y las capturas llegaban tarde.
    static func at(_ time: Double, _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(fire: start.addingTimeInterval(time), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { block() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `CGWindowListCreateImage` (no disponible en Swift desde macOS 15, de ahí `dlsym`) sí compone
    /// materiales y capas de SwiftUI, y una app puede capturar sus propias ventanas sin permiso.
    /// `cacheDisplay` queda de reserva, aunque no dibuja el contenido de SwiftUI.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func capture(to url: URL) {
        let began = Date()
        defer {
            FileHandle.standardError.write(Data(String(format: "[snap] %@ a %.2f s (%.0f ms)\n", url.lastPathComponent,
                began.timeIntervalSince(start), Date().timeIntervalSince(began) * 1000).utf8))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
        else { return }
        // Con una hoja abierta: solo la ventana y su hoja (nunca ventanas de otras apps).
        if let sheet = window.attachedSheet,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") {
            typealias FromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
            let create = unsafeBitCast(symbol, to: FromArray.self)
            var ids: [UnsafeRawPointer?] = [sheet, window].map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
            if let array = CFArrayCreate(nil, &ids, ids.count, nil),
               let image = create(.null, array, (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            // Con DISKMAP_SNAPSHOT_MENUS=1 entran también las ventanas por encima (menús de la app).
            let listOption: UInt32 = environment["DISKMAP_SNAPSHOT_MENUS"] == "1" ? (1 << 1) | (1 << 3) : 1 << 3
            if let image = create(.null, listOption, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?
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
