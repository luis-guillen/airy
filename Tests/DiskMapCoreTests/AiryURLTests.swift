import Testing
import Foundation
@testable import DiskMapCore

@Suite struct AiryURLTests {
    @Test func roundTripsEveryCommand() {
        let commands: [AiryURLCommand] = [
            .propose(target: .item("user-logs"), reason: "takes 2 GB & “not needed”", agent: "claude-code"),
            .propose(target: .path("/Users/x/Música & Co/ñ#1"), reason: "", agent: nil),
            .show(path: "/Users/x/Música & Co/ñ#1"),
            .show(path: "/Users"),
            .rescan,
        ]
        for command in commands {
            #expect(AiryURLCommand(url: command.url) == command, "\(command.url)")
        }
    }

    @Test func quitURLRoundTripsAndRejectsHostile() {
        let commands: [AiryURLCommand] = [
            .proposeQuit(app: "com.spotify.client", reason: "heavy & “a lot”", agent: "claude-code"),
            .proposeQuit(app: "Google Chrome", reason: "", agent: nil),
        ]
        for command in commands { #expect(AiryURLCommand(url: command.url) == command, "\(command.url)") }
        #expect(AiryURLCommand.proposeQuit(app: "com.spotify.client", reason: "pesa", agent: "test-client").url
                == URL(string: "airy://quit?app=com.spotify.client&reason=pesa&agent=test-client")!)
        let long = String(repeating: "a", count: 201)
        for hostile in ["airy://quit", "airy://quit?app=", "airy://quit?app=a%0Ab", "airy://quit?app=\(long)",
                        "airy://quit?app=a&app=b", "airy://quit/x?app=a"] {
            #expect(AiryURLCommand(url: URL(string: hostile)!) == nil, "\(hostile)")
        }
        #expect(AiryURLCommand(url: URL(string: "airy://quit?app=\(String(repeating: "a", count: 200))")!) != nil)
        // Reason and agent are sanitized as in propose.
        #expect(AiryURLCommand(url: URL(string: "airy://quit?app=x&reason=a%0Ab&agent=")!)
                == .proposeQuit(app: "x", reason: "a b", agent: nil))
    }

    @Test func uninstallURLRoundTrip() {
        let commands: [AiryURLCommand] = [
            .uninstall(bundleID: "com.example.foo", reason: "you do not use it & “heavy”", agent: "claude-code"),
            .uninstall(bundleID: "org.x-y_z.App2", reason: "", agent: nil),
        ]
        for command in commands { #expect(AiryURLCommand(url: command.url) == command, "\(command.url)") }
        #expect(AiryURLCommand.uninstall(bundleID: "com.example.foo", reason: "x", agent: "test-client").url
                == URL(string: "airy://uninstall?bundle=com.example.foo&reason=x&agent=test-client")!)
        #expect(AiryURLCommand(url: URL(string: "airy://uninstall?bundle=a&reason=a%0Ab&agent=")!)
                == .uninstall(bundleID: "a", reason: "a b", agent: nil))
    }

    @Test func uninstallURLRejectsHostileBundleID() {
        let long = String(repeating: "a", count: 201)
        for hostile in ["airy://uninstall", "airy://uninstall?bundle=", "airy://uninstall?bundle=../x",
                        "airy://uninstall?bundle=a%20b", "airy://uninstall?bundle=a%0Ab", "airy://uninstall?bundle=\(long)",
                        "airy://uninstall?bundle=.a", "airy://uninstall?bundle=a/b", "airy://uninstall?bundle=a&bundle=b",
                        "airy://uninstall?reason=x"] {
            #expect(AiryURLCommand(url: URL(string: hostile)!) == nil, "\(hostile)")
        }
        #expect(AiryURLCommand(url: URL(string: "airy://uninstall?bundle=\(String(repeating: "a", count: 200))")!) != nil)
    }

    @Test func parsesDocumentedForms() {
        #expect(AiryURLCommand(url: URL(string: "airy://rescan")!) == .rescan)
        #expect(AiryURLCommand(url: URL(string: "airy://show?path=/Users")!) == .show(path: "/Users"))
        #expect(AiryURLCommand(url: URL(string: "airy://propose?item=user-logs&reason=prueba&agent=manual")!)
                == .propose(target: .item("user-logs"), reason: "prueba", agent: "manual"))
        #expect(AiryURLCommand(url: URL(string: "AIRY://Rescan")!) == .rescan)
    }

    @Test func parseRejectsHostileInput() {
        let long = String(repeating: "a", count: 1025)
        let hostile = [
            "airy://propose?item=a&path=/x&reason=r", "airy://propose?reason=r", "airy://propose?path=x&reason=r",
            "airy://propose?item=&reason=r", "airy://propose?item=a&item=b",
            "airy://show?path=/a/../b", "airy://show?path=/a%0Ab", "airy://show?path=/a%00b",
            "airy://show?path=/a%E2%80%A8b", "airy://show", "airy://show?path=", "airy://show?path=/a/..",
            "airy://show?path=/\(long)", "airy://propose?item=\(String(repeating: "i", count: 201))",
            "airy://propose?item=a%0Ab", "airy://delete?path=/x", "airy://empty-trash", "http://propose?item=a",
            "file:///etc/passwd", "airy://rescan/extra",
        ]
        for s in hostile {
            #expect(AiryURLCommand(url: URL(string: s)!) == nil, "\(s)")
        }
        // Right at the limit it does fit.
        let ok = "/" + String(repeating: "a", count: 1023)
        #expect(AiryURLCommand(url: URL(string: "airy://show?path=\(ok)")!) == .show(path: ok))
    }

    @Test func reasonIsSanitisedAndTruncated() {
        var raw = ""
        for i in 0..<10_000 { raw += i % 7 == 0 ? "\n" : "x" }
        var components = URLComponents(string: "airy://propose")!
        components.queryItems = [URLQueryItem(name: "item", value: "a"), URLQueryItem(name: "reason", value: raw),
                                 URLQueryItem(name: "agent", value: "  ag\u{7}ent\n" + String(repeating: "z", count: 200))]
        guard case .propose(_, let reason, let agent)? = AiryURLCommand(url: components.url!) else {
            Issue.record("should be accepted with a long reason"); return
        }
        #expect(reason.count <= 501)
        #expect(reason.hasSuffix("…"))
        #expect(!reason.contains("\n"))
        #expect((agent?.count ?? 0) <= 65)
        #expect(agent?.hasPrefix("ag ent") == true)
        #expect(agent?.contains("\n") == false)
    }

    @Test func reasonNeutralisesInvisibleControlsAndTrims() {
        // Line/paragraph separators and direction controls (they spoof text in the sheet).
        var components = URLComponents(string: "airy://propose")!
        components.queryItems = [URLQueryItem(name: "item", value: "a"),
                                 URLQueryItem(name: "reason", value: "  uno\u{2028}dos\u{202E}tres  ")]
        #expect(AiryURLCommand(url: components.url!) == .propose(target: .item("a"), reason: "uno dos tres", agent: nil))
    }
}

