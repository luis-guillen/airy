#if DEBUG
import AppKit

/// Debug only: captures the app's own window to PNG to review the UI without Screen Recording
/// permission (an app can capture its own windows).
///
/// - `AIRY_SNAPSHOT_DIR`: output folder; without it, nothing happens.
/// - `AIRY_SNAPSHOT_TIMES`: seconds after launch, comma-separated (default "2,6").
/// - `AIRY_SNAPSHOT_PREFIX`: file name prefix (default "shot").
/// - `AIRY_APPEARANCE`: "dark" or "light" to force the mode.
/// - `AIRY_SECTION`: initial section ("map", "cleanup", "assistant").
/// - `AIRY_SNAPSHOT_SHEET`: "1" crops the capture to the open sheet, if any.
/// - `AIRY_SUPPORT_DIR` (in `AppModel`): alternative data folder.
/// - `AIRY_REDUCE_MOTION`: "1" forces "Reduce motion" in `RootView`'s gatekeeper.
/// - `AIRY_HIDE_AT` / `AIRY_UNHIDE_AT`: seconds after launch at which the app hides and comes back
///   (`NSApp.hide`/`unhide`, only the app itself); used to check the full pause.
/// - `AIRY_SKIP_LAUNCH`: "1" skips the launch layer; it is also skipped with any
///   `AIRY_*_SCRIPT`, so debug scripts keep their timings.
/// - `AIRY_SCAN_PREVIEW` (in `AppModel`): "1" shows the scan screen with fixed progress
///   without scanning anything (to measure its animations without walking the disk).
/// - `AIRY_MOTION_GALLERY`: "1" replaces the content with the motion gallery (`MotionGallery`) and
///   doesn't scan the disk.
/// - `AIRY_GALLERY_AUTOPLAY`: seconds after launch at which the gallery presses "Simulate Deletion" by itself.
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// Shared clock for captures and debug scripts (e.g. `AIRY_MAP_SCRIPT`).
    nonisolated(unsafe) static private(set) var start = Date()
    private static var activity: NSObjectProtocol?

    /// `AIRY_REDUCE_MOTION=1`: the gatekeeper behaves as with "Reduce motion".
    static var forcesReduceMotion: Bool { environment["AIRY_REDUCE_MOTION"] == "1" }

    /// `AIRY_SKIP_LAUNCH=1` or some `AIRY_*_SCRIPT`: no launch layer.
    static var skipsLaunch: Bool {
        environment["AIRY_SKIP_LAUNCH"] == "1"
            || environment.keys.contains { $0.hasPrefix("AIRY_") && $0.hasSuffix("_SCRIPT") }
    }

    /// `AIRY_SCAN_PREVIEW=1`: scan screen with fixed progress, without walking the disk.
    static var previewsScan: Bool { environment["AIRY_SCAN_PREVIEW"] == "1" }

    /// `AIRY_MOTION_GALLERY=1`: motion gallery instead of the section, without scanning the disk.
    static var showsGallery: Bool { environment["AIRY_MOTION_GALLERY"] == "1" }

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
        // The new variables are read before the captures' early exit.
        let hideAt = environment["AIRY_HIDE_AT"].flatMap(Double.init)
        let unhideAt = environment["AIRY_UNHIDE_AT"].flatMap(Double.init)
        if hideAt != nil || unhideAt != nil {
            // No App Nap: the `unhide` timer fires on time and the system doesn't lower the hidden CPU
            // measurement (what counts is that the app animates nothing, not that macOS throttles it).
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Debug hide and show")
        }
        if let hideAt { at(hideAt) { NSApp.hide(nil) } }
        // `unhide` doesn't reactivate the app; it was active before hiding, so it becomes active again.
        if let unhideAt { at(unhideAt) { NSApp.unhide(nil); NSApp.activate() } }
        guard let directory = environment["AIRY_SNAPSHOT_DIR"] else { return }
        // No App Nap: with the window covered, macOS delays timers and the captures never arrive.
        activity = activity ?? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Debug captures")
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

    /// Runs `block` `time` seconds after launch with a zero-tolerance `Timer`: `asyncAfter` with
    /// delays of tens of seconds carries seconds of slack and the captures arrived late.
    static func at(_ time: Double, _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(fire: start.addingTimeInterval(time), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { block() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `CGWindowListCreateImageFromArray` (unavailable in Swift since macOS 15, hence `dlsym`) does
    /// composite SwiftUI materials and layers, and an app can capture its own windows without permission.
    /// Only windows owned by this process are included (the main one, its sheets and its menus), never
    /// other apps', and the image is cropped to the main window's frame.
    /// `cacheDisplay` stays as a fallback, although it doesn't draw SwiftUI content.
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    static func capture(to url: URL) {
        let began = Date()
        defer {
            FileHandle.standardError.write(Data(String(format: "[snap] %@ at %.2f s (%.0f ms)\n", url.lastPathComponent,
                began.timeIntervalSince(start), Date().timeIntervalSince(began) * 1000).utf8))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
        else { return }
        let pid = Int(getpid())
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        // Front to back, as the system returns them; only this process's.
        let own = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
        let ids = own.compactMap { $0[kCGWindowNumber as String] as? Int }
        // With AIRY_SNAPSHOT_SHEET=1 and a sheet open, it is cropped to the sheet's frame (same
        // composition of own windows; other apps' windows never get in).
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
