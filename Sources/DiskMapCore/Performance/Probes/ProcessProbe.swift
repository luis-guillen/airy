import AppKit
import Darwin
import Foundation

/// Processes: libproc for the user's own, `/bin/ps` (read-only) for all, NSWorkspace for the apps.
/// libproc returns EPERM for processes of root and of other users (R2), which is why `ps` covers the rest.
public enum ProcessProbe {
    // MARK: - Own (libproc)

    /// Processes with the same uid as this process (itself included). Those that fail (EPERM, already ended) are skipped.
    public static func ownProcesses() -> [OwnProcess] {
        let uid = getuid()
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(pids.count, Int(bytes) / MemoryLayout<pid_t>.size)
        let factor = timebaseFactor()
        var result: [OwnProcess] = []
        for pid in pids.prefix(count) where pid > 0 {
            if let p = read(pid: pid, uid: uid, timebase: factor) { result.append(p) }
        }
        return result
    }

    private static func read(pid: pid_t, uid: uid_t, timebase: (numer: UInt64, denom: UInt64)) -> OwnProcess? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == uid else { return nil }

        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }

        let path = executablePath(pid)
        let name = processName(bsd, path: path)
        let cpuTicks = usage.ri_user_time &+ usage.ri_system_time
        let cpuNs = cpuTicks &* timebase.numer / max(timebase.denom, 1)
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        let cwd = (path?.contains(".app/") ?? false) ? nil : workingDirectory(pid)
        return OwnProcess(pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                          executablePath: path, startTime: start, cpuTimeNs: cpuNs,
                          footprint: Int64(clamping: usage.ri_phys_footprint),
                          energyNj: usage.ri_billed_energy,
                          diskReadBytes: usage.ri_diskio_bytesread, diskWriteBytes: usage.ri_diskio_byteswritten,
                          workingDirectory: cwd, isZombie: bsd.pbi_status == UInt32(SZOMB))
    }

    private static func timebaseFactor() -> (numer: UInt64, denom: UInt64) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processName(_ bsd: proc_bsdinfo, path: String?) -> String {
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let long = string(bsd.pbi_name)
        if !long.isEmpty { return long }
        let comm = string(bsd.pbi_comm)
        if !comm.isEmpty { return comm }
        return path.map { ($0 as NSString).lastPathComponent } ?? "?"
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - All (ps)

    public static let psArguments = ["-Ac", "-o", "pid=,ppid=,uid=,pcpu=,rss=,state=,comm="]

    /// `/bin/ps` with `psArguments`, 3 s time limit; status ≠ 0, exhausted time limit or empty output ⇒ nil.
    public static func systemProcesses(runner: any CommandRunning) async -> [SystemProcess]? {
        guard let out = try? await runner.run("/bin/ps", psArguments, timeout: 3), out.status == 0 else { return nil }
        let parsed = parsePS(out.stdout)
        return parsed.isEmpty ? nil : parsed
    }

    /// Six space-separated fields and the rest of the line is the name; `,` or `.` decimal; rss in KiB.
    static func parsePS(_ output: String) -> [SystemProcess] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<6 {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            let name = rest.drop { $0 == " " || $0 == "\t" }
            guard !name.isEmpty,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")),
                  let rssKiB = Int64(fields[4]), rssKiB >= 0 else { return nil }
            let (bytes, overflow) = rssKiB.multipliedReportingOverflow(by: 1024)
            return SystemProcess(pid: pid, ppid: ppid, uid: uid, cpuPercent: cpu, rssBytes: overflow ? .max : bytes,
                                 state: String(fields[5]), name: String(name))
        }
    }

    // MARK: - Open apps

    /// NSWorkspace.shared.runningApplications → RunningAppInfo.
    public static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap(info)
    }

    /// `NSWorkspace` plus what LaunchServices says *now* about the `.app` bundles it does not know. In a process
    /// without an AppKit loop (`airy-mcp`) the `NSWorkspace` list does not learn about apps opened after launch;
    /// `NSRunningApplication(processIdentifier:)` is queried on the spot.
    public static func runningApps(processes: [OwnProcess]) -> [RunningAppInfo] {
        merge(workspace: runningApps(), processes: processes) { pid in
            NSRunningApplication(processIdentifier: pid).flatMap(info)
        }
    }

    /// For each outermost `.app` in the process list that `workspace` does not know, queries its PIDs (lowest
    /// to highest) until it finds the app of that same `.app`. An inner app (a helper with its own `.app`
    /// inside another one) does not count: its path is not that of the outermost `.app`.
    static func merge(workspace: [RunningAppInfo], processes: [OwnProcess],
                      lookup: (Int32) -> RunningAppInfo?) -> [RunningAppInfo] {
        let knownBundles = Set(workspace.compactMap(\.bundlePath))
        let knownPIDs = Set(workspace.map(\.pid))
        var members: [String: [Int32]] = [:], order: [String] = []
        for p in processes where !p.isZombie && !knownPIDs.contains(p.pid) {
            guard let bundle = AppGrouper.outermostBundle(p.executablePath), !knownBundles.contains(bundle) else { continue }
            if members[bundle] == nil { order.append(bundle) }
            members[bundle, default: []].append(p.pid)
        }
        var result = workspace
        for bundle in order {
            for pid in (members[bundle] ?? []).sorted() {
                if let app = lookup(pid), app.bundlePath == bundle {
                    result.append(app)
                    break
                }
            }
        }
        return result
    }

    private static func info(_ app: NSRunningApplication) -> RunningAppInfo? {
        guard app.processIdentifier > 0 else { return nil }
        let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.executableURL?.lastPathComponent ?? ""
        return RunningAppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: name,
                              bundlePath: app.bundleURL?.path, policy: policy(app.activationPolicy))
    }

    static func policy(_ p: NSApplication.ActivationPolicy) -> RunningAppInfo.Policy {
        switch p {
        case .regular: .regular
        case .accessory: .accessory
        default: .prohibited
        }
    }
}
