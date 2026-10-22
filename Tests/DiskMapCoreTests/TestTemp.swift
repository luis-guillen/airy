import Foundation
import Synchronization

/// Single entry point for every temporary folder the tests create.
///
/// All folders live under one per-process root,
/// `NSTemporaryDirectory()/airy-tests/<pid>-<launch UUID>/`, which is removed when the
/// process exits (`atexit`). Folders are only ever deleted at exit, so parallel suites
/// never race with the cleanup. As a safety net for runs that were killed or crashed,
/// the first use also deletes sibling run roots older than one hour whose PID is dead.
enum TestTemp {
    /// Parent of every run root.
    static let base: String = NSTemporaryDirectory() + "airy-tests"

    /// This process's root. Created (and cleanup registered) on first access.
    static let root: String = {
        let path = base + "/\(getpid())-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        sweepStaleRuns(excluding: path)
        sweepStaleSuites()
        atexit { TestTemp.removeAll() }
        return path
    }()

    /// Creates `<root>/<label>-<UUID>` and returns its path.
    static func directory(_ label: String) -> String {
        let path = self.path(label)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `<root>/<label>-<UUID>` as a URL, without creating it (callers that create it themselves).
    static func url(_ label: String) -> URL {
        URL(fileURLWithPath: path(label))
    }

    /// `<root>/<label>-<UUID>` without creating it.
    static func path(_ label: String) -> String {
        root + "/\(label)-\(UUID().uuidString)"
    }

    // MARK: Preference suites

    /// A `UserDefaults` suite for one test. `cfprefsd` rewrites the suite's .plist after it is removed, so the
    /// file is deleted at process exit instead (together with the temp root). Returns the suite name.
    static func defaultsSuiteName(_ label: String) -> String {
        let name = "airy.test.\(label).\(UUID().uuidString)"
        _ = root // make sure the exit handler is registered
        suites.withLock { $0.append(name) }
        return name
    }

    private static let suites = Mutex<[String]>([])

    /// `cfprefsd` recreates a suite's file after the process that used it exits, so a run always leaves its last
    /// few behind. The next run removes the ones older than an hour, so they never accumulate.
    private static func sweepStaleSuites() {
        let dir = NSHomeDirectory() + "/Library/Preferences"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix("airy.test.") && name.hasSuffix(".plist") {
            let path = dir + "/" + name
            if let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modified < cutoff {
                unlink(path)
            }
        }
    }

    private static func removeSuites() {
        for name in suites.withLock({ $0 }) {
            UserDefaults.standard.removePersistentDomain(forName: name)
            let plist = NSHomeDirectory() + "/Library/Preferences/\(name).plist"
            unlink(plist)
        }
    }

    // MARK: Cleanup

    /// Removes this process's root, restoring permissions first so locked folders go too.
    static func removeAll() {
        removeSuites()
        remove(root)
        // Drop `airy-tests/` itself when no other run is using it.
        rmdir(base)
    }

    private static func sweepStaleRuns(excluding own: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names {
            let path = base + "/" + name
            guard path != own, let pid = pid_t(name.prefix { $0 != "-" }) else { continue }
            if kill(pid, 0) == 0 || errno != ESRCH { continue }  // still alive
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            remove(path)
        }
    }

    /// Recursive delete that restores `u+rwx` (and clears file flags) on every entry first, so
    /// locked folders and read-only files really go. It walks with file descriptors
    /// (`openat`/`unlinkat`) because some tests build paths longer than `PATH_MAX`, and does not
    /// follow symlinks. `FileManager.removeItem` gives up at the first entry it cannot remove.
    private static func remove(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            chflags(path, 0)
            chmod(path, (info.st_mode & 0o7777) | 0o700)
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd >= 0 { emptyDirectory(fd) }  // closes fd
            rmdir(path)
        } else {
            chflags(path, 0)
            unlink(path)
        }
    }

    /// Deletes everything inside the directory open at `fd`, then closes it.
    private static func emptyDirectory(_ fd: Int32) {
        guard let dir = fdopendir(fd) else { close(fd); return }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        let parent = dirfd(dir)
        for name in names {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                fchmodat(parent, name, (info.st_mode & 0o7777) | 0o700, 0)
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 { emptyDirectory(child) }
                unlinkat(parent, name, AT_REMOVEDIR)
            } else {
                unlinkat(parent, name, 0)
            }
        }
        closedir(dir)  // also closes fd
    }
}
