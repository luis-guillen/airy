import Foundation
import Synchronization

/// Busca los restos de una app en la carpeta personal (y, solo para informar, en `/Library`) y arma el plan
/// de desinstalación con su tamaño real. Los restos se deducen del identificador de la app y de sus ayudantes
/// (y, con menos confianza, de su nombre); nunca del destino de un enlace.
public struct LeftoverFinder: Sendable {
    private let home: String
    private let gate: PathGate
    private let runner: any CommandRunning
    private let appRoots: [String]
    private let systemLibrary: String
    private let budget: Duration

    public init(home: String, gate: PathGate, runner: any CommandRunning, appRoots: [String],
                systemLibrary: String = "/Library", budget: Duration = TimeBudget.sizeMeasure) {
        self.home = home
        self.gate = gate
        self.runner = runner
        self.appRoots = appRoots
        self.systemLibrary = systemLibrary
        self.budget = budget
    }

    static let pkgutil = "/usr/sbin/pkgutil"
    static let pkgutilTimeout: TimeInterval = 10

    // MARK: - Tabla de ubicaciones

    private enum Match { case id, name }

    /// Una fila de la tabla: carpeta bajo `~/Library` y cómo reconoce una entrada (en minúsculas).
    private struct Row: Sendable {
        let kind: Leftover.Kind
        let folder: String
        let risk: Risk
        let preselected: Bool
        let reason: String
        /// La fila coincide por id y por nombre (la coincidencia solo por nombre baja de confianza).
        var byIDAndName = false
        let match: @Sendable (_ entry: String, _ ids: [String], _ names: Set<String>) -> Match?
    }

    /// `x + suffix` exacto para algún id (o, si `names`, algún nombre).
    private static func exact(_ suffixes: [String], names useNames: Bool = false)
        -> @Sendable (String, [String], Set<String>) -> Match? {
        { entry, ids, names in
            for suffix in suffixes {
                if ids.contains(where: { entry == $0 + suffix }) { return .id }
            }
            if useNames, suffixes.contains(where: { suffix in names.contains { entry == $0 + suffix } }) {
                return .name
            }
            return nil
        }
    }

    private static let rows: [Row] = [
        Row(kind: .appSupport, folder: "Application Support", risk: .yourCall, preselected: true,
            reason: "Datos y ajustes de la app; si la reinstalas empezará de cero.", byIDAndName: true,
            match: exact([""], names: true)),
        Row(kind: .caches, folder: "Caches", risk: .safe, preselected: true, reason: "Caché: se regenera.",
            byIDAndName: true, match: exact([""], names: true)),
        Row(kind: .containers, folder: "Containers", risk: .yourCall, preselected: true,
            reason: "Datos de la app (sandbox).", match: exact([""])),
        Row(kind: .preferences, folder: "Preferences", risk: .yourCall, preselected: true,
            reason: "Ajustes de la app.", match: exact([".plist"])),
        Row(kind: .byHost, folder: "Preferences/ByHost", risk: .yourCall, preselected: true,
            reason: "Ajustes de la app en este Mac.",
            match: { entry, ids, _ in
                ids.contains { entry.hasPrefix($0 + ".") && entry.hasSuffix(".plist") } ? .id : nil
            }),
        Row(kind: .savedState, folder: "Saved Application State", risk: .safe, preselected: true,
            reason: "Estado de ventanas: se regenera.", match: exact([".savedstate"])),
        Row(kind: .httpStorage, folder: "HTTPStorages", risk: .safe, preselected: true,
            reason: "Datos de red de la app.", match: exact(["", ".binarycookies"])),
        Row(kind: .logs, folder: "Logs", risk: .safe, preselected: true, reason: "Registros.", byIDAndName: true,
            match: exact([""], names: true)),
        Row(kind: .webKit, folder: "WebKit", risk: .safe, preselected: true, reason: "Caché web de la app.",
            match: exact([""])),
        Row(kind: .webKit, folder: "WebKit/com.apple.WebKit.WebContent", risk: .safe, preselected: true,
            reason: "Caché web de la app.", match: exact([""])),
        Row(kind: .cookies, folder: "Cookies", risk: .safe, preselected: true, reason: "Cookies de la app.",
            match: exact([".binarycookies"])),
        Row(kind: .applicationScripts, folder: "Application Scripts", risk: .yourCall, preselected: true,
            reason: "Scripts de la app.", match: exact([""])),
        Row(kind: .autosave, folder: "Autosave Information", risk: .yourCall, preselected: false,
            reason: "Puede tener documentos sin guardar.", match: exact([""])),
        Row(kind: .syncedPreferences, folder: "SyncedPreferences", risk: .yourCall, preselected: true,
            reason: "Ajustes sincronizados.", match: exact([".plist"])),
    ] + pluginRows

