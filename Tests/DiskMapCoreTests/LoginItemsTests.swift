import Foundation
import Testing
@testable import DiskMapCore

@Suite struct LoginItemsTests {
    private func makeDir(_ plists: [String: Any]) throws -> String {
        let dir = TestTemp.path("airy-login")
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

    @Test func oversizedPlistSkipped() throws {
        let dir = try makeDir([:])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pad = String(repeating: "a", count: 1_100_000)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/nope/big", "Pad": pad], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: dir + "/big.plist"))
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func fifoNamedPlistSkippedWithoutHanging() throws {
        let dir = try makeDir([:])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(mkfifo(dir + "/pipe.plist", 0o600) == 0)
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
    }

    @Test func symlinkToDeviceSkippedAndSymlinkToFileFollowed() throws {
        let dir = try makeDir([:])
        let target = try makeDir(["real.plist": ["Label": "lnk", "Program": "/nope/l"]])
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.createSymbolicLink(atPath: dir + "/zero.plist", withDestinationPath: "/dev/zero")
        #expect(LoginItemsAudit.broken(in: [dir]).isEmpty)
        try FileManager.default.createSymbolicLink(atPath: dir + "/ok.plist", withDestinationPath: target + "/real.plist")
        #expect(LoginItemsAudit.broken(in: [dir]).map(\.label) == ["lnk"])
    }

    @Test func mountedVolumeMissingProgramIsReported() throws {
        let dir = try makeDir(["v.plist": ["Program": "/Volumes/Disco/app"]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let items = LoginItemsAudit.broken(in: [dir], fileExists: { $0 == "/Volumes/Disco" })
        #expect(items.map(\.missingProgram) == ["/Volumes/Disco/app"])
    }

    @Test func emptyProgramFallsBackToArguments() throws {
        let dir = try makeDir(["p.plist": ["Program": "", "ProgramArguments": ["/nope/fb"]]])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(LoginItemsAudit.broken(in: [dir]).map(\.missingProgram) == ["/nope/fb"])
    }
}
