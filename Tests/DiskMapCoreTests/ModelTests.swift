import Testing
import Foundation
@testable import DiskMapCore

@Suite struct ModelTests {
    @Test func strictestPicksHigher() {
        #expect(Risk.strictest(.safe, .doNotTouch) == .doNotTouch)
        #expect(Risk.strictest(.yourCall, .safe) == .yourCall)
    }

    @Test func pathJoinsParents() {
        let root = FileNode(name: "/", isDirectory: true)
        let users = FileNode(name: "Users", isDirectory: true)
        let ana = FileNode(name: "ana", isDirectory: true)
        users.parent = root; root.children = [users]
        ana.parent = users; users.children = [ana]
        #expect(root.path == "/")
        #expect(ana.path == "/Users/ana")
    }

    @Test func dominantKindUsesKindBytes() {
        let node = FileNode(name: "x", isDirectory: true)
        node.kindBytes[ContentKind.allCases.firstIndex(of: .video)!] = 10
        node.kindBytes[ContentKind.allCases.firstIndex(of: .code)!] = 30
        #expect(node.dominantKind == .code)
    }

    @Test func emptyKindBytesFallsBackToOwnKind() {
        let node = FileNode(name: "f", isDirectory: false, kind: .images)
        #expect(node.kindBytes.count == ContentKind.allCases.count)
        #expect(node.dominantKind == .images)
    }

    @Test func idsAreUnique() {
        #expect(FileNode(name: "a", isDirectory: false).id != FileNode(name: "a", isDirectory: false).id)
    }

    @Test func formatsBytes() {
        #expect(Format.bytes(1_500_000_000) == "1.5 GB")
    }

    @Test func relativeDateNilIsDash() {
        #expect(Format.relativeDate(nil) == "—")
        let past = Date(timeIntervalSinceNow: -3 * 86_400)
        #expect(Format.relativeDate(past).contains("3 days"))
    }
}