    private static let pluginReason = "Otras apps pueden usar este complemento."

    private static var pluginRows: [Row] {
        let named: (String, String) -> Row = { folder, ext in
            Row(kind: .plugin, folder: folder, risk: .yourCall, preselected: false, reason: pluginReason,
                match: { entry, _, names in names.contains { entry == $0 + ext } ? .name : nil })
        }
        let audio: (String) -> Row = { folder in
            Row(kind: .plugin, folder: "Audio/Plug-Ins/" + folder, risk: .yourCall, preselected: false,
                reason: pluginReason,
                match: { entry, _, names in
                    let ext = (entry as NSString).pathExtension
                    return !ext.isEmpty && names.contains((entry as NSString).deletingPathExtension) ? .name : nil
                })
        }
        return [named("Services", ".workflow"), named("QuickLook", ".qlgenerator"),
                audio("Components"), audio("VST"), audio("VST3")]
    }

    static let systemFolders = ["Application Support", "Caches", "Logs", "Preferences", "LaunchAgents",
                                "LaunchDaemons", "PrivilegedHelperTools"]

    // MARK: - Plan

    /// Resto encontrado, antes de etiquetarlo.
    private struct Candidate {
        let path: String
        let kind: Leftover.Kind
        let matchedByName: Bool
        var risk: Risk
        var preselected: Bool
        var reason: String
        var launchLabel: String? = nil
        /// Ruta de disco que se mide (no en los recibos).
        var measured = true
    }

    public func plan(for app: AppRecord, inventory: AppInventorySnapshot) async -> UninstallPlan {
        let waiver = ProtectionWaiver.uninstall(app, appRoots: appRoots)
        let refusal = waiver == nil ? refusalText(for: app) : nil
        var ids: [String] = []
        for id in [app.bundleID] + app.helperBundleIDs {
            let lower = id.lowercased()
            if !lower.isEmpty, !ids.contains(lower) { ids.append(lower) }
        }
        let names = Set(AppInventory.nameVariants(app.name).map { $0.lowercased() })

        var candidates: [Candidate] = []
        var seen = Set<String>()
        func add(_ candidate: Candidate) {
            if seen.insert(candidate.path).inserted { candidates.append(candidate) }
        }
        let library = home + "/Library"
        if !ids.isEmpty || !names.isEmpty {
            for row in Self.rows {
                let folder = library + "/" + row.folder
                for entry in Self.entries(of: folder) {
                    guard let match = row.match(entry.lowercased(), ids, names) else { continue }
                    var candidate = Candidate(path: folder + "/" + entry, kind: row.kind,
                                              matchedByName: match == .name, risk: row.risk,
                                              preselected: row.preselected, reason: row.reason)
                    if row.byIDAndName, match == .name {
                        candidate.risk = .yourCall
                        candidate.preselected = false
                        candidate.reason = "Coincide por nombre: revisa que sea de «\(app.name)»."
                    }
                    add(candidate)
                }
            }
            for agent in launchAgents(in: library + "/LaunchAgents", ids: ids, appPath: app.path) { add(agent) }
        }
        // Reglas 2 y 3: el embudo (con y sin dispensa) y el suelo por ruta.
        candidates = candidates.map(labelled(waiver: waiver, appName: app.name))
        if !ids.isEmpty || !names.isEmpty {
            for candidate in systemLocations(ids: ids, names: names) { add(candidate) }
        }
        for receipt in await receipts(for: app) { add(receipt) }

        // Regla 4: otra copia instalada; y enlaces a apps fuera de las raíces: solo informativo.
        let canonicalPath = RiskPolicy.canonical(app.path)
        let other = inventory.apps.first {
            $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
                && RiskPolicy.canonical($0.path) != canonicalPath
        }
        let override: String? = if let other {
            "Otra copia instalada en \(other.path) los usa."
        } else if let refusal {
            refusal
        } else if linkIsInformational(app.path) {
            "Es un enlace a una app que está fuera de Aplicaciones: sus datos no se tocan."
        } else {
            nil
        }
        if let override {
            candidates = candidates.map {
                var copy = $0
                copy.risk = .doNotTouch
                copy.preselected = false
                copy.reason = override
                return copy
            }
        }

        let (sizes, complete) = await measure([app.path] + candidates.filter(\.measured).map(\.path))
        let leftovers = candidates.map {
            Leftover(path: $0.path, kind: $0.kind, bytes: $0.measured ? sizes[$0.path] ?? 0 : 0, risk: $0.risk,
                     preselected: $0.preselected, matchedByName: $0.matchedByName, reason: $0.reason,
                     launchLabel: $0.launchLabel)
        }
        return UninstallPlan(app: app, appBytes: sizes[app.path] ?? 0, leftovers: leftovers, refusal: refusal,
                             sharedWith: other?.path, sizeComplete: complete)
    }

