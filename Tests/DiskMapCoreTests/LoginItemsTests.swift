import Foundation
import Testing
@testable import DiskMapCore

@Suite struct LoginItemsTests {
    private func makeDir(_ plists: [String: Any]) throws -> String {
        let dir = NSTemporaryDirectory() + "airy-login-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, value) in plists {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        return dir
    }

    @Test func reportsMissingProgram() throws {
        let dir = try makeDir(["a.plist": ["Label": "com.x.a", "Program": "/nope/x"]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let items = LoginItemsAudit.broken(in: [dir])
        #expect(items.count == 1)
        #expect(items.first?.label == "com.x.a")
        #expect(items.first?.missingProgram == "/nope/x")
        #expect(items.first?.plistPath == dir + "/a.plist")
    }

    @Test func usesFirstProgramArgument() throws {
        let dir = try makeDir(["b.plist": ["ProgramArguments": ["/nope/y", "--flag"]]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let items = LoginItemsAudit.broken(in: [dir])
        #expect(items.count == 1)
        #expect(items.first?.missingProgram == "/nope/y")
        #expect(items.first?.label == "b")
    }

    @Test func existingProgramIsFine() throws {
        let dir = try makeDir(["c.plist": ["Label": "c", "Program": "/bin/ls"]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func relativeProgramIgnored() throws {
        let dir = try makeDir(["d.plist": ["ProgramArguments": ["node", "x.js"]]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func unmountedVolumeIgnored() throws {
        let dir = try makeDir(["e.plist": ["Program": "/Volumes/NoExiste/app"]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func unreadablePlistSkipped() throws {
        let dir = try makeDir([:])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data([0xFF, 0x00, 0x13, 0x37]).write(to: URL(fileURLWithPath: dir + "/junk.plist"))
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func auditNeverDeletes() throws {
        let dir = try makeDir(["f.plist": ["Program": "/nope/z"], "g.plist": ["Program": "/bin/ls"]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func snapshot() throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            return try Dictionary(uniqueKeysWithValues: names.map {
                ($0, try Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0)))
            })
        }
        let before = try snapshot()
        _ = LoginItemsAudit.broken(in: [dir])
        #expect(try snapshot() == before)
    }
}
