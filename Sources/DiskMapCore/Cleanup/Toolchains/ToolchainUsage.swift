import Foundation

/// Una versión pedida (por defecto de un gestor o en un archivo de un proyecto).
public struct VersionPin: Sendable, Equatable {
    public var language: ToolchainLanguage
    /// Tal cual, sin espacios.
    public var raw: String
    /// "~/Projects/app/.nvmrc" o "pyenv global".
    public var source: String
    /// `false`: "lts/*", "node", "latest", "system", "stable"/"nightly" sin toolchain de ese canal…
    public var resolvable: Bool

    public init(language: ToolchainLanguage, raw: String, source: String, resolvable: Bool = true) {
        self.language = language; self.raw = raw; self.source = source; self.resolvable = resolvable
    }

    static let rustChannels: Set<String> = ["stable", "beta", "nightly"]

    /// Prefijo por componentes numéricos (R4): `3.11` pide `3.11.x`; `3.1` no pide `3.11.0`.
    public func matches(_ install: InstalledToolchain) -> Bool {
        guard install.language == language, !raw.isEmpty else { return false }
        if language == .condaEnv {
            if raw.hasPrefix("/") { return RiskPolicy.canonical(raw) == RiskPolicy.canonical(install.path) }
            return (install.path as NSString).lastPathComponent == raw
        }
        if language == .rust {
            let pin = Self.stripRustHost(Self.normalize(raw))
            let installed = Self.stripRustHost(install.name)
            if Self.rustChannels.contains(pin) { return installed == pin || installed.hasPrefix(pin + "-") }
            return installed == pin || Self.componentPrefix(pin, of: installed)
        }
        let pin = Self.normalize(raw)
        return Self.installedVersions(install).contains { Self.componentPrefix(pin, of: Self.normalize($0)) }
    }

    static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["java/", "ruby-", "python-", "v"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasPrefix("go"), value.dropFirst(2).first?.isNumber == true { value = String(value.dropFirst(2)) }
        return value
    }

    static func stripRustHost(_ name: String) -> String {
        for host in ["-aarch64-apple-darwin", "-x86_64-apple-darwin"] where name.hasSuffix(host) {
            return String(name.dropLast(host.count))
        }
        return name
    }

    /// Versiones con las que se compara: el nombre (sin candidato de SDKMAN); en Homebrew, `python@3.11` ⇒ `3.11`
    /// y una fórmula sin `@` ⇒ sus carpetas de versión.
    static func installedVersions(_ install: InstalledToolchain) -> [String] {
        guard install.manager == .homebrew else { return [install.version] }
        if let at = install.name.firstIndex(of: "@") { return [String(install.name[install.name.index(after: at)...])] }
        return ToolchainInventory.realChildren(install.path).map(\.0)
    }

    static func componentPrefix(_ pin: String, of installed: String) -> Bool {
        let p = pin.split(separator: ".", omittingEmptySubsequences: false)
        let i = installed.split(separator: ".", omittingEmptySubsequences: false)
        guard !p.isEmpty, p.count <= i.count else { return false }
        return zip(p, i).allSatisfy { $0 == $1 }
    }
}

/// Qué versiones están en uso o pedidas.
public struct UsageReport: Sendable {
    /// `InstalledToolchain.path` → motivo («Es la versión por defecto de pyenv.», «La usa el PATH (node).»…).
    public var defaults: [String: String]
    /// path → «La pide ~/Projects/app (.nvmrc).»
    public var requested: [String: String]
    /// Pin no resoluble o lista de proyectos incompleta.
    public var noPreselect: Set<ToolchainLanguage>
    public var projectsComplete: Bool

    public init(defaults: [String: String] = [:], requested: [String: String] = [:],
                noPreselect: Set<ToolchainLanguage> = [], projectsComplete: Bool = true) {
        self.defaults = defaults; self.requested = requested; self.noPreselect = noPreselect
        self.projectsComplete = projectsComplete
    }
}

/// Versión por defecto de cada gestor, PATH y pins de proyecto. Solo se leen archivos (y `runner.resolve`); nunca
/// se ejecuta ninguna orden.
public enum ToolchainUsage {
    static let pinFiles = [".nvmrc", ".node-version", ".python-version", ".tool-versions", "rust-toolchain",
                           "rust-toolchain.toml", ".ruby-version", "environment.yml"]
    static let pathExecutables: [ToolchainLanguage: [String]] = [.python: ["python3", "python"], .node: ["node"],
        .ruby: ["ruby"], .java: ["java"], .rust: ["rustc", "cargo"], .go: ["go"]]
    static let maxPinFileBytes = 64 * 1024
    static let asdfPlugins: [String: ToolchainLanguage] = [
        "nodejs": .node, "python": .python, "ruby": .ruby, "java": .java, "golang": .go, "rust": .rust,
    ]
    static let unresolvableWords: Set<String> = ["node", "latest", "system", "stable", "lts", "current", "default",
                                                 "nightly", "beta"]

