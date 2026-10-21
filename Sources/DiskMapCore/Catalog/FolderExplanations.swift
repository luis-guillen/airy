import Foundation

/// Short explanations of well-known folders that have no catalog entry.
public enum FolderExplanations {
    private static var system: [String: String] {[
        "/Applications": String(localized: "Your applications.", bundle: .airyCore),
        "/System": String(localized: "The operating system; leave it alone.", bundle: .airyCore),
        "/Users": String(localized: "The home folders of every user on this Mac.", bundle: .airyCore),
        "/Library": String(localized: "Settings and components shared by all apps and users.", bundle: .airyCore),
        "/private": String(localized: "Internal system data: virtual memory, temporary files and logs.", bundle: .airyCore),
        "/private/var": String(localized: "Variable system data: logs, caches and virtual memory.", bundle: .airyCore),
        "/private/var/vm": String(localized: "Virtual memory and the Mac's sleep image; macOS manages it.", bundle: .airyCore),
        "/usr": String(localized: "System Unix tools and what some programs install.", bundle: .airyCore),
        "/opt": String(localized: "Software installed separately from the system.", bundle: .airyCore),
        "/opt/homebrew": String(localized: "Homebrew and the packages you have installed with it.", bundle: .airyCore),
        "/Volumes": String(localized: "External disks and mounted volumes.", bundle: .airyCore),
        "/cores": String(localized: "Memory dumps of programs that crashed.", bundle: .airyCore),
    ]}

    private static var home: [String: String] {[
        "": String(localized: "Your home folder.", bundle: .airyCore),
        "Library": String(localized: "Settings, caches and app data.", bundle: .airyCore),
        "Library/Application Support": String(localized: "Data apps keep in order to work.", bundle: .airyCore),
        "Library/Containers": String(localized: "Data of apps that run sandboxed.", bundle: .airyCore),
        "Library/Group Containers": String(localized: "Data shared by several apps from the same developer.", bundle: .airyCore),
        "Documents": String(localized: "Your documents.", bundle: .airyCore),
        "Desktop": String(localized: "What you have on your desktop.", bundle: .airyCore),
        "Downloads": String(localized: "What you have downloaded.", bundle: .airyCore),
        "Movies": String(localized: "Your videos and video projects.", bundle: .airyCore),
        "Pictures": String(localized: "Your photos, including the Photos library.", bundle: .airyCore),
        "Music": String(localized: "Your music and audio libraries.", bundle: .airyCore),
        "Applications": String(localized: "Apps installed just for your user.", bundle: .airyCore),
        ".Trash": String(localized: "The Trash: it frees no space until you empty it.", bundle: .airyCore),
    ]}

    public static func text(for path: String, home homePath: String = NSHomeDirectory()) -> String? {
        if let text = system[path] { return text }
        let base = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if path == base { return home[""] }
        guard path.hasPrefix(base + "/") else { return nil }
        return home[String(path.dropFirst(base.count + 1))]
    }
}