@Suite struct URLProposalPolicyTests {
    @Test func rateLimiterDropsBurstsAndRecovers() {
        var limiter = URLCommandRateLimiter(limit: 3, window: 10)
        let t0 = Date(timeIntervalSince1970: 1_000)
        var allowed: [Bool] = []
        for offset in [0, 1, 2, 3, 9.9, 10, 10.5] { allowed.append(limiter.allow(at: t0.addingTimeInterval(offset))) }
        // Three in a row; then nothing until the first one leaves the window (t0 + 10).
        #expect(allowed == [true, true, true, false, false, true, false])
    }

    @Test func proposalNeverReplacesAnOpenSheet() {
        #expect(URLProposalPolicy.refusal(sheetOpen: true, busy: false) == URLProposalPolicy.sheetOpen)
        #expect(URLProposalPolicy.refusal(sheetOpen: true, busy: true) == URLProposalPolicy.sheetOpen)
        #expect(URLProposalPolicy.refusal(sheetOpen: false, busy: true) == URLProposalPolicy.busy)
        #expect(URLProposalPolicy.refusal(sheetOpen: false, busy: false) == nil)
    }

    @Test func agentNameIsShownAsAClaim() {
        let subtitle = URLProposalPolicy.warningSubtitle(agent: "Claude Code", reason: "old cache")
        #expect(subtitle == "Claims to come from “Claude Code” (Airy cannot verify it) · old cache")
        #expect(URLProposalPolicy.warningSubtitle(agent: "  ", reason: "")
                == "Proposed by an external app · no reason")
        #expect(URLProposalPolicy.warningTitle() == "Proposal received by link")
        let context = URLProposalPolicy.context(runID: UUID(), agent: nil)
        #expect(context.actor == .user && context.proposedBy == nil && context.proposedVia == "url-unverified")
    }

    @Test func activityShowsUnverifiedAuthorship() {
        func record(_ actor: OperationActor, by: String?, via: String?) -> OperationRecord {
            OperationRecord(runID: UUID(), date: Date(), actor: actor, action: "clean", itemID: nil, title: "t",
                            paths: [], command: nil, dryRun: false, outcome: "freed", bytes: 0, message: nil,
                            proposedBy: by, proposedVia: via)
        }
        let viaURL = record(.user, by: nil, via: OperationContext.viaUnverifiedURL)
        #expect(URLProposalPolicy.isAgentActivity(viaURL))
        #expect(URLProposalPolicy.activityAuthor(viaURL) == "By link from an external app · confirmed by you")
        #expect(URLProposalPolicy.activityAuthor(record(.agent(client: "codex"), by: nil, via: nil)) == "codex")
        #expect(!URLProposalPolicy.isAgentActivity(record(.user, by: nil, via: nil)))
    }

    @Test func shortPathTrimsLongAttackerPaths() {
        #expect(URLProposalPolicy.shortPath("/a/b") == "/a/b")
        let long = "/" + String(repeating: "x", count: 300)
        let short = URLProposalPolicy.shortPath(long)
        #expect(short.count == 80 && short.hasPrefix("…"))
    }
}
