import CryptoKit
import Foundation
import Synchronization

/// One copy of a group of duplicates.
public struct DuplicateCopy: Sendable, Equatable, Identifiable {
    public let path: String, created: Date?, modified: Date?
    /// What is really freed by deleting it: `ATTR_CMNEXT_PRIVATESIZE` (0 for an APFS clone that shares
    /// blocks); if the system does not provide it, `st_blocks * 512`. With more than one hard link, 0.
    public let reclaimableBytes: Int64
    public let risk: Risk, protection: ProtectionMatch?
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }

    public init(path: String, created: Date?, modified: Date?, reclaimableBytes: Int64, risk: Risk,
                protection: ProtectionMatch?) {
        self.path = path; self.created = created; self.modified = modified
        self.reclaimableBytes = reclaimableBytes; self.risk = risk; self.protection = protection
    }
}

/// Fingerprint of a group's content. It only lives in memory, inside the process that computes it: it is not
/// public, it is not saved to disk and it is not printed (neither `description` nor `dump` shows it).
struct ContentFingerprint: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    fileprivate let digest: SHA256.Digest
    var description: String { "‹fingerprint›" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    /// `st_size` of each copy.
    public let size: Int64
    /// ≥ 2; the suggested kept copy first.
    public let copies: [DuplicateCopy]
    public let keeper: String
    let fingerprint: ContentFingerprint?
    public var id: String { keeper }
    /// What every copy except `keeper` would free.
    public var wastedBytes: Int64 { copies.filter { $0.path != keeper }.reduce(0) { $0 + $1.reclaimableBytes } }

    public init(size: Int64, copies: [DuplicateCopy], keeper: String) {
        self.init(size: size, copies: copies, keeper: keeper, fingerprint: nil)
    }

    init(size: Int64, copies: [DuplicateCopy], keeper: String, fingerprint: ContentFingerprint?) {
        self.size = size; self.copies = copies; self.keeper = keeper; self.fingerprint = fingerprint
    }
}

public struct DuplicateSearch: Sendable, Equatable {
    public var roots: [String]
    public var minBytes: Int64 = 1_000_000
    /// Cap on bytes read for the fingerprints; past it, the result is incomplete.
    public var readBudget: Int64 = 40_000_000_000
    /// Time cap of the search; past it, the result is incomplete.
    public var timeBudget: Duration = .seconds(600)
    public static let sizeSteps: [Int64] = [1_000_000, 10_000_000, 100_000_000]
    public static let skippedNames: Set<String> = [".Trash", ".git", "node_modules", ".venv"]

    /// Children of `home` except `Library` and `.Trash` (a single read of the folder, without walking anything).
    public static func defaultRoots(home: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return names.filter { $0 != "Library" && $0 != ".Trash" }.sorted().map { base + "/" + $0 }
    }

    public init(roots: [String], minBytes: Int64 = 1_000_000) {
        self.roots = roots
        self.minBytes = minBytes
    }
}

public struct DuplicateResult: Sendable, Equatable {
    /// `wastedBytes` descending, then `keeper`.
    public let groups: [DuplicateGroup]
    public let complete: Bool
    public let filesExamined: Int
    public let date: Date

    public init(groups: [DuplicateGroup], complete: Bool, filesExamined: Int, date: Date) {
        self.groups = groups; self.complete = complete; self.filesExamined = filesExamined; self.date = date
    }
}

/// What the user wants to send to the Trash from a group: it never includes `keep`.
public struct DuplicateRemoval: Sendable, Equatable {
    public let keep: String
    public let remove: [String]
    public let size: Int64
    let fingerprint: ContentFingerprint?

    /// No fingerprint: `verify` can only check `keep`'s size (the others are compared against `keep`
    /// read again). For tests and previews; what gets deleted comes from `DuplicateBoard.removals()`.
    public init(keep: String, remove: [String], size: Int64) {
        self.init(keep: keep, remove: remove, size: size, fingerprint: nil)
    }

    init(keep: String, remove: [String], size: Int64, fingerprint: ContentFingerprint?) {
        self.keep = keep; self.remove = remove; self.size = size; self.fingerprint = fingerprint
    }
}

