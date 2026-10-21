import Foundation
import Testing
@testable import DiskMapCore

private struct Quiet: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private let gitAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

/// Runs real git in the test's temporary repository (setup only; the source itself runs read-only git).
@discardableResult
private func git(_ arguments: [String], in folder: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Airy Test", "-c", "user.email=test@example.invalid",
                         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C", folder] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown, userInfo: ["git": text]) }
    return text
}

private func write(_ path: String, _ text: String = "x") {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

/// Makes git's admin files of a worktree look untouched for `days`.
private func ageAdmin(_ repo: String, _ name: String, days: Double) {
    let admin = repo + "/.git/worktrees/" + name
    for file in ["HEAD", "index", "logs/HEAD"] where FileManager.default.fileExists(atPath: admin + "/" + file) {
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                               ofItemAtPath: admin + "/" + file)
    }
}

@Suite struct GitWorktreeTests {
    @Test func parsesPorcelain() {
        let records = GitWorktreeSource.parse("""
            worktree /r
            HEAD 1111
            branch refs/heads/main

            worktree /r/wt
            HEAD 2222
            branch refs/heads/feat/x
            locked busy

            worktree /gone
            HEAD 3333
            detached
            prunable gitdir file points to non-existent location

            """)
        #expect(records.map(\.path) == ["/r", "/r/wt", "/gone"])
        #expect(records[0].isMain && !records[1].isMain)
        #expect(records[1].branch == "feat/x" && records[1].isLocked)
        #expect(records[2].branch == nil && records[2].isPrunable)
    }

    @Test(.enabled(if: gitAvailable)) func offersOnlyMergedCleanQuietWorktrees() async throws {
        let made = TestTemp.directory("worktrees")
        let home = CleanupTargets.realPath(made) ?? made
        let repo = home + "/Projects/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        write(repo + "/README.md", "hello")
        write(repo + "/.gitignore", ".build/\n")
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        for name in ["wt-merged", "wt-open", "wt-dirty", "wt-locked", "wt-fresh"] {
            try git(["worktree", "add", "-q", "-b", "feat-" + name, "../" + name], in: repo)
        }
        write(home + "/Projects/wt-merged/.build/debug/obj.o")
        write(home + "/Projects/wt-open/new.txt")
        try git(["add", "."], in: home + "/Projects/wt-open")
        try git(["commit", "-q", "-m", "work"], in: home + "/Projects/wt-open")
        write(home + "/Projects/wt-dirty/untracked.txt")
        try git(["worktree", "lock", "../wt-locked"], in: repo)
        for name in ["wt-merged", "wt-open", "wt-dirty", "wt-locked"] { ageAdmin(repo, name, days: 3) }

        let entry = try #require(try Catalog.bundled().entry(id: "merged-git-worktrees"))
        let context = DiscoveryContext(catalog: Catalog(entries: [entry]), home: home, runner: ProcessRunner(),
                                       processListing: Quiet(), now: Date(), scan: nil)
        let source = GitWorktreeSource()
        let targets = await source.discover(entry, context: context)
        #expect(targets.map(\.paths) == [[home + "/Projects/wt-merged"]])
        let target = try #require(targets.first)
        #expect(target.floor == .yourCall && !target.preselectable)
        #expect(target.floorReason == "Branch feat-wt-merged is merged into main and has no uncommitted changes")
        #expect(target.details.contains("Includes build folders: .build"))
        #expect(entry.cleanup == .trash && !entry.regenerates && entry.aggressiveRisk == nil)

        // Never green, never checked.
        let verdict = RiskClassifier(catalog: Catalog(entries: [entry]), settings: AirySettings(), home: home)
            .classify(entry: entry, paths: target.paths, floor: target.floor)
        #expect(verdict.risk == .yourCall && !verdict.preselected)

        // Revalidation: valid now; a new uncommitted file makes it refuse.
        let item = CleanupItem(id: "merged-git-worktrees:x", entry: entry, paths: target.paths, bytes: 1,
                               risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        #expect(await source.revalidate(entry, item: item, context: context) == nil)
        write(home + "/Projects/wt-merged/notes.txt")
        #expect(await source.revalidate(entry, item: item, context: context) != nil)
        // The main worktree is never accepted.
        let main = CleanupItem(id: "merged-git-worktrees:y", entry: entry, paths: [repo], bytes: 1,
                               risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        #expect(await source.revalidate(entry, item: main, context: context) != nil)
    }
}
