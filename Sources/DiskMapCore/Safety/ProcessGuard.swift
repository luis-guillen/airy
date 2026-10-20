import Darwin
import Foundation

public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?

    public init(pid: Int32, name: String, executablePath: String?) {
        self.pid = pid; self.name = name; self.executablePath = executablePath
    }
}

public protocol ProcessListing: Sendable {
    /// `nil` = no se pudo leer la lista.
    func processes() -> [RunningProcess]?
    /// Procesos con algún fichero abierto bajo `paths`. `nil` = no se sabe.
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]?
}

/// Lectura real con libproc. Excluye el PID propio; los procesos que no se pueden inspeccionar (EPERM) se saltan.
public struct LibprocListing: ProcessListing {
    public init() {}

    public func processes() -> [RunningProcess]? {
        guard let pids = Self.allPIDs() else { return nil }
        return pids.compactMap(Self.describe)
    }

    public func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? {
        guard let pids = Self.allPIDs() else { return nil }
        let roots = paths.filter { !$0.isEmpty }
        guard !roots.isEmpty else { return [] }
        var result: [RunningProcess] = []
        for pid in pids {
            guard let process = Self.describe(pid) else { continue }
            if Self.openPaths(of: pid).contains(where: { open in
                roots.contains { open == $0 || open.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            }) {
                result.append(process)
            }
        }
        return result
    }

    private static func allPIDs() -> [Int32]? {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        return pids.prefix(Int(count)).filter { $0 > 0 && $0 != own }
    }

    private static func describe(_ pid: Int32) -> RunningProcess? {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil
        var name = nameLength > 0 ? String(cString: nameBuffer) : ""
        if name.isEmpty, let path { name = (path as NSString).lastPathComponent }
        guard !name.isEmpty else { return nil } // no inspeccionable o ya terminó
        return RunningProcess(pid: pid, name: name, executablePath: path)
    }

    private static func openPaths(of pid: Int32) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard written > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(written) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

public enum GuardState: Sendable, Equatable {
    case stopped
    /// Nombre del proceso encontrado.
    case running(String)
    /// Motivo técnico por el que no se pudo comprobar.
    case unknown(String)

    /// Texto para la interfaz cuando no se puede limpiar; `nil` si está parado.
    public var blockedReason: String? {
        switch self {
        case .stopped: nil
        case .running(let name): "Está en marcha: \(name). Ciérralo antes de limpiar."
        case .unknown: "No se pudo comprobar si está en uso; Airy no lo toca."
        }
    }
}

public struct ProcessGuard: Sendable {
    private let listing: any ProcessListing
    private let budget: Duration

    public init(listing: any ProcessListing = LibprocListing(), budget: Duration = TimeBudget.processScan) {
        self.listing = listing
        self.budget = budget
    }

    /// Nombres sin distinguir mayúsculas contra `name` y el último componente de `executablePath`.
    /// `checkOpenFiles`: además, ¿algún proceso tiene abierto un fichero bajo `paths` (caché viva, SQLite)?
    /// Cualquier fallo o exceso de tiempo ⇒ `.unknown` (falla cerrado).
    public func check(processNames: [String], paths: [String], checkOpenFiles: Bool) async -> GuardState {
        if !processNames.isEmpty {
            let listing = self.listing
            guard let outcome = await TimeBudget.run(budget, { listing.processes() }) else {
                return .unknown("el listado de procesos tardó demasiado")
            }
            guard let processes = outcome else { return .unknown("no se pudo leer el listado de procesos") }
            if case .running(let name) = Self.state(processNames: processNames, among: processes) {
                return .running(name)
            }
        }
        if checkOpenFiles, !paths.isEmpty {
            let listing = self.listing
            guard let outcome = await TimeBudget.run(budget, { listing.holders(ofPathsUnder: paths) }) else {
                return .unknown("la búsqueda de ficheros abiertos tardó demasiado")
            }
            guard let holders = outcome else { return .unknown("no se pudo saber quién usa los ficheros") }
            if let first = holders.first { return .running(first.name) }
        }
        return .stopped
    }

    /// Coincidencia pura por nombre contra un listado ya obtenido (`nil` = listado desconocido).
    public static func state(processNames: [String], among processes: [RunningProcess]?) -> GuardState {
        guard !processNames.isEmpty else { return .stopped }
        guard let processes else { return .unknown("no se pudo leer el listado de procesos") }
        let wanted = Set(processNames.map { $0.lowercased() })
        for process in processes {
            let last = process.executablePath.map { ($0 as NSString).lastPathComponent.lowercased() }
            if wanted.contains(process.name.lowercased()) || (last.map(wanted.contains) ?? false) {
                return .running(process.name)
            }
        }
        return .stopped
    }
}
