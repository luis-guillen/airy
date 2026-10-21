import Foundation
import Testing
@testable import DiskMapCore

private struct FakeAppUsage: AppUsageReading {
    var dates: [String: Date] = [:]
    func lastUsed(bundlePath: String) -> Date? { dates[bundlePath] }
}

private func makeTempDir() throws -> String {
    let dir = TestTemp.path("airy-inventory")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makeApp(_ path: String, id: String? = "com.example.foo", name: String? = nil,
                     display: String? = nil, version: String? = nil, plistPath: String = "Contents/Info.plist") throws
    -> String {
    var dict: [String: Any] = [:]
    if let id { dict["CFBundleIdentifier"] = id }
    if let name { dict["CFBundleName"] = name }
    if let display { dict["CFBundleDisplayName"] = display }
    if let version { dict["CFBundleShortVersionString"] = version }
    let target = path + "/" + plistPath
    try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: target))
    return path
}

@Test func findsAppsWithIDNameAndVersion() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try makeApp(root + "/Foo.app", id: "com.example.foo", name: "Foo", version: "1.2")
    let date = Date(timeIntervalSince1970: 1_000)
    let inventory = AppInventory(roots: [root], usage: FakeAppUsage(dates: [root + "/Foo.app": date]),
                                 casks: ["Foo.app": "foo-cask"])
    let snapshot = await inventory.snapshot()
    #expect(snapshot.complete)
    #expect(snapshot.problems.isEmpty)
    #expect(snapshot.apps == [AppRecord(
        bundleID: "com.example.foo", name: "Foo", version: "1.2", path: root + "/Foo.app", helperBundleIDs: [],
        isSystem: false, isAppStore: false, caskToken: "foo-cask", lastUsed: date)])
}

@Test func vendorFolderDepthTwoFoundDepthFourNot() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try makeApp(root + "/Vendor/Two.app", id: "com.example.two")
    try makeApp(root + "/a/b/Three.app", id: "com.example.three")
    try makeApp(root + "/a/b/c/Four.app", id: "com.example.four")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.apps.map(\.bundleID) == ["com.example.three", "com.example.two"])
    #expect(snapshot.complete)
}

@Test func helpersAreCollected() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let app = try makeApp(root + "/Foo.app", id: "com.Example.Foo")
    try makeApp(app + "/Contents/Library/LoginItems/Helper.app", id: "com.Example.Foo.Helper")
    try makeApp(app + "/Contents/Helpers/Agent.app", id: "com.example.foo.agent")
    try makeApp(app + "/Contents/XPCServices/Svc.xpc", id: "com.example.foo.svc")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.apps.first?.helperBundleIDs == [
        "com.Example.Foo.Helper", "com.example.foo.agent", "com.example.foo.svc",
    ])
    #expect(snapshot.installedIDs == [
        "com.example.foo", "com.example.foo.helper", "com.example.foo.agent", "com.example.foo.svc",
    ])
}

@Test func unreadablePlistMakesSnapshotIncomplete() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Bad.app/Contents", withIntermediateDirectories: true)
    try Data("not a plist".utf8).write(to: URL(fileURLWithPath: root + "/Bad.app/Contents/Info.plist"))
    try makeApp(root + "/Good.app", id: "com.example.good")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
    #expect(!snapshot.problems.isEmpty)
    #expect(snapshot.apps.map(\.bundleID) == ["com.example.good"])
}

@Test func unreadableRootMakesSnapshotIncomplete() async throws {
    guard geteuid() != 0 else {
        Issue.record("Test skipped: chmod 000 does not block the root user.")
        return
    }
    let root = try makeTempDir()
    try makeApp(root + "/Foo.app")
    chmod(root, 0o000)
    defer {
        chmod(root, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
    #expect(!snapshot.problems.isEmpty)
}

@Test func missingRootIsFine() async throws {
    let root = TestTemp.path("airy-inventory-missing")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.complete)
    #expect(snapshot.problems.isEmpty)
    #expect(snapshot.apps.isEmpty)
}

@Test func budgetExhaustedIsIncomplete() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try makeApp(root + "/Foo.app")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage(), budget: .zero).snapshot()
    #expect(!snapshot.complete)
    #expect(!snapshot.problems.isEmpty)
}

@Test func appStoreAndSystemFlags() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try makeApp(root + "/Store.app", id: "com.example.store")
    try FileManager.default.createDirectory(atPath: store + "/Contents/_MASReceipt", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: store + "/Contents/_MASReceipt/receipt"))
    try makeApp(root + "/Safari.app", id: "com.apple.Safari")
    try makeApp(root + "/Plain.app", id: "com.example.plain")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    let byID = Dictionary(uniqueKeysWithValues: snapshot.apps.map { ($0.bundleID, $0) })
    #expect(byID["com.example.store"]?.isAppStore == true)
    #expect(byID["com.example.store"]?.isSystem == false)
    #expect(byID["com.apple.Safari"]?.isSystem == true)
    #expect(byID["com.apple.Safari"]?.isAppStore == false)
    #expect(byID["com.example.plain"]?.isSystem == false)
}