    private func labelled(waiver: ProtectionWaiver?, appName: String) -> (Candidate) -> Candidate {
        { candidate in
            var result = candidate
            switch gate.validate(candidate.path, waiver: waiver) {
            case .failure(let refusal):
                result.risk = .doNotTouch
                result.preselected = false
                result.reason = refusal.reason
            case .success:
                if waiver != nil, gate.validate(candidate.path, waiver: nil).failure != nil {
                    result.risk = .strictest(result.risk, .yourCall)
                    result.preselected = false
                    result.reason = "Datos de cuenta de «\(appName)»: si la reinstalas tendrás que volver a configurarla."
                }
            }
            result.risk = .strictest(result.risk, RiskPolicy.minimumRisk(forPath: candidate.path, home: home))
            if result.risk == .doNotTouch { result.preselected = false }
            return result
        }
    }

    // MARK: - Filas especiales

    /// `LaunchAgents/*.plist` cuyo `Label` es un id o empieza por `<id>.`, o cuyo programa está dentro del
    /// `.app` (la ruta tal cual, sin seguir enlaces). Los plist ilegibles se saltan.
    private func launchAgents(in folder: String, ids: [String], appPath: String) -> [Candidate] {
        let bundle = RiskPolicy.canonical(appPath)
        var result: [Candidate] = []
        for entry in Self.entries(of: folder) where entry.lowercased().hasSuffix(".plist") {
            let path = folder + "/" + entry
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String, !label.isEmpty else { continue }
            let lower = label.lowercased()
            let byLabel = ids.contains { lower == $0 || lower.hasPrefix($0 + ".") }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [Any])?.first as? String)
            let byProgram = program.map {
                $0.hasPrefix("/") && RiskPolicy.canonical($0).hasPrefix(bundle + "/")
            } ?? false
            guard byLabel || byProgram else { continue }
            result.append(Candidate(path: path, kind: .launchAgent, matchedByName: false, risk: .yourCall,
                                    preselected: true, reason: "Se ejecuta al iniciar sesión; se detiene antes.",
                                    launchLabel: label))
        }
        return result
    }

    /// Entradas de `/Library` que empiezan por un id o un nombre: solo informativas, nunca se borran.
    private func systemLocations(ids: [String], names: Set<String>) -> [Candidate] {
        var result: [Candidate] = []
        for sub in Self.systemFolders {
            let folder = systemLibrary + "/" + sub
            for entry in Self.entries(of: folder) {
                let lower = entry.lowercased()
                let byID = ids.contains { lower.hasPrefix($0) }
                guard byID || names.contains(where: { lower.hasPrefix($0) }) else { continue }
                result.append(Candidate(path: folder + "/" + entry, kind: .systemLocation, matchedByName: !byID,
                                        risk: .doNotTouch, preselected: false,
                                        reason: "Fuera de tu carpeta personal: Airy no lo borra."))
            }
        }
        return result
    }

    /// `pkgutil --file-info <app>` → líneas `pkgid: X`. Los id con caracteres raros se descartan.
    private func receipts(for app: AppRecord) async -> [Candidate] {
        guard let output = try? await runner.run(Self.pkgutil, ["--file-info", app.path], timeout: Self.pkgutilTimeout),
              output.status == 0 else { return [] }
        var result: [Candidate] = []
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("pkgid:") else { continue }
            let id = text.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
            guard Self.isValidPackageID(id), !result.contains(where: { $0.path == id }) else { continue }
            let isApple = id.lowercased().hasPrefix("com.apple.")
            result.append(Candidate(
                path: id, kind: .receipt, matchedByName: false, risk: isApple ? .doNotTouch : .safe,
                preselected: !isApple,
                reason: isApple ? "Es parte de macOS." : "Registro de instalación; pide contraseña de administrador.",
                measured: false))
        }
        return result
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`
    static func isValidPackageID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 200 else { return false }
        func ascii(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        return ascii(first) && id.unicodeScalars.allSatisfy { ascii($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    // MARK: - Rechazos y enlaces

    private func refusalText(for app: AppRecord) -> String {
        let resolved = Self.realPath(app.path) ?? app.path
        let onDisk = AppInventory.bundleIdentifier(ofApp: app.path)
        let ids = [app.bundleID] + (onDisk.map { [$0] } ?? [])
        if app.isSystem || ids.contains(where: {
            AppInventory.isSystemApp(path: app.path, bundleID: $0) || AppInventory.isSystemApp(path: resolved, bundleID: $0)
        }) {
            return "Es parte de macOS."
        }
        let lower = ids.map { $0.lowercased() }
        if lower.contains(where: { id in
            AppInventory.officialUninstallerPrefixes.contains { id.hasPrefix($0.lowercased()) }
        }) {
            return "Usa el desinstalador oficial de «\(app.name)»."
        }
        if lower.contains(where: { $0.hasPrefix("local.airy.") }) { return "Es Airy." }
        let setapp = RiskPolicy.canonical(home + "/Library/Application Support/Setapp")
        if RiskPolicy.isInside(RiskPolicy.canonical(app.path), root: setapp)
            || RiskPolicy.isInside(RiskPolicy.canonical(resolved), root: setapp) {
            return "Desinstálala desde Setapp."
        }
        return "Solo se desinstalan apps de Aplicaciones."
    }

    /// `true` si el `.app` es un enlace cuyo destino está fuera de las raíces de apps, dentro de `/System`
    /// o no se puede resolver.
    private func linkIsInformational(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return false }
        guard let target = Self.realPath(path) else { return true }
        let form = RiskPolicy.canonical(target)
        if RiskPolicy.isInside(form, root: "/system") { return true }
        let roots = appRoots.flatMap { root in [root] + (Self.realPath(root).map { [$0] } ?? []) }
            .map(RiskPolicy.canonical)
        return !roots.contains { form.hasPrefix($0 + "/") }
    }

    // MARK: - Utilidades

    private static func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Tamaños dentro del presupuesto; si se agota, lo que no se midió no aparece (0 bytes).
    private func measure(_ paths: [String]) async -> (sizes: [String: Int64], complete: Bool) {
        guard budget > .zero else { return ([:], false) }
        final class Sizes: Sendable { let values = Mutex<[String: Int64]>([:]) }
        let box = Sizes()
        let finished = await TimeBudget.run(budget) {
            for path in paths {
                if Task.isCancelled { return false }
                let bytes = AllocatedSize.of(path) ?? 0
                box.values.withLock { $0[path] = bytes }
            }
            return true
        }
        return (box.values.withLock { $0 }, finished == true)
    }
}