/// Finds identical files: size → partial fingerprint (start and end) → full fingerprint. Candidates
/// come from the already scanned index (it does not walk the disk: only an `lstat` per candidate). It reads at most two
/// files at a time, at low priority, in 1 MiB blocks and without caching; it can be cancelled and has time
/// and byte caps. The fingerprints never leave this process nor are saved.
public struct DuplicateFinder: Sendable {
    public static let partialChunk = 65_536
    static let fullChunk = 1 << 20
    /// Maximum simultaneous reads.
    static let width = 2
    static let priority: TaskPriority = .utility

    private let home: String
    private let classifier: RiskClassifier
    private let gate: PathGate

    public init(home: String, classifier: RiskClassifier, gate: PathGate) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.classifier = classifier
        self.gate = gate
    }

    // MARK: - Candidates (index)

    /// Paths of index files inside `search.roots`, without entering `skippedNames`, `*.app` or
    /// the "Other" aggregates. It only reads the tree: call it inside a read turn (`TreeGate.read`).
    public static func candidates(in index: FileNode, search: DuplicateSearch) -> [String] {
        let roots = search.roots.map(RiskPolicy.canonical)
        var out: [String] = []
        func visit(_ node: FileNode, path: String) {
            if Task.isCancelled { return }
            let canonical = RiskPolicy.canonical(path)
            let inside = roots.contains { RiskPolicy.isInside(canonical, root: $0) }
            if node.isDirectory {
                if node.aggregatedCount > 0 { return }
                if !node.name.isEmpty, DuplicateSearch.skippedNames.contains(node.name) || node.name.lowercased().hasSuffix(".app") {
                    return
                }
                let ancestor = roots.contains { $0.hasPrefix(canonical == "/" ? "/" : canonical + "/") }
                guard inside || ancestor || node.name.isEmpty else { return }
                for child in node.children { visit(child, path: join(path, child.name)) }
                return
            }
            guard node.aggregatedCount == 0, inside else { return }
            out.append(path)
        }
        visit(index, path: index.name)
        return out
    }

    private static func join(_ path: String, _ name: String) -> String {
        if name.hasPrefix("/") { return name }          // roots of an index with several roots
        if path.isEmpty || path == "/" { return "/" + name }
        return path + "/" + name
    }

    // MARK: - Search

    /// Shortcut: index candidates and search. Cancellable: with `Task.cancel()` it returns what was found with
    /// `complete == false`. `progress` = files examined (≤ 10 times per second).
    public func find(_ search: DuplicateSearch, in index: FileNode,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> DuplicateResult {
        await find(search, candidates: Self.candidates(in: index, search: search), progress: progress)
    }

    /// Searches among `candidates` (index paths). It never opens a file outside that list.
    public func find(_ search: DuplicateSearch, candidates: [String],
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> DuplicateResult {
        let started = Date()
        let limits = Limits(bytes: search.readBudget, time: search.timeBudget)
        let counter = Counter(report: progress)
        func finish(_ groups: [DuplicateGroup], complete: Bool) -> DuplicateResult {
            counter.flush()
            let sorted = groups.sorted {
                $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.keeper < $1.keeper
            }
            return DuplicateResult(groups: sorted, complete: complete && !Task.isCancelled && !limits.exceeded,
                                   filesExamined: counter.value, date: started)
        }
        guard !Task.isCancelled else { return finish([], complete: false) }

        // 1–2. Regular files on the roots' volumes, with the minimum size; a single hard link.
        let rootDevices = Set(search.roots.compactMap { Self.lstatInfo($0)?.st_dev })
        let roots = search.roots.map(RiskPolicy.canonical)
        var byInode: [FileKey: Candidate] = [:]
        for path in candidates {
            if Task.isCancelled { return finish([], complete: false) }
            let canonical = RiskPolicy.canonical(path)
            guard roots.contains(where: { RiskPolicy.isInside(canonical, root: $0) }),
                  let info = Self.lstatInfo(path), (info.st_mode & S_IFMT) == S_IFREG,
                  rootDevices.contains(info.st_dev), Int64(info.st_size) >= search.minBytes else { continue }
            let key = FileKey(device: info.st_dev, inode: info.st_ino)
            if let existing = byInode[key], existing.path <= path { continue }
            byInode[key] = Candidate(path: path, size: Int64(info.st_size))
        }
        let files = Array(byInode.values)

        // 3. By size.
        let bySize = Dictionary(grouping: files, by: \.size)
        var sizeGroups = bySize.values.filter { $0.count >= 2 }
        counter.add(files.count - sizeGroups.reduce(0) { $0 + $1.count })
        sizeGroups.sort { $0[0].size > $1[0].size }       // what takes the most space first

        // 4. Partial fingerprint (start and end).
        let partialInput = sizeGroups.flatMap { $0 }
        let partials = await Self.mapBounded(partialInput, limits: limits) { candidate in
            Self.hash(candidate.path, size: candidate.size, partial: true, limits: limits)
        }
        var byPartial: [PartialKey: [Candidate]] = [:]
        for (candidate, digest) in zip(partialInput, partials) {
            guard let digest else { continue }
            byPartial[PartialKey(size: candidate.size, digest: digest), default: []].append(candidate)
        }
        let partialGroups = byPartial.values.filter { $0.count >= 2 }.sorted { $0[0].size > $1[0].size }
        let fullInput = partialGroups.flatMap { $0 }
        counter.add(partialInput.count - fullInput.count)
        if Task.isCancelled || limits.exceeded { return finish([], complete: false) }

        // 5. Full fingerprint.
        let fulls = await Self.mapBounded(fullInput, limits: limits) { candidate -> SHA256.Digest? in
            defer { counter.add(1) }
            return Self.hash(candidate.path, size: candidate.size, partial: false, limits: limits)
        }
        var byFull: [PartialKey: [Candidate]] = [:]
        for (candidate, digest) in zip(fullInput, fulls) {
            guard let digest else { continue }
            byFull[PartialKey(size: candidate.size, digest: digest), default: []].append(candidate)
        }
        let groups = byFull.compactMap { key, members -> DuplicateGroup? in
            guard members.count >= 2 else { return nil }
            return makeGroup(members, size: key.size, fingerprint: ContentFingerprint(digest: key.digest))
        }
        return finish(groups, complete: true)
    }

    private func makeGroup(_ members: [Candidate], size: Int64, fingerprint: ContentFingerprint) -> DuplicateGroup? {
        let copies = members.compactMap { member -> DuplicateCopy? in
            guard let info = Self.lstatInfo(member.path) else { return nil }
            let classification = classifier.classify(path: member.path)
            var risk = Risk.strictest(classification.risk, .yourCall)
            var protection = classification.protection
            if protection == nil, case let .failure(refusal) = gate.validate(member.path) {
                protection = ProtectionMatch(source: .airy, pattern: member.path, reason: refusal.reason)
            }
            if protection != nil { risk = .doNotTouch }
            return DuplicateCopy(path: member.path, created: Self.date(info.st_birthtimespec),
                                 modified: Self.date(info.st_mtimespec),
                                 reclaimableBytes: Self.reclaimable(member.path, info: info),
                                 risk: risk, protection: protection)
        }
        guard copies.count >= 2 else { return nil }
        let keeper = Self.suggestedKeeper(copies, home: home)
        let ordered = copies.sorted { a, b in
            if (a.path == keeper) != (b.path == keeper) { return a.path == keeper }
            return a.path < b.path
        }
        return DuplicateGroup(size: size, copies: ordered, keeper: keeper, fingerprint: fingerprint)
    }

    /// In order: (1) the first one (by path) that cannot be checked, because what is protected is never proposed
    /// for deletion; (2) outside `~/Downloads` and `~/Desktop`; (3) the one created first; (4) the shortest path; (5) alphabetical.
    static func suggestedKeeper(_ copies: [DuplicateCopy], home: String) -> String {
        if let locked = copies.filter({ !$0.canSelect }).map(\.path).min() { return locked }
        let base = RiskPolicy.canonical(home)
        let transient = ["downloads", "desktop"].map { (base == "/" ? "" : base) + "/" + $0 }
        func isTransient(_ path: String) -> Bool {
            let canonical = RiskPolicy.canonical(path)
            return transient.contains { RiskPolicy.isInside(canonical, root: $0) }
        }
        let best = copies.min { a, b in
            let (ta, tb) = (isTransient(a.path), isTransient(b.path))
            if ta != tb { return !ta }
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        return best?.path ?? ""
    }

    // MARK: - Before deleting

    /// Right before deleting: rereads the full content of `keep` and of each `remove`. Returns
    /// path → refusal reason (empty = all good). Problems with `keep` go under `keep`'s path.
    public func verify(_ removal: DuplicateRemoval) async -> [String: String] {
        let task = Task.detached(priority: Self.priority) { () -> [String: String] in
            self.verifyNow(removal)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func verifyNow(_ removal: DuplicateRemoval) -> [String: String] {
        var refusals: [String: String] = [:]
        let keepCanonical = RiskPolicy.canonical(removal.keep)
        let keepInfo = Self.lstatInfo(removal.keep)
        let keepKey = keepInfo.map { FileKey(device: $0.st_dev, inode: $0.st_ino) }
        for path in removal.remove {
            let sameInode = keepKey != nil && Self.lstatInfo(path).map { FileKey(device: $0.st_dev, inode: $0.st_ino) } == keepKey
            if RiskPolicy.canonical(path) == keepCanonical || sameInode {
                refusals[path] = String(localized: "It is the copy you are keeping.", bundle: .airyCore)
            }
        }
        let limits = Limits(bytes: .max, time: .seconds(3_600))
        // If the kept copy fails, every other one is refused too: a whole group is never deleted.
        func refuseAll(_ reason: String) -> [String: String] {
            for path in removal.remove + [removal.keep] where refusals[path] == nil { refusals[path] = reason }
            return refusals
        }
        guard let keepInfo, (keepInfo.st_mode & S_IFMT) == S_IFREG else {
            return refuseAll(String(localized: "The copy you are keeping no longer exists.", bundle: .airyCore))
        }
        guard Int64(keepInfo.st_size) == removal.size,
              let keepDigest = Self.hash(removal.keep, size: removal.size, partial: false, limits: limits),
              removal.fingerprint.map({ $0.digest == keepDigest }) ?? true else {
            return refuseAll(String(localized: "The copy you are keeping has changed.", bundle: .airyCore))
        }
        for path in removal.remove where refusals[path] == nil {
            if Task.isCancelled { refusals[path] = String(localized: "It has changed since the search.", bundle: .airyCore); continue }
            guard let info = Self.lstatInfo(path) else { refusals[path] = String(localized: "It no longer exists.", bundle: .airyCore); continue }
            guard (info.st_mode & S_IFMT) == S_IFREG, Int64(info.st_size) == removal.size,
                  Self.hash(path, size: removal.size, partial: false, limits: limits) == keepDigest else {
                refusals[path] = String(localized: "It has changed since the search.", bundle: .airyCore)
                continue
            }
        }
        return refusals
    }

    /// What can really be sent to the Trash after `verify`: the copies that pass, never the one being
    /// kept, and nothing from a group whose kept copy fails. `notes`: one visible reason per refusal.
    public func confirmable(_ removals: [DuplicateRemoval]) async -> (paths: [String], notes: [String]) {
        var paths: [String] = []
        var notes: [String] = []
        for removal in removals {
            let refusals = await verify(removal)
            if let reason = refusals[removal.keep] {
                notes.append("\(Format.tildePath(removal.keep, home: home)): \(reason)")
                continue
            }
            for (path, reason) in refusals.sorted(by: { $0.key < $1.key }) {
                notes.append("\(Format.tildePath(path, home: home)): \(reason)")
            }
            paths += removal.remove.filter { refusals[$0] == nil && $0 != removal.keep }
        }
        return (paths, notes)
    }

    // MARK: - Reading

    private struct Candidate: Sendable { let path: String, size: Int64 }
    private struct FileKey: Hashable { let device: dev_t, inode: ino_t }
    private struct PartialKey: Hashable { let size: Int64, digest: SHA256.Digest }

    /// Shared caps on bytes read and on time.
    private final class Limits: Sendable {
        private let read = Mutex<Int64>(0)
        private let budget: Int64
        private let deadline: ContinuousClock.Instant
        init(bytes: Int64, time: Duration) { budget = bytes; deadline = .now.advanced(by: time) }
        var exceeded: Bool { read.withLock { $0 } > budget || ContinuousClock.now >= deadline }
        /// `false` if these bytes go past the cap.
        func spend(_ bytes: Int) -> Bool {
            read.withLock { $0 += Int64(bytes) }
            return !exceeded
        }
    }

    /// Files examined, reporting at most every 100 ms.
    private final class Counter: Sendable {
        private struct State { var count = 0; var last: ContinuousClock.Instant? }
        private let state = Mutex(State())
        private let report: @Sendable (Int) -> Void
        init(report: @escaping @Sendable (Int) -> Void) { self.report = report }
        var value: Int { state.withLock { $0.count } }
        func add(_ n: Int) {
            guard n > 0 else { return }
            let now = ContinuousClock.now
            let due: Int? = state.withLock { s in
                s.count += n
                if let last = s.last, now - last < .milliseconds(100) { return nil }
                s.last = now
                return s.count
            }
            if let due { report(due) }
        }
        func flush() { report(value) }
    }

    /// At most `width` at a time, at low priority; the result's order is that of `items`.
    private static func mapBounded<T: Sendable, R: Sendable>(_ items: [T], limits: Limits,
                                                             _ body: @escaping @Sendable (T) -> R?) async -> [R?] {
        var results = [R?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            func launch() {
                guard next < items.count, !Task.isCancelled, !limits.exceeded else { return }
                let index = next, item = items[index]
                next += 1
                group.addTask(priority: priority) { (index, Task.isCancelled ? nil : body(item)) }
            }
            for _ in 0..<width { launch() }
            while let (index, value) = await group.next() {
                results[index] = value
                launch()
            }
        }
        return results
    }

    /// SHA-256 of the content (or of the first and last `partialChunk` bytes). `nil` if it cannot be read,
    /// if it is a link, if it changes during the read (size or `mtime`) or if it is cancelled or a cap is hit.
    private static func hash(_ path: String, size: Int64, partial: Bool, limits: Limits) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, Int64(before.st_size) == size else {
            return nil
        }
        let chunk = partial ? partialChunk : fullChunk
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()

        func readSpan(at offset: Int64, length: Int64) -> Bool {
            var done: Int64 = 0
            while done < length {
                if Task.isCancelled { return false }
                let want = Int(min(Int64(chunk), length - done))
                let got = pread(fd, buffer.baseAddress, want, off_t(offset + done))
                guard got > 0 else { return false }
                guard limits.spend(got) else { return false }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<got]))
                done += Int64(got)
            }
            return true
        }

        if partial {
            let head = min(Int64(chunk), size)
            guard readSpan(at: 0, length: head) else { return nil }
            let tail = min(Int64(chunk), size - head)
            if tail > 0 { guard readSpan(at: size - tail, length: tail) else { return nil } }
        } else {
            guard readSpan(at: 0, length: size) else { return nil }
            // If it has grown, there is something extra at the end.
            var probe: UInt8 = 0
            guard pread(fd, &probe, 1, off_t(size)) == 0 else { return nil }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { return nil }
        return hasher.finalize()
    }

    // MARK: - Metadata

    private static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func date(_ spec: timespec) -> Date? {
        guard spec.tv_sec != 0 || spec.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9)
    }

    /// Bytes that would really be freed: with another hard link, nothing; otherwise APFS's private size
    /// (0 for a clone that shares blocks) or, without it, `st_blocks * 512`.
    static func reclaimable(_ path: String, info: stat) -> Int64 {
        if info.st_nlink > 1 { return 0 }
        return privateSize(path) ?? Int64(info.st_blocks) * 512
    }

    /// `getattrlist(ATTR_CMNEXT_PRIVATESIZE)` without following links; `nil` if the volume does not provide it.
    static func privateSize(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // u_int32_t length + attribute_set_t (5 × u_int32_t) + off_t
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count,
                        UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0, length >= 32 else { return nil }
            let value = raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            return value >= 0 ? value : nil
        }
    }
}
