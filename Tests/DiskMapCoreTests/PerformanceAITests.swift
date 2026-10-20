import Foundation
import Testing
@testable import DiskMapCore

private func group(_ name: String, memoryMB: Int64, pid: Int32, detail: String? = nil, bundlePath: String? = nil,
                   bundleID: String? = nil, kind: AppGroupKind = .app) -> AppGroup {
    AppGroup(id: "g\(pid)", name: name, detail: detail, bundleID: bundleID, bundlePath: bundlePath, kind: kind,
             uid: 501, leadPID: pid, leadStart: Date(timeIntervalSince1970: 0), pids: [pid], processNames: [name],
             memory: memoryMB << 20, cpuPercent: 12.34)
}

private func snapshot(_ groups: [AppGroup]) -> PerformanceSnapshot {
    let memory = MemoryStats(total: 16 << 30, used: 12 << 30, fileCache: 2 << 30, pressure: .warning,
                             swapUsed: 1 << 30, swapTotal: 2 << 30)
    return PerformanceSnapshot(date: Date(), memory: memory, thermal: ThermalReading(level: .fair, throttling: true),
                               cpu: CPUUsage(total: 55.55), raw: RawSample(date: Date(), uptimeNs: 1, memory: memory),
                               groups: groups)
}

private let verdict = HealthVerdict(level: .fair, sentence: "Tu Mac va justo de memoria.",
                                    findings: [Finding(id: "memory", level: .fair, sentence: "Tu Mac va justo de memoria.")])

@Suite struct PerformanceAITests {
    @Test func contextHasOnlyNumbersAndNames() throws {
        let groups = [
            group("node", memoryMB: 900, pid: 4242, detail: "proyecto-secreto", kind: .looseProcess),
            group("X", memoryMB: 500, pid: 77, bundlePath: "/Applications/X.app", bundleID: "com.example.x"),
        ]
        let json = PerformanceAIContext.build(snapshot(groups), verdict: verdict)
        #expect(!json.contains("/") && !json.contains("proyecto-secreto") && !json.contains("4242"))
        #expect(!json.contains("com.example.x"))
        #expect(json.contains("\"name\":\"node\""))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["memory", "thermal", "cpu", "apps", "findings"])
        let memory = try #require(object["memory"] as? [String: Any])
        #expect(memory["total_gb"] as? Double == 16 && memory["pressure"] as? String == "warning")
        #expect((object["findings"] as? [String]) == ["Tu Mac va justo de memoria."])
    }

    @Test func contextLimitsToTenApps() throws {
        let groups = (1...15).map { group("App\($0)", memoryMB: Int64($0) * 100, pid: Int32($0)) }
        let json = PerformanceAIContext.build(snapshot(groups), verdict: verdict)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let apps = try #require(object["apps"] as? [[String: Any]])
        #expect(apps.count == 10 && apps.first?["name"] as? String == "App15")
    }

    @Test func explainSlownessUsesClosedInvocation() async throws {
        let lines = [
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Cierra "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Chrome."}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Cierra Chrome."}"#,
        ]
        let runner = AIFakeRunner(lines: lines)
        let ai = AIAssistant(claudePath: "/opt/claude", runner: runner, catalog: Catalog(entries: []), home: "/Users/x")
        var text = ""
        for try await chunk in ai.explainSlowness(context: #"{"apps":[]}"#) { text += chunk }
        #expect(text == "Cierra Chrome.")
        let call = try #require(runner.calls.first)
        let a = call.arguments
        for (flag, value) in [("--tools", ""), ("--setting-sources", ""), ("--system-prompt", AIAssistant.performanceSystemPrompt)] {
            let i = try #require(a.firstIndex(of: flag), "\(flag)")
            #expect(a[i + 1] == value, "\(flag)")
        }
        #expect(a.contains("--strict-mcp-config") && a.contains("stream-json"))
        #expect(call.stdin?.contains(#"{"apps":[]}"#) == true)
        #expect(call.stdin?.hasPrefix("Estado del Mac (JSON, solo números y nombres de apps):") == true)
        #expect(AIAssistant.performanceSystemPrompt.hasPrefix("Eres el asistente de Airy"))
    }
}
