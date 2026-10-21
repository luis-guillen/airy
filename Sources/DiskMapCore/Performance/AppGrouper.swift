import Foundation

/// R1: agrupa los procesos propios por la ruta del `.app` más externo.
public enum AppGrouper {
    public static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"]

    /// "/Applications/Google Chrome.app" para un helper anidado; nil si la ruta no está dentro de un `.app`.
    public static func outermostBundle(_ path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let i = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + parts[...i].joined(separator: "/")
    }

    /// Sin ruta conocida cuenta como sistema: nunca se ofrece cerrar algo que no se sabe qué es.
    private static func isSystem(_ path: String?) -> Bool {
        guard let path else { return true }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }

    /// Carpetas que no dicen qué programa es (se saltan al buscar el nombre de un binario con versión).
    static let genericFolders: Set<String> = [
        "versions", "version", "bin", "sbin", "libexec", "lib", "current", "node_modules", ".bin", "contents", "macos",
        "share", "local", "build", "release", "debug", "dist", "out",
    ]

    /// «2.1.304», «1.0», «v22.3.0»: un nombre que es solo una versión.
    static func isVersionLike(_ name: String) -> Bool {
        let core = name.hasPrefix("v") ? String(name.dropFirst()) : name
        return !core.isEmpty && core.first!.isNumber && core.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Nombre legible de un proceso suelto o del sistema: si el nombre del kernel está truncado, el del
    /// ejecutable (o su título del catálogo); si el ejecutable es una versión (`…/claude/versions/2.1.304`), la
    /// primera carpeta superior con nombre de programa.
    public static func friendlyName(_ p: OwnProcess, catalog: AppCatalog?) -> String {
        var base = p.name
        if let path = p.executablePath {
            let parts = path.split(separator: "/").map(String.init)
            if let file = parts.last {
                if isVersionLike(file) {
                    if let parent = parts.dropLast().reversed().first(where: {
                        !isVersionLike($0) && !genericFolders.contains($0.lowercased())
                    }) {
                        base = parent.hasPrefix(".") ? String(parent.dropFirst()) : parent
                    }
                } else if file.count > p.name.count, file.hasPrefix(p.name) {
                    base = file
                }
            }
        }
        // Solo cuando el nombre del kernel no servía: un `node` sigue llamándose `node`.
        if base != p.name, let title = catalog?.entry(bundleID: nil, processName: base)?.title { return title }
        return base
    }

    public static let dockerVMName = "Docker (máquina virtual)"

    public static func group(_ raw: RawSample, cpu: [Int32: Double], energy: [Int32: Double],
                             catalog: AppCatalog?) -> [AppGroup] {
        let live = raw.processes.filter { !$0.isZombie }
        let home = NSHomeDirectory()
        var bundleProcs: [String: [OwnProcess]] = [:], bundleOrder: [String] = []
        var systemProcs: [String: [OwnProcess]] = [:], systemOrder: [String] = []
        var groups: [AppGroup] = []

        for p in live {
            if let bundle = outermostBundle(p.executablePath) {
                if bundleProcs[bundle] == nil { bundleOrder.append(bundle) }
                bundleProcs[bundle, default: []].append(p)
            } else if isSystem(p.executablePath) {
                if systemProcs[p.name] == nil { systemOrder.append(p.name) }
                systemProcs[p.name, default: []].append(p)
            } else {
                var detail: String?
                if let cwd = p.workingDirectory, cwd != "/", cwd != home, cwd != home + "/" {
                    let last = (cwd as NSString).lastPathComponent
                    detail = last.isEmpty ? nil : last
                }
                let entry = catalog?.entry(bundleID: nil, processName: p.name)
                groups.append(make(id: "pid:\(p.pid):\(Int(p.startTime.timeIntervalSince1970))",
                                   name: friendlyName(p, catalog: catalog), detail: detail,
                                   bundleID: nil, bundlePath: nil, kind: .looseProcess, members: [p], lead: p,
                                   cpu: cpu, energy: energy, explanation: entry?.explanation))
            }
        }

        for name in systemOrder {
            let members = systemProcs[name] ?? []
            let lead = members.max { $0.footprint < $1.footprint } ?? members[0]
            groups.append(make(id: "system:" + name, name: friendlyName(lead, catalog: catalog), detail: nil,
                               bundleID: nil, bundlePath: nil,
                               kind: .system, members: members, lead: lead, cpu: cpu, energy: energy,
                               explanation: catalog?.entry(bundleID: nil, processName: name)?.explanation))
        }

        for path in bundleOrder {
            let members = bundleProcs[path] ?? []
            let apps = raw.apps.filter { $0.bundlePath == path }
            let regular = apps.filter { $0.policy == .regular }.sorted { $0.pid < $1.pid }
            let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

            // F5: varias instancias normales del mismo bundle → un grupo por instancia; los ayudantes van a la de menor PID.
            if regular.count > 1 {
                for inst in regular {
                    let instancePIDs = Set(regular.map(\.pid))
                    let mine = members.filter { p in
                        p.pid == inst.pid || (inst.pid == regular[0].pid && !instancePIDs.contains(p.pid))
                    }
                    guard !mine.isEmpty else { continue }
                    let lead = mine.first { $0.pid == inst.pid } ?? mine.max { $0.footprint < $1.footprint }!
                    groups.append(make(id: "\(inst.bundleID ?? "bundle:" + path)#\(inst.pid)", name: inst.name,
                                       detail: nil, bundleID: inst.bundleID, bundlePath: path, kind: .app,
                                       members: mine, lead: lead, cpu: cpu, energy: energy,
                                       explanation: catalog?.entry(bundleID: inst.bundleID, processName: lead.name)?.explanation))
                }
                continue
            }

            let app = regular.first ?? apps.sorted { $0.pid < $1.pid }.first
            let kind: AppGroupKind
            if isSystem(path), app?.policy != .regular { kind = .system }
            else if let app, app.policy == .regular || app.policy == .accessory { kind = .app }
            else { kind = .background }
            let lead = app.flatMap { a in members.first { $0.pid == a.pid } } ?? members.max { $0.footprint < $1.footprint }!
            groups.append(make(id: app?.bundleID ?? "bundle:" + path, name: app?.name ?? fileName, detail: nil,
                               bundleID: app?.bundleID, bundlePath: path, kind: kind, members: members, lead: lead,
                               cpu: cpu, energy: energy,
                               explanation: catalog?.entry(bundleID: app?.bundleID, processName: lead.name)?.explanation))
        }

        // R9: la VM de Virtualization.framework es de Docker si Docker está abierto y ninguna otra app de VM.
        let openBundles = Set(raw.apps.compactMap(\.bundleID) + groups.compactMap(\.bundleID))
        if openBundles.contains(PerformanceDiagnosis.dockerBundleID),
           openBundles.isDisjoint(with: PerformanceDiagnosis.otherVirtualizationBundleIDs) {
            for i in groups.indices where groups[i].kind == .system
                && groups[i].processNames.contains(where: { PerformanceDiagnosis.virtualMachineProcess.hasPrefix($0) && $0.count >= 20 }) {
                groups[i].name = dockerVMName
            }
        }

        // El mismo bundle id desde dos rutas (una copia de la app) daría dos grupos con el mismo id:
        // se distinguen por PID para que nunca se confunda una instancia con otra al revalidar o cerrar.
        var seen: [String: Int] = [:]
        for g in groups { seen[g.id, default: 0] += 1 }
        for i in groups.indices where seen[groups[i].id, default: 0] > 1 {
            groups[i].id += "#\(groups[i].leadPID)"
        }

        let total = raw.memory.total, cores = raw.cores.count
        return groups.sorted {
            let a = $0.impact(totalMemory: total, logicalCores: cores), b = $1.impact(totalMemory: total, logicalCores: cores)
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func make(id: String, name: String, detail: String?, bundleID: String?, bundlePath: String?,
                             kind: AppGroupKind, members: [OwnProcess], lead: OwnProcess,
                             cpu: [Int32: Double], energy: [Int32: Double], explanation: String?) -> AppGroup {
        let cpus = members.compactMap { cpu[$0.pid] }
        let energies = members.compactMap { energy[$0.pid] }
        var names: [String] = []
        for m in members where !names.contains(m.name) { names.append(m.name) }
        return AppGroup(id: id, name: name, detail: detail, bundleID: bundleID, bundlePath: bundlePath, kind: kind,
                        uid: lead.uid, leadPID: lead.pid, leadStart: lead.startTime, pids: members.map(\.pid),
                        processNames: names, memory: members.reduce(0) { $0 + $1.footprint },
                        cpuPercent: cpus.isEmpty ? nil : cpus.reduce(0, +),
                        energy: energies.isEmpty ? nil : energies.reduce(0, +), explanation: explanation)
    }
}
