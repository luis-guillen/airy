import Foundation

/// Identidad de una entrada en disco (sin seguir el último enlace) y de su carpeta padre.
public struct FileIdentity: Sendable, Equatable {
    public let device: UInt64, inode: UInt64, parentDevice: UInt64, parentInode: UInt64, isSymlink: Bool
}

/// Ruta que pasó la validación: sus formas canónicas comprobadas y su identidad en ese momento.
public struct ValidatedPath: Sendable, Equatable {
    public let path: String
    public let forms: [String]
    public let identity: FileIdentity
}

public struct PathRefusal: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Dispensa acotada que solo construye el embudo de desinstalación: deja pasar el `.app` exacto que se
/// desinstala (con su `CFBundleIdentifier` comprobado al validar) y las carpetas de datos sensibles (capa C)
/// de esa misma app. Nunca dispensa raíces críticas, selladas del home, carpetas superiores, fragmentos de
/// datos, la lista del usuario ni las reglas del catálogo.
public struct ProtectionWaiver: Sendable, Equatable {
    /// Ruta canónica del `.app`.
    public let bundlePath: String
    public let bundleID: String
    /// En minúsculas: `bundleID`, `helperBundleIDs` y `AppInventory.nameVariants(name)`.
    public let ownedNames: [String]
    /// La ruta tal cual se eligió (solo esa cuenta como el `.app`, sin variantes de mayúsculas).
    let appPath: String
    /// Raíz de apps (canónica) de la que cuelga; solo su ubicación sellada se dispensa para el `.app`.
    let appRoot: String

    /// Solo `uninstall(_:appRoots:)` construye una dispensa.
    private init(bundlePath: String, bundleID: String, ownedNames: [String], appPath: String, appRoot: String) {
        self.bundlePath = bundlePath; self.bundleID = bundleID; self.ownedNames = ownedNames
        self.appPath = appPath; self.appRoot = appRoot
    }

    /// `nil` (no hay dispensa) si: app.isSystem; id con prefijo de officialUninstallerPrefixes; id con prefijo
    /// "local.airy."; o app.path no cuelga de un elemento de `appRoots` a profundidad 1 o 2.
    /// Solo valen raíces cuyo último componente es `Applications` (`/Applications`, `~/Applications` o, en
    /// DEBUG, una carpeta temporal `…/Applications`). No se fía de `app.isSystem`: lo recalcula con la ruta
    /// resuelta y con el identificador que hay ahora en disco.
    public static func uninstall(_ app: AppRecord, appRoots: [String]) -> ProtectionWaiver? {
        let id = app.bundleID.lowercased()
        guard !app.isSystem, !id.isEmpty, !isRefusedID(id),
              PathGate.syntaxRefusal(app.path) == nil, app.path.lowercased().hasSuffix(".app") else { return nil }
        let path = RiskPolicy.canonical(app.path)
        let parts = HardProtections.components(path)
        let root = appRoots.lazy.map(RiskPolicy.canonical).first { root in
            let depth = parts.count - HardProtections.components(root).count
            return isAppRoot(root) && RiskPolicy.isInside(path, root: root) && (1...2).contains(depth)
        }
        guard let root, let resolved = resolvedPath(app.path),
              !AppInventory.isSystemApp(path: resolved, bundleID: app.bundleID) else { return nil }
        if let onDisk = AppInventory.bundleIdentifier(ofApp: app.path),
           AppInventory.isSystemApp(path: resolved, bundleID: onDisk) || isRefusedID(onDisk.lowercased()) {
            return nil
        }
        var owned: [String] = []
        for name in [app.bundleID] + app.helperBundleIDs + AppInventory.nameVariants(app.name) {
            let lower = name.lowercased()
            if !lower.isEmpty, !owned.contains(lower) { owned.append(lower) }
        }
        return ProtectionWaiver(bundlePath: path, bundleID: app.bundleID, ownedNames: owned, appPath: app.path,
                                appRoot: root)
    }

    public static func productionAppRoots(home: String) -> [String] { ["/Applications", home + "/Applications"] }