    public static func report(installs: [InstalledToolchain], roots: ToolchainRoots, projects: ProjectList,
                              runner: any CommandRunning) async -> UsageReport {
        var report = UsageReport(projectsComplete: projects.complete)
        let home = roots.home
        let offered = installs.filter { !$0.informational }
        func of(_ manager: ToolchainManager) -> [InstalledToolchain] { offered.filter { $0.manager == manager } }
        func mark(_ install: InstalledToolchain, _ reason: String) {
            if report.defaults[install.path] == nil { report.defaults[install.path] = reason }
        }
        /// Default que no se resuelve: la más alta del gestor cuenta como por defecto y su lenguaje no se marca.
        func unresolved(_ manager: ToolchainManager) {
            let list = of(manager)
            guard let highest = list.max(by: { versionLess($0.version, $1.version) }) else { return }
            mark(highest, defaultReason(manager))
            report.noPreselect.insert(highest.language)
        }
        /// Instalaciones del gestor cuya carpeta contiene `real` (destino de un enlace).
        func owner(_ manager: ToolchainManager, containing real: String) -> InstalledToolchain? {
            let canonical = RiskPolicy.canonical(real)
            return of(manager).first {
                let root = RiskPolicy.canonical(CleanupTargets.realPath($0.path) ?? $0.path)
                return canonical == root || RiskPolicy.isInside(canonical, root: root)
            }
        }
        /// Una versión por nombre: la más alta que coincide.
        func byVersion(_ manager: ToolchainManager, _ raw: String) -> InstalledToolchain? {
            let list = of(manager)
            guard let language = list.first?.language else { return nil }
            let pin = VersionPin(language: language, raw: raw, source: "")
            return list.filter(pin.matches).max(by: { versionLess($0.version, $1.version) })
        }
        func linkTarget(_ link: String) -> String? {
            guard isSymlink(link) else { return nil }
            return CleanupTargets.realPath(link)
        }
        /// Una línea de `.python-version` como la resuelve pyenv: `~/.pyenv/versions/<línea>` (enlace de
        /// pyenv-virtualenv `myenv` o ruta larga `3.11.4/envs/myenv`) dentro de una versión base; si no existe,
        /// el primer componente de una ruta `<ver>/envs/<nombre>`.
        func pyenvOwner(_ line: String) -> InstalledToolchain? {
            guard !line.isEmpty, !line.hasPrefix("/") else { return nil }
            let entry = home + "/.pyenv/versions/" + line
            if ProjectArtifactRules.exists(entry), let real = CleanupTargets.realPath(entry),
               let install = owner(.pyenv, containing: real) {
                return install
            }
            if let range = line.range(of: "/envs/") {
                let base = String(line[..<range.lowerBound])
                return of(.pyenv).first { $0.name == base }
            }
            return nil
        }

        // pyenv: ~/.pyenv/version (todas sus líneas).
        if let text = read(home + "/.pyenv/version") {
            for line in lines(text) where line != "system" {
                let entry = home + "/.pyenv/versions/" + line
                if let real = linkTarget(entry), let install = owner(.pyenv, containing: real) {
                    mark(install, defaultReason(.pyenv))
                } else if line.contains("/"), let install = pyenvOwner(line) {
                    mark(install, defaultReason(.pyenv))
                } else if let install = of(.pyenv).first(where: { $0.name == line }) {
                    mark(install, defaultReason(.pyenv))
                } else {
                    unresolved(.pyenv)
                }
            }
        }
        // nvm: alias default, siguiendo alias hasta 3 saltos.
        if var value = read(home + "/.nvm/alias/default").flatMap({ lines($0).first }) {
            for _ in 0..<3 {
                guard let next = read(home + "/.nvm/alias/" + value).flatMap({ lines($0).first }) else { break }
                value = next
            }
            if value != "system" {
                if ["node", "stable"].contains(value),
                   let highest = of(.nvm).max(by: { versionLess($0.version, $1.version) }) {
                    mark(highest, defaultReason(.nvm))
                } else if !isUnresolvableWord(value), let install = byVersion(.nvm, value) {
                    mark(install, defaultReason(.nvm))
                } else {
                    unresolved(.nvm)
                }
            }
        }
        // fnm: realpath de <fnm>/aliases/default.
        for root in ToolchainInventory.fnmRoots {
            let link = "\(home)/\(root)/aliases/default"
            guard ProjectArtifactRules.exists(link) else { continue }
            if let real = CleanupTargets.realPath(link), let install = owner(.fnm, containing: real) {
                mark(install, defaultReason(.fnm))
            } else {
                unresolved(.fnm)
            }
        }
        // volta: node.runtime de platform.json.
        if let data = FileManager.default.contents(atPath: home + "/.volta/tools/user/platform.json") {
            let runtime = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["node"] as? [String: Any] }?["runtime"] as? String
            if let runtime, let install = of(.volta).first(where: { VersionPin.normalize($0.name) == VersionPin.normalize(runtime) }) {
                mark(install, defaultReason(.volta))
            } else {
                unresolved(.volta)
            }
        }
        // asdf: ~/.tool-versions.
        if let text = read(home + "/.tool-versions") {
            for (plugin, versions) in toolVersions(text) {
                for version in versions where version != "system" {
                    if let install = of(.asdf).first(where: { $0.plugin == plugin && $0.name == version }) {
                        mark(install, defaultReason(.asdf))
                    } else if of(.asdf).contains(where: { $0.plugin == plugin }) {
                        unresolved(.asdf)
                    }
                }
            }
        }
        // rbenv: ~/.rbenv/version.
        if let line = read(home + "/.rbenv/version").flatMap({ lines($0).first }), line != "system" {
            if let install = of(.rbenv).first(where: { $0.name == line }) {
                mark(install, defaultReason(.rbenv))
            } else {
                unresolved(.rbenv)
            }
        }
        // rvm: realpath de ~/.rvm/rubies/default.
        let rvmDefault = home + "/.rvm/rubies/default"
        if ProjectArtifactRules.exists(rvmDefault) {
            if let real = CleanupTargets.realPath(rvmDefault), let install = owner(.rvm, containing: real) {
                mark(install, defaultReason(.rvm))
            } else {
                unresolved(.rvm)
            }
        }
        // SDKMAN: realpath de candidates/<c>/current.
        for (_, folder) in ToolchainInventory.realChildren(home + "/.sdkman/candidates") {
            let current = folder + "/current"
            guard ProjectArtifactRules.exists(current) else { continue }
            if let real = CleanupTargets.realPath(current), let install = owner(.sdkman, containing: real) {
                mark(install, defaultReason(.sdkman))
            } else {
                unresolved(.sdkman)
            }
        }
        // rustup: default_toolchain y [overrides] de settings.toml.
        if let text = read(home + "/.rustup/settings.toml") {
            var section = ""
            for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { section = trimmed; continue }
                guard let (key, value) = tomlPair(trimmed) else { continue }
                guard (section.isEmpty && key == "default_toolchain") || section == "[overrides]" else { continue }
                let pin = VersionPin(language: .rust, raw: value, source: "rustup")
                let matches = of(.rustup).filter(pin.matches)
                if matches.isEmpty { unresolved(.rustup) }
                for install in matches { mark(install, defaultReason(.rustup)) }
            }
        }
        // Xcode activo.
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: roots.xcodeSelectLink) {
            let canonical = RiskPolicy.canonical(destination)
            for install in installs where install.manager == .system && install.name.hasPrefix("Xcode")
                && RiskPolicy.isInside(canonical, root: RiskPolicy.canonical(install.path)) {
                mark(install, "Xcode activo (xcode-select).")
            }
        }
        // PATH: el ejecutable resuelto (y su destino real) dentro de una instalación.
        for (_, executables) in pathExecutables.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for executable in executables {
                guard let resolved = await runner.resolve(executable) else { continue }
                let real = RiskPolicy.canonical(CleanupTargets.realPath(resolved) ?? resolved)
                for install in installs {
                    let root = RiskPolicy.canonical(CleanupTargets.realPath(install.path) ?? install.path)
                    if RiskPolicy.isInside(real, root: root) { mark(install, "La usa el PATH (\(executable)).") }
                }
            }
        }
        // nvm sin alias por defecto y con varias versiones: la que elige la shell (`nvm use` en .zshrc) no se ve
        // (y el PATH de la app nunca lleva el node de nvm). Va después del PATH para no tapar su motivo.
        if read(home + "/.nvm/alias/default") == nil, of(.nvm).count > 1 { unresolved(.nvm) }
        // Java: el ejecutable del PATH es el stub de /usr/bin y `JAVA_HOME` no se ve desde la app; la que se usa
        // puede no detectarse, así que Java nunca se preselecciona.
        if offered.contains(where: { $0.language == .java }) { report.noPreselect.insert(.java) }

        // Pins de los proyectos.
        if !projects.complete { report.noPreselect.formUnion(ToolchainLanguage.allCases) }
        for project in projects.projects {
            for pin in pins(inProject: project, home: home) {
                let file = (pin.source as NSString).lastPathComponent
                let folder = (pin.source as NSString).deletingLastPathComponent
                // pyenv-virtualenv (I1): el entorno vive dentro de su versión base; esa base queda pedida.
                if pin.language == .python, file == ".python-version", pin.raw.contains("/") || !pin.resolvable {
                    if let install = pyenvOwner(pin.raw) {
                        if report.requested[install.path] == nil {
                            report.requested[install.path] = "La pide \(folder) (\(file))."
                        }
                        report.noPreselect.insert(.python)
                        continue
                    }
                    if pin.raw.contains("/") {
                        report.noPreselect.insert(.python)
                        continue
                    }
                }
                let matches = offered.filter(pin.matches)
                if !pin.resolvable || (pin.language == .rust && VersionPin.rustChannels.contains(pin.raw)
                                       && matches.isEmpty) {
                    report.noPreselect.insert(pin.language)
                    continue
                }
                for install in matches where report.requested[install.path] == nil {
                    report.requested[install.path] = "La pide \(folder) (\(file))."
                }
            }
        }
        return report
    }

    static func defaultReason(_ manager: ToolchainManager) -> String {
        let names: [ToolchainManager: String] = [.volta: "Volta", .sdkman: "SDKMAN"]
        return "Es la versión por defecto de \(names[manager] ?? manager.rawValue)."
    }

    static func pins(inProject root: String) -> [VersionPin] { pins(inProject: root, home: NSHomeDirectory()) }

    /// Raíz y sus hijos directos (R4); los archivos de más de 64 KB se ignoran.
    static func pins(inProject root: String, home: String) -> [VersionPin] {
        var folders = [root]
        folders += ToolchainInventory.realChildren(root).map(\.1).filter {
            !ProjectArtifactRules.signalExcluded.contains(($0 as NSString).lastPathComponent)
        }
        var result: [VersionPin] = []
        for folder in folders {
            for file in pinFiles {
                let path = folder + "/" + file
                guard let text = read(path) else { continue }
                let source = Format.tildePath(path, home: home)
                result += parse(file: file, text: text, source: source)
            }
        }
        return result
    }

    static func parse(file: String, text: String, source: String) -> [VersionPin] {
        func pin(_ language: ToolchainLanguage, _ raw: String) -> VersionPin {
            VersionPin(language: language, raw: raw, source: source, resolvable: !isUnresolvableWord(raw))
        }
        switch file {
        case ".nvmrc", ".node-version":
            return lines(text).prefix(1).map { pin(.node, $0) }
        case ".python-version":
            return lines(text).map { pin(.python, $0) }
        case ".ruby-version":
            return lines(text).prefix(1).map { pin(.ruby, $0) }
        case ".tool-versions":
            return toolVersions(text).flatMap { plugin, versions in
                versions.map { pin(asdfPlugins[plugin] ?? .other, $0) }
            }
        case "rust-toolchain", "rust-toolchain.toml":
            let pairs = text.split(whereSeparator: \.isNewline).compactMap {
                tomlPair($0.trimmingCharacters(in: .whitespaces))
            }
            if let channel = pairs.first(where: { $0.0 == "channel" })?.1 {
                return [VersionPin(language: .rust, raw: channel, source: source)]
            }
            if file == "rust-toolchain", let line = lines(text).first, !line.contains("=") {
                return [VersionPin(language: .rust, raw: line, source: source)]
            }
            return []
        case "environment.yml":
            for line in text.split(whereSeparator: \.isNewline) {
                for key in ["name:", "prefix:"] where line.hasPrefix(key) {
                    var value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty { return [VersionPin(language: .condaEnv, raw: value, source: source)] }
                }
            }
            return []
        default:
            return []
        }
    }

    static func isUnresolvableWord(_ raw: String) -> Bool {
        let value = raw.lowercased()
        return value.isEmpty || value.hasPrefix("lts") || unresolvableWords.contains(value)
            || !(value.first?.isNumber ?? false) && !value.hasPrefix("v") && !value.hasPrefix("ruby-")
                && !value.hasPrefix("python-") && !value.hasPrefix("go") && !value.hasPrefix("java/")
    }

    /// `plugin v1 v2` por línea (sin comentarios).
    static func toolVersions(_ text: String) -> [(String, [String])] {
        lines(text).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return (parts[0], Array(parts.dropFirst()))
        }
    }

    /// `^\s*([^=]+?)\s*=\s*"(.*)"\s*$`
    static func tomlPair(_ line: String) -> (String, String)? {
        guard let equal = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return (key, String(value.dropFirst().dropLast()))
    }

    /// Líneas sin espacios, sin vacías ni comentarios.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Fichero normal de como mucho 64 KB, como texto.
    static func read(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxPinFileBytes,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Orden numérico por componentes (`v18.9` < `v18.10`).
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = numbers(VersionPin.normalize(a)), y = numbers(VersionPin.normalize(b))
        for (p, q) in zip(x, y) where p != q { return p < q }
        return x.count < y.count
    }

    private static func numbers(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
