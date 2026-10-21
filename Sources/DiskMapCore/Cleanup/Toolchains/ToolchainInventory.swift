import Foundation

public enum ToolchainLanguage: String, Sendable, CaseIterable {
    case python, node, ruby, java, rust, go, condaEnv, other

    /// Nombre para la interfaz.
    var title: String {
        switch self {
        case .python: "Python"
        case .node: "Node"
        case .ruby: "Ruby"
        case .java: "Java"
        case .rust: "Rust"
        case .go: "Go"
        case .condaEnv: "conda"
        case .other: "Otras"
        }
    }
}

/// Una versión instalada de una herramienta de desarrollo.
public struct InstalledToolchain: Sendable, Equatable {
    public var manager: ToolchainManager
    public var language: ToolchainLanguage
    /// "3.11.4", "v20.11.0", "stable-aarch64-apple-darwin", "python@3.11", "java/17.0.9-tem", nombre del entorno.
    public var name: String
    /// Carpeta de la instalación (`Cellar/<fórmula>` en Homebrew).
    public var path: String
    /// Valor de `{target}` (nombre o ruta según el gestor).
    public var target: String
    /// max(atime del ejecutable principal, mtime de la carpeta); `nil` si no se pudo leer.
    public var lastUsed: Date?
    /// /Library/…, /Applications/Xcode*.app: solo se muestran.
    public var informational: Bool

    public init(manager: ToolchainManager, language: ToolchainLanguage, name: String, path: String, target: String,
                lastUsed: Date?, informational: Bool = false) {
        self.manager = manager; self.language = language; self.name = name; self.path = path
        self.target = target; self.lastUsed = lastUsed; self.informational = informational
    }

    /// Plugin de asdf o candidato de SDKMAN (carpeta padre); `nil` en los demás gestores.
    var plugin: String? {
        switch manager {
        case .asdf: return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        case .sdkman: return name.split(separator: "/").first.map(String.init)
        default: return nil
        }
    }

    /// Versión sin el candidato de SDKMAN.
    var version: String {
        manager == .sdkman ? String(name.split(separator: "/", maxSplits: 1).last ?? Substring(name)) : name
    }
}

/// Dónde se busca (inyectable en pruebas).
public struct ToolchainRoots: Sendable {
    public var home: String
    public var cellars: [String]
    public var applications: String
    public var libraryJava: String
    public var libraryPython: String
    public var xcodeSelectLink: String

    public init(home: String, cellars: [String], applications: String, libraryJava: String, libraryPython: String,
                xcodeSelectLink: String) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.cellars = cellars; self.applications = applications; self.libraryJava = libraryJava
        self.libraryPython = libraryPython; self.xcodeSelectLink = xcodeSelectLink
    }

    public static func standard(home: String) -> ToolchainRoots {
        ToolchainRoots(home: home, cellars: ["/opt/homebrew/Cellar", "/usr/local/Cellar"],
                       applications: "/Applications", libraryJava: "/Library/Java/JavaVirtualMachines",
                       libraryPython: "/Library/Frameworks/Python.framework/Versions",
                       xcodeSelectLink: "/var/db/xcode_select_link")
    }
}

/// Inventario de solo lectura (`lstat`/`readdir`/`readlink`): nunca lanza procesos.
public enum ToolchainInventory {
    static let condaBases = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", ".conda"]
    static let fnmRoots = ["Library/Application Support/fnm", ".local/share/fnm", ".fnm"]
    static let asdfLanguages: [String: (ToolchainLanguage, String)] = [
        "nodejs": (.node, "node"), "python": (.python, "python3"), "ruby": (.ruby, "ruby"),
        "java": (.java, "java"), "golang": (.go, "go"), "rust": (.rust, "rustc"),
    ]