    /// Airy y las apps con desinstalador oficial (id en minúsculas).
    private static func isRefusedID(_ id: String) -> Bool {
        id.hasPrefix("local.airy.") || AppInventory.officialUninstallerPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Raíz canónica cuyo último componente es `applications`.
    private static func isAppRoot(_ root: String) -> Bool {
        HardProtections.components(root).last == "applications"
    }

    /// Ruta real del `.app` (o, si aún no existe, la de su carpeta padre más su nombre); `nil` si no se resuelve.
    private static func resolvedPath(_ path: String) -> String? {
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        if let full = real(path) { return full }
        guard let parent = real((path as NSString).deletingLastPathComponent) else { return nil }
        return parent + "/" + (path as NSString).lastPathComponent
    }

    static let bundleChanged = "Ya no es la app que elegiste."

    /// `true` si el `.app` (que no es un enlace) tiene ahora mismo `CFBundleIdentifier == bundleID`, leído
    /// como lo lee el inventario (también apps de iOS envueltas en `Wrapper/*.app`).
    func bundleStillMatches(identity: FileIdentity) -> Bool {
        guard !identity.isSymlink, let id = AppInventory.bundleIdentifier(ofApp: appPath) else { return false }
        return id == bundleID
    }

    /// `true` si la dispensa cubre esta coincidencia de la lista dura. `isBundle`: la ruta es el `.app` exacto;
    /// `form`: la forma canónica comprobada; `home`: la forma del home con la que se comprobó.
    func waives(_ match: ProtectionMatch, form: String, isBundle: Bool, home: String) -> Bool {
        guard match.source == .airy else { return false }
        if isBundle {
            switch match.rule {
            case .sealedSystem:
                // Solo el sello de la propia raíz de apps (en la práctica, `/Applications`).
                let pattern = RiskPolicy.canonical(match.pattern)
                return pattern == appRoot && Self.isAppRoot(pattern)
            case .fragment:
                // Solo si el fragmento está en el nombre del `.app`, no en una carpeta superior.
                let fragment = match.pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                let parts = HardProtections.components(form)
                guard let last = parts.last, !fragment.isEmpty else { return false }
                return last.contains(fragment) && !parts.dropLast().contains { $0.contains(fragment) }
            default:
                return false
            }
        }
        // Otra ruta: solo la carpeta de datos sensibles en sí, y solo si es de esta app.
        guard match.rule == .sensitiveAppData, match.pattern.hasPrefix("~/") else { return false }
        let folder = RiskPolicy.canonical((home == "/" ? "" : home) + match.pattern.dropFirst(1))
        guard folder == form, var last = HardProtections.components(form).last else { return false }
        for suffix in [".savedstate", ".plist", ".binarycookies"] where last.hasSuffix(suffix) {
            last.removeLast(suffix.count)
            break
        }
        return last == bundleID.lowercased() || ownedNames.contains(last)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Embudo de validación de rutas antes de cualquier acción destructiva: sintaxis, existencia, formas
/// canónicas (texto, padre resuelto, destino del enlace), lista dura de Airy, lista del usuario, reglas
/// del catálogo e identidad `(st_dev, st_ino)` frente a las raíces críticas y el home.
public struct PathGate: Sendable {
    private struct InodeKey: Hashable, Sendable { let device: UInt64, inode: UInt64 }

    private let home: String
    /// Home canónico literal y resuelto (si difiere).
    private let homeForms: [String]
    private let catalog: Catalog?
    private let userProtected: ProtectList
    private let protections: HardProtections
    /// Solo para el `{target}` de una orden: la ficha cuya ruta declarada vale como excepción de la capa C.
    private let commandTarget: CatalogEntry?
    /// Inodo → raíz crítica (o home) a la que pertenece; calculado una vez con `stat`.
    private let criticalInodes: [InodeKey: String]
    /// Inodo de `/Users`: ninguna carpeta directamente dentro se borra.
    private let usersInode: InodeKey?

    public init(home: String, catalog: Catalog?, userProtected: ProtectList, protections: HardProtections = .standard,
                commandTarget: CatalogEntry? = nil) {
        self.commandTarget = commandTarget
        self.home = home
        self.catalog = catalog
        self.userProtected = userProtected
        self.protections = protections
        var homes = [RiskPolicy.canonical(home)]
        if let real = Self.realPath(home), !homes.contains(RiskPolicy.canonical(real)) {
            homes.append(RiskPolicy.canonical(real))
        }
        homeForms = homes
        var inodes: [InodeKey: String] = [:]
        for root in protections.criticalRoots + [home] {
            if let key = Self.statKey(root), inodes[key] == nil { inodes[key] = root }
        }
        criticalInodes = inodes
        usersInode = Self.statKey("/Users")
    }

    public func validate(_ path: String) -> Result<ValidatedPath, PathRefusal> {
        validate(path, waiver: nil)
    }

    /// `validate(_:)` es `validate(_:waiver: nil)`. Con dispensa, todo lo demás sigue igual (sintaxis, formas
    /// resueltas, inodo de raíces críticas, lista del usuario, catálogo); solo se saltan las coincidencias de
    /// la lista dura que la dispensa cubre (ver `ProtectionWaiver`).
    public func validate(_ path: String, waiver: ProtectionWaiver?) -> Result<ValidatedPath, PathRefusal> {
        if let reason = Self.syntaxRefusal(path) { return .failure(PathRefusal(reason: reason)) }
        guard let identity = Self.identity(of: path) else { return .failure(PathRefusal(reason: "No existe.")) }
        // Si no se puede resolver la carpeta padre (o el destino de un enlace que existe), no se sabe
        // dónde está de verdad: se rechaza (fallo cerrado).
        guard let forms = Self.forms(of: path, isSymlink: identity.isSymlink) else {
            return .failure(PathRefusal(reason: "No se puede resolver la ruta real; no se toca."))
        }
        // Solo la ruta tal cual se eligió es el `.app`; ni variantes de mayúsculas ni nada de dentro.
        let isBundle = waiver.map { path == $0.appPath } ?? false
        if isBundle, let waiver, !waiver.bundleStillMatches(identity: identity) {
            return .failure(PathRefusal(reason: ProtectionWaiver.bundleChanged))
        }
        for form in forms {
            if let reason = refusal(forForm: form, waiver: waiver, isBundle: isBundle) {
                return .failure(PathRefusal(reason: reason))
            }
        }
        if let reason = inodeRefusal(path, identity: identity) { return .failure(PathRefusal(reason: reason)) }
        return .success(ValidatedPath(path: path, forms: forms, identity: identity))
    }

    /// Vuelve a hacer `lstat` de la ruta y su padre justo antes de actuar; distinto ⇒ rechazo.
    public func confirmUnchanged(_ validated: ValidatedPath) -> PathRefusal? {
        guard let now = Self.identity(of: validated.path) else {
            return PathRefusal(reason: "Ya no existe.")
        }
        guard now == validated.identity else {
            return PathRefusal(reason: "La ruta ha cambiado desde que se comprobó; no se toca.")
        }
        return nil
    }

    // MARK: - Reglas por forma

    private func refusal(forForm form: String, waiver: ProtectionWaiver?, isBundle: Bool) -> String? {
        for base in homeForms {
            guard let waiver else {
                if let match = protections.match(canonicalPath: form, home: base, catalog: catalog,
                                                     commandTarget: commandTarget) {
                    return match.reason
                }
                continue
            }
            let matches = protections.matches(canonicalPath: form, home: base, catalog: catalog,
                                              commandTarget: commandTarget)
            if let match = matches.first(where: { !waiver.waives($0, form: form, isBundle: isBundle, home: base) }) {
                return match.reason
            }
        }
        for variant in homeVariants(of: form) {
            if let pattern = userProtected.match(variant) { return "Lo has protegido tú (\(pattern))." }
        }
        if RiskPolicy.minimumRisk(forPath: form, home: home) == .doNotTouch { return "Marcado como «No tocar»." }
        guard let catalog else { return nil }
        if let entry = catalog.match(path: form, home: home), entry.risk == .doNotTouch {
            return "Marcado como «No tocar» (\(entry.title))."
        }
        // Las cachés con comando oficial se limpian solo con ese comando, nunca a mano.
        for entry in catalog.entries {
            guard case .command = entry.cleanup else { continue }
            if entry.paths.contains(where: { related(form, $0) }) {
                return "«\(entry.title)» se limpia solo con su comando oficial."
            }
        }
        // Ni dentro de un patrón "No tocar" ni una carpeta que lo contenga (exista o no ahora).
        for entry in catalog.entries where entry.risk == .doNotTouch {
            if entry.paths.contains(where: { related(form, $0) }) {
                return "Contiene o está dentro de algo marcado como «No tocar» (\(entry.title))."
            }
        }
        return nil
    }

    /// La forma tal cual y, si está bajo una forma del home, reescrita bajo las demás (la lista del usuario
    /// se guarda con el home literal; la forma resuelta puede empezar por `/private`).
    private func homeVariants(of form: String) -> [String] {
        var variants = [form]
        for from in homeForms where RiskPolicy.isInside(form, root: from) {
            for to in homeForms where to != from {
                variants.append(to + form.dropFirst(from.count))
            }
        }
        return variants
    }

    /// `true` si la ruta canónica está dentro del patrón (o lo iguala) o es una carpeta superior suya.
    private func related(_ canonicalPath: String, _ pattern: String) -> Bool {
        var expanded = pattern
        if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
        let patternParts = HardProtections.components(RiskPolicy.canonical(expanded))
        let pathParts = HardProtections.components(canonicalPath)
        return zip(patternParts, pathParts).allSatisfy { HardProtections.componentMatches($0, $1) }
    }

    // MARK: - Identidad

    private func inodeRefusal(_ path: String, identity: FileIdentity) -> String? {
        var keys = [InodeKey(device: identity.device, inode: identity.inode)]
        if identity.isSymlink, let target = Self.statKey(path) { keys.append(target) }
        for key in keys {
            if let root = criticalInodes[key] { return "Carpeta crítica del sistema (la misma que \(root))." }
        }
        if let usersInode {
            guard let parent = Self.realPath((path as NSString).deletingLastPathComponent),
                  let parentKey = Self.statKey(parent) else {
                return "No se puede resolver la ruta real; no se toca."
            }
            if parentKey == usersInode { return "Carpeta crítica del sistema (carpeta de un usuario)." }
        }
        return nil
    }

    static func identity(of path: String) -> FileIdentity? {
        var item = stat()
        guard lstat(path, &item) == 0 else { return nil }
        var parent = stat()
        let parentPath = (path as NSString).deletingLastPathComponent
        guard lstat(parentPath.isEmpty ? "/" : parentPath, &parent) == 0 else { return nil }
        return FileIdentity(device: device(item), inode: UInt64(item.st_ino),
                            parentDevice: device(parent), parentInode: UInt64(parent.st_ino),
                            isSymlink: (item.st_mode & S_IFMT) == S_IFLNK)
    }

    private static func statKey(_ path: String) -> InodeKey? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return InodeKey(device: device(info), inode: UInt64(info.st_ino))
    }

    private static func device(_ info: stat) -> UInt64 { UInt64(UInt32(bitPattern: info.st_dev)) }

    // MARK: - Sintaxis y formas

    static let maxPathBytes = 1024

    static func syntaxRefusal(_ path: String) -> String? {
        if path.isEmpty { return "Ruta vacía." }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "La ruta contiene caracteres de control."
        }
        guard path.hasPrefix("/") else { return "Ruta no absoluta." }
        if path == "/" { return "Carpeta crítica del sistema." }
        if path.utf8.count > maxPathBytes { return "Ruta demasiado larga." }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "Ruta no canónica (componentes vacíos, «.» o «..»)."
        }
        return nil
    }

    /// Canónicas: la ruta tal cual, con su carpeta padre resuelta y, si es un enlace, su destino.
    /// `nil` si la carpeta padre no se puede resolver o el destino existe pero no se puede resolver.
    static func forms(of path: String, isSymlink: Bool) -> [String]? {
        var forms = [RiskPolicy.canonical(path)]
        func add(_ form: String) { if !forms.contains(form) { forms.append(form) } }
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedParent = realPath(parent) else { return nil }
        add(RiskPolicy.canonical(resolvedParent + "/" + (path as NSString).lastPathComponent))
        if isSymlink {
            if let target = realPath(path) {
                add(RiskPolicy.canonical(target))
            } else {
                // Solo un enlace roto (el destino no existe) se acepta sin resolver: su destino en texto,
                // relativo a la carpeta padre resuelta.
                var info = stat()
                guard stat(path, &info) != 0, errno == ENOENT,
                      let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                add(RiskPolicy.canonical(raw.hasPrefix("/") ? raw : resolvedParent + "/" + raw))
            }
        }
        return forms
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
