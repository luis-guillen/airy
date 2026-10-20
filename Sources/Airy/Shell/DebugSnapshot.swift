#if DEBUG
import AppKit

/// Solo en Debug: captura la propia ventana a PNG para revisar la interfaz sin permiso de
/// Grabación de pantalla (una app puede capturar sus propias ventanas).
///
/// - `AIRY_SNAPSHOT_DIR`: carpeta de salida; sin ella no hace nada.
/// - `AIRY_SNAPSHOT_TIMES`: segundos tras el arranque, separados por comas (por defecto "2,6").
/// - `AIRY_SNAPSHOT_PREFIX`: prefijo del nombre (por defecto "shot").
/// - `AIRY_APPEARANCE`: "dark" o "light" para forzar el modo.
/// - `AIRY_SECTION`: sección inicial ("map", "cleanup", "assistant").
/// - `AIRY_SNAPSHOT_SHEET`: "1" recorta la captura a la hoja abierta, si la hay.
/// - `AIRY_SUPPORT_DIR` (en `AppModel`): carpeta de datos alternativa.
/// - `AIRY_REDUCE_MOTION`: "1" fuerza «Reducir movimiento» en el portero de `RootView`.
/// - `AIRY_HIDE_AT` / `AIRY_UNHIDE_AT`: segundos tras el arranque a los que la app se oculta y vuelve
///   (`NSApp.hide`/`unhide`, solo la propia app); sirven para comprobar la pausa total.
/// - `AIRY_SKIP_LAUNCH`: "1" salta la capa de arranque; también se salta con cualquier
///   `AIRY_*_SCRIPT`, para que los guiones de depuración conserven sus tiempos.
/// - `AIRY_SCAN_PREVIEW` (en `AppModel`): "1" enseña la pantalla de análisis con un progreso fijo
///   sin analizar nada (para medir sus animaciones sin recorrer el disco).
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// Reloj común de capturas y guiones de depuración (p. ej. `AIRY_MAP_SCRIPT`).
    nonisolated(unsafe) static private(set) var start = Date()
    private static var activity: NSObjectProtocol?

    /// `AIRY_REDUCE_MOTION=1`: el portero se comporta como con «Reducir movimiento».
    static var forcesReduceMotion: Bool { environment["AIRY_REDUCE_MOTION"] == "1" }

    /// `AIRY_SKIP_LAUNCH=1` o algún `AIRY_*_SCRIPT`: sin capa de arranque.
    static var skipsLaunch: Bool {
        environment["AIRY_SKIP_LAUNCH"] == "1"
            || environment.keys.contains { $0.hasPrefix("AIRY_") && $0.hasSuffix("_SCRIPT") }
    }

    /// `AIRY_SCAN_PREVIEW=1`: pantalla de análisis con progreso fijo, sin recorrer el disco.
    static var previewsScan: Bool { environment["AIRY_SCAN_PREVIEW"] == "1" }

    static func configure(_ model: AppModel) {
        start = Date()
        switch environment["AIRY_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let raw = environment["AIRY_SECTION"], let section = Section(rawValue: raw) {
            model.section = section
        }
        // Las variables nuevas se leen antes de la salida temprana de las capturas.
        let hideAt = environment["AIRY_HIDE_AT"].flatMap(Double.init)
        let unhideAt = environment["AIRY_UNHIDE_AT"].flatMap(Double.init)
        if hideAt != nil || unhideAt != nil {
            // Sin App Nap: el reloj de `unhide` llega a tiempo y la medida de CPU oculta no la rebaja
            // el sistema (lo que cuenta es que la app no anime nada, no que macOS la frene).
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Ocultar y mostrar de depuración")
        }
        if let hideAt { at(hideAt) { NSApp.hide(nil) } }
        // `unhide` no reactiva la app; antes de ocultarse era la activa, así que vuelve a serlo.
        if let unhideAt { at(unhideAt) { NSApp.unhide(nil); NSApp.activate() } }
        guard let directory = environment["AIRY_SNAPSHOT_DIR"] else { return }
        // Sin App Nap: con la ventana tapada, macOS retrasa los temporizadores y las capturas no llegan.
        activity = activity ?? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Capturas de depuración")
        let prefix = environment["AIRY_SNAPSHOT_PREFIX"] ?? "shot"
        let times = (environment["AIRY_SNAPSHOT_TIMES"] ?? "2,6")
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

    /// `CGWindowListCreateImageFromArray` (no disponible en Swift desde macOS 15, de ahí `dlsym`) sí
    /// compone materiales y capas de SwiftUI, y una app puede capturar sus propias ventanas sin permiso.
    /// Solo entran ventanas cuyo dueño es este proceso (la principal, sus hojas y sus menús), nunca las
    /// de otras apps, y la imagen se recorta al marco de la ventana principal.
    /// `cacheDisplay` queda de reserva, aunque no dibuja el contenido de SwiftUI.
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    static func capture(to url: URL) {
        let began = Date()
        defer {
            FileHandle.standardError.write(Data(String(format: "[snap] %@ a %.2f s (%.0f ms)\n", url.lastPathComponent,
                began.timeIntervalSince(start), Date().timeIntervalSince(began) * 1000).utf8))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
        else { return }
        let pid = Int(getpid())
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        // De delante hacia atrás, como las devuelve el sistema; solo las de este proceso.
        let own = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
        let ids = own.compactMap { $0[kCGWindowNumber as String] as? Int }
        // Con AIRY_SNAPSHOT_SHEET=1 y una hoja abierta, se recorta al marco de la hoja (misma
        // composición de ventanas propias; nunca entran las de otras apps).
        let target = environment["AIRY_SNAPSHOT_SHEET"] == "1" ? (window.attachedSheet ?? window) : window
        let bounds = own.first { ($0[kCGWindowNumber as String] as? Int) == target.windowNumber }
            .flatMap { $0[kCGWindowBounds as String] as! CFDictionary? }
            .flatMap { CGRect(dictionaryRepresentation: $0) }
        if ids.contains(window.windowNumber), let bounds,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") {
            let create = unsafeBitCast(symbol, to: CreateImageFromArray.self)
            var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
            // .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            if let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
               let image = create(bounds, array, (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
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