    /// Las entradas que son enlaces simbólicos no se ofrecen (pyenv-virtualenv, `current` de SDKMAN, `default`
    /// de rvm).
    public static func scan(_ roots: ToolchainRoots) -> [InstalledToolchain] {
        let home = roots.home
        var result: [InstalledToolchain] = []
        func add(_ manager: ToolchainManager, _ language: ToolchainLanguage, folder: String, exe: String,
                 byPath: Bool, except: Set<String> = [], name: (String) -> String = { $0 }) {
            for (entry, path) in realChildren(folder) where !except.contains(entry) {
                result.append(InstalledToolchain(
                    manager: manager, language: language, name: name(entry), path: path,
                    target: byPath ? path : name(entry), lastUsed: lastUsed(path, executable: exe)))
            }
        }
        add(.pyenv, .python, folder: home + "/.pyenv/versions", exe: "bin/python3", byPath: false)
        for base in condaBases {
            add(.conda, .condaEnv, folder: "\(home)/\(base)/envs", exe: "bin/python", byPath: true)
        }
        add(.nvm, .node, folder: home + "/.nvm/versions/node", exe: "bin/node", byPath: true)
        for root in fnmRoots {
            add(.fnm, .node, folder: "\(home)/\(root)/node-versions", exe: "installation/bin/node", byPath: false)
        }
        add(.volta, .node, folder: home + "/.volta/tools/image/node", exe: "bin/node", byPath: true)
        for (plugin, folder) in realChildren(home + "/.asdf/installs") {
            let (language, exe) = asdfLanguages[plugin] ?? (.other, plugin)
            add(.asdf, language, folder: folder, exe: "bin/" + exe, byPath: true)
        }
        add(.rbenv, .ruby, folder: home + "/.rbenv/versions", exe: "bin/ruby", byPath: false)
        add(.rvm, .ruby, folder: home + "/.rvm/rubies", exe: "bin/ruby", byPath: true, except: ["default"])
        for (candidate, folder) in realChildren(home + "/.sdkman/candidates") {
            add(.sdkman, candidate == "java" ? .java : .other, folder: folder, exe: "bin/" + candidate,
                byPath: true, except: ["current"], name: { "\(candidate)/\($0)" })
        }
        add(.rustup, .rust, folder: home + "/.rustup/toolchains", exe: "bin/rustc", byPath: false)
        for (entry, path) in realChildren(home + "/sdk") where entry.hasPrefix("go") {
            result.append(InstalledToolchain(manager: .goSDK, language: .go, name: entry, path: path, target: path,
                                             lastUsed: lastUsed(path, executable: "bin/go")))
        }
        for cellar in roots.cellars {
            for (formula, path) in realChildren(cellar) {
                guard let (language, exe) = homebrewFormula(formula) else { continue }
                let versions = realChildren(path).map(\.1)
                let used = versions.compactMap { lastUsed($0, executable: "bin/" + exe) }.max()
                let folder = modification(path)
                result.append(InstalledToolchain(manager: .homebrew, language: language, name: formula, path: path,
                                                 target: formula, lastUsed: [used, folder].compactMap { $0 }.max()))
            }
        }
        result += systemInstalls(roots)
        return result
    }

    /// Fórmulas de lenguaje de Homebrew (R6): `python@3.N`, `node`, `node@N`, `openjdk`, `openjdk@N`, `go`, `go@1.N`.
    static func homebrewFormula(_ name: String) -> (ToolchainLanguage, String)? {
        func versioned(_ prefix: String, minorOf major: String? = nil) -> Bool {
            guard name.hasPrefix(prefix + "@") else { return false }
            let version = name.dropFirst(prefix.count + 1)
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
            if let major { return parts.count == 2 && parts[0] == major }
            return parts.count == 1
        }
        if versioned("python", minorOf: "3") { return (.python, "python3") }
        if name == "node" || versioned("node") { return (.node, "node") }
        if name == "openjdk" || versioned("openjdk") { return (.java, "java") }
        if name == "go" || versioned("go", minorOf: "1") { return (.go, "go") }
        return nil
    }

    private static func systemInstalls(_ roots: ToolchainRoots) -> [InstalledToolchain] {
        var result: [InstalledToolchain] = []
        let xcodes = realChildren(roots.applications).filter {
            $0.0.hasPrefix("Xcode") && $0.0.hasSuffix(".app")
        }
        if xcodes.count >= 2 {
            for (name, path) in xcodes {
                result.append(InstalledToolchain(manager: .system, language: .other, name: name, path: path,
                                                 target: "", lastUsed: modification(path), informational: true))
            }
        }
        for (name, path) in realChildren(roots.libraryJava) where name.hasSuffix(".jdk") {
            result.append(InstalledToolchain(manager: .system, language: .java, name: name, path: path, target: "",
                                             lastUsed: modification(path), informational: true))
        }
        for (name, path) in realChildren(roots.libraryPython) where name != "Current" {
            result.append(InstalledToolchain(manager: .system, language: .python, name: name, path: path, target: "",
                                             lastUsed: modification(path), informational: true))
        }
        return result
    }

    /// Hijos que son carpetas reales (no enlaces), ordenados por nombre: (nombre, ruta).
    static func realChildren(_ folder: String) -> [(String, String)] {
        guard DiskScope.allowsWalk(folder), ProjectArtifactRules.isRealDirectory(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let path = folder + "/" + name
            return ProjectArtifactRules.isRealDirectory(path) ? (name, path) : nil
        }
    }

    /// max(atime del ejecutable, mtime de la carpeta).
    static func lastUsed(_ folder: String, executable: String) -> Date? {
        var dates: [Date] = []
        var info = stat()
        let exe = folder + "/" + executable
        if stat(exe, &info) == 0 || lstat(exe, &info) == 0 { dates.append(date(info.st_atimespec)) }
        if let folderDate = modification(folder) { dates.append(folderDate) }
        return dates.max()
    }

    static func modification(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return date(info.st_mtimespec)
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}