@Test func iOSWrapperUsesInnerPlist() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try makeApp(root + "/Phone.app/Wrapper/Phone.app", id: "com.example.ios", name: "Phone Game",
                version: "3.0", plistPath: "Info.plist")
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.complete)
    #expect(snapshot.apps.first?.bundleID == "com.example.ios")
    #expect(snapshot.apps.first?.name == "Phone Game")
    #expect(snapshot.apps.first?.version == "3.0")
}

@Test func nameVariantsSkipShortAndGeneric() {
    #expect(AppInventory.nameVariants("Foo Bar") == [
        "Foo Bar", "FooBar", "Foo_Bar", "Foo-Bar", "foo bar", "foobar", "foo_bar", "foo-bar",
    ])
    #expect(AppInventory.nameVariants("Notes").isEmpty)
    #expect(AppInventory.nameVariants("Abc").isEmpty)
    #expect(AppInventory.nameVariants("Helper").isEmpty)
}

@Test func caskTokenFromBrewJSON() {
    let json = #"{"casks":[{"token":"visual-studio-code","artifacts":[{"app":["Visual Studio Code.app"]}]}]}"#
    #expect(HomebrewCasks.parse(json) == ["Visual Studio Code.app": "visual-studio-code"])
    let target = #"{"casks":[{"token":"x","artifacts":[{"app":[{"target":"X Real.app"}]},{"zap":[]}]}]}"#
    #expect(HomebrewCasks.parse(target) == ["X Real.app": "x"])
}

@Test func brewMissingGivesNil() async {
    let runner = FakeRunner()
    #expect(await HomebrewCasks.installed(runner: runner) == nil)
    #expect(runner.calls.isEmpty)
}

@Test func corruptHelperPlistMakesSnapshotIncomplete() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let app = try makeApp(root + "/Foo.app", id: "com.example.foo")
    try FileManager.default.createDirectory(
        atPath: app + "/Contents/Library/LoginItems/Bad.app/Contents", withIntermediateDirectories: true)
    try Data("roto".utf8).write(
        to: URL(fileURLWithPath: app + "/Contents/Library/LoginItems/Bad.app/Contents/Info.plist"))
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
    #expect(!snapshot.problems.isEmpty)
}

@Test func unlistableHelperFolderMakesSnapshotIncomplete() async throws {
    guard geteuid() != 0 else {
        Issue.record("Test skipped: chmod 000 does not block the root user.")
        return
    }
    let root = try makeTempDir()
    let app = try makeApp(root + "/Foo.app", id: "com.example.foo")
    let helpers = app + "/Contents/Helpers"
    try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
    chmod(helpers, 0o000)
    defer {
        chmod(helpers, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
}

@Test func symlinkedAppIsIncludedAndBrokenOneIsIncomplete() async throws {
    let root = try makeTempDir()
    let outside = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: outside)
    }
    try makeApp(outside + "/Real.app", id: "com.example.real")
    try FileManager.default.createSymbolicLink(atPath: root + "/Link.app", withDestinationPath: outside + "/Real.app")
    var snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.complete)
    #expect(snapshot.apps.map(\.bundleID) == ["com.example.real"])
    try FileManager.default.createSymbolicLink(atPath: root + "/Broken.app", withDestinationPath: outside + "/Nada.app")
    snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
    #expect(!snapshot.problems.isEmpty)
}

@Test func symlinkedFolderIsNotFollowedAndStaysComplete() async throws {
    let root = try makeTempDir()
    let outside = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: outside)
    }
    try makeApp(outside + "/Real.app", id: "com.example.real")
    try FileManager.default.createSymbolicLink(atPath: root + "/Folder", withDestinationPath: outside)
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(snapshot.complete)
    #expect(snapshot.apps.isEmpty)
}

@Test func unreadableNestedFolderMakesSnapshotIncomplete() async throws {
    guard geteuid() != 0 else {
        Issue.record("Test skipped: chmod 000 does not block the root user.")
        return
    }
    let root = try makeTempDir()
    let vendor = root + "/Vendor"
    try FileManager.default.createDirectory(atPath: vendor, withIntermediateDirectories: true)
    chmod(vendor, 0o000)
    defer {
        chmod(vendor, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }
    let snapshot = await AppInventory(roots: [root], usage: FakeAppUsage()).snapshot()
    #expect(!snapshot.complete)
}

@Test func brewFailureGivesNil() async {
    let failing = FakeRunner(resolved: ["brew": "/fake/brew"], outputs: [
        "/fake/brew info --cask --installed --json=v2": CommandOutput(status: 1, stdout: "{}", stderr: "boom"),
    ])
    #expect(await HomebrewCasks.installed(runner: failing) == nil)
    let json = #"{"casks":[{"token":"x","artifacts":[{"app":["X.app"]}]}]}"#
    let ok = FakeRunner(resolved: ["brew": "/fake/brew"], outputs: [
        "/fake/brew info --cask --installed --json=v2": CommandOutput(status: 0, stdout: json, stderr: ""),
    ])
    #expect(await HomebrewCasks.installed(runner: ok) == ["X.app": "x"])
}
