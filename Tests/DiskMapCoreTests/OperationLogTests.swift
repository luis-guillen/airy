import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

@Suite struct OperationLogTests {
    private func tempDir() -> URL {
        TestTemp.url("airy-oplog")
    }

    private func record(_ title: String = "t", actor: OperationActor = .user) -> OperationRecord {
        OperationRecord(runID: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), actor: actor,
                        action: "clean", itemID: "npm", title: title, paths: ["/tmp/x"], command: nil,
                        dryRun: false, outcome: "freed", bytes: 10, message: nil, proposedBy: nil)
    }

    @Test func appendAndReadBack() throws {
        let dir = tempDir()
        let log = OperationLog(file: dir.appendingPathComponent("ops.jsonl"))
        let a = record("a"), b = record("b", actor: .agent(client: "claude-code"))
        try log.append(a); try log.append(b)
        #expect(try log.records() == [a, b])
        #expect(try log.records(limit: 1) == [b])
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ops.jsonl").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func clearEmptiesTheLogAndKeepsItWritable() throws {
        let file = tempDir().appendingPathComponent("ops.jsonl")
        let log = OperationLog(file: file)
        try log.clear()
        try log.append(record("a")); try log.append(record("b"))
        try log.clear()
        #expect(try log.records().isEmpty)
        try log.append(record("c"))
        #expect(try log.records().map(\.title) == ["c"])
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func skipsCorruptLine() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("ops.jsonl")
        let log = OperationLog(file: file)
        try log.append(record("a"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{basura\n".utf8)); try handle.close()
        try log.append(record("b"))
        #expect(try log.records().map(\.title) == ["a", "b"])
    }

    @Test func tornLineDoesNotSwallowTheNextRecord() throws {
        let file = tempDir().appendingPathComponent("ops.jsonl")
        let log = OperationLog(file: file)
        try log.append(record("a"))
        // Another process died halfway through a write: a line without a trailing `\n`.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"runID":"cortado","tit"#.utf8)); try handle.close()
        try log.append(record("b"))
        try log.append(record("c"))
        #expect(try log.records().map(\.title) == ["a", "b", "c"])
        #expect(log.takeWriteFailure() == nil)
    }

    @Test func failedShortWriteIsRolledBackAndReported() throws {
        let file = tempDir().appendingPathComponent("ops.jsonl")
        try OperationLog(file: file).append(record("a"))
        let before = try Data(contentsOf: file)
        // It writes half and then fails (disk full).
        let calls = Mutex(0)
        let broken = OperationLog(file: file, writer: { fd, bytes, count in
            let call = calls.withLock { n in defer { n += 1 }; return n }
            if call == 0 { return Darwin.write(fd, bytes, count / 2) }
            errno = ENOSPC
            return -1
        })
        #expect(throws: (any Error).self) { try broken.append(self.record("b")) }
        #expect(try Data(contentsOf: file) == before)
        let failure = try #require(broken.takeWriteFailure())
        #expect(failure.contains("“b”"))
        #expect(broken.takeWriteFailure() == nil)
        try OperationLog(file: file).append(record("c"))
        #expect(try OperationLog(file: file).records().map(\.title) == ["a", "c"])
    }

    @Test func concurrentAppendsFromTwoLogsKeepAll() async throws {
        let file = tempDir().appendingPathComponent("ops.jsonl")
        let logs = [OperationLog(file: file), OperationLog(file: file)]
        let long = String(repeating: "x", count: 2000)
        await withTaskGroup(of: Void.self) { group in
            for (n, log) in logs.enumerated() {
                group.addTask {
                    for i in 0..<200 { try? log.append(self.record("\(n)-\(i)-\(long)")) }
                }
            }
        }
        #expect(try logs[0].records().count == 400)
    }

    @Test func historyConcurrentAppendsFromTwoStores() async throws {
        let dir = tempDir()
        let stores = [IndexStore(directory: dir), IndexStore(directory: dir)]
        await withTaskGroup(of: Void.self) { group in
            for store in stores {
                group.addTask {
                    for i in 0..<100 {
                        try? store.append(CleanupRecord(date: .now, title: "\(i)", bytes: 1, wentToTrash: false))
                    }
                }
            }
        }
        #expect(try stores[0].history().count == 200)
    }

    @Test func exportIsValidJSONWithRunIDsAndActors() throws {
        let log = OperationLog(file: tempDir().appendingPathComponent("ops.jsonl"))
        let a = record("a"), b = record("b", actor: .agent(client: "claude-code"))
        try log.append(a); try log.append(b)
        let object = try #require(JSONSerialization.jsonObject(with: try log.exportJSON()) as? [String: Any])
        #expect(object["exportedAt"] is String)
        let records = try #require(object["records"] as? [[String: Any]])
        #expect(records.count == 2)
        #expect(records[0]["runID"] as? String == a.runID.uuidString)
        #expect((records[0]["actor"] as? [String: String]) == ["type": "user"])
        #expect((records[1]["actor"] as? [String: String]) == ["type": "agent", "client": "claude-code"])
    }

    @Test func recordFieldsAreMetadataOnly() {
        let names = Set(Mirror(reflecting: record()).children.compactMap(\.label))
        #expect(names == ["runID", "date", "actor", "action", "itemID", "title", "paths", "command",
                          "dryRun", "outcome", "bytes", "message", "proposedBy", "proposedVia"])
        #expect(names.count == 14)
    }

    @Test func oldHistoryWithoutByAgentDecodes() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"date":"2026-01-01T00:00:00Z","title":"old","bytes":5,"wentToTrash":true}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("history.json"))
        let store = IndexStore(directory: dir)
        let old = try store.history()
        #expect(old.count == 1 && old[0].byAgent == false)
        try store.append(CleanupRecord(date: .now, title: "new", bytes: 1, wentToTrash: false, byAgent: true))
        let all = try store.history()
        #expect(all.map(\.byAgent) == [false, true])
        let raw = try String(contentsOf: dir.appendingPathComponent("history.json"), encoding: .utf8)
        #expect(raw.components(separatedBy: "byAgent").count == 2)  // only encoded when true
    }
}
