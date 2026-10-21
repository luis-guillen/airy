import Foundation
import Testing
@testable import DiskMapCore

/// `ProtectionMatch.Scope`: display information only. Pure path logic, nothing touches the disk.
@Suite struct ProtectionScopeTests {
    let home = "/Users/tester"
    let protections = HardProtections.standard

    private func contentsProtected(_ path: String) -> Bool {
        protections.contentsAreProtected(path: path, home: home, catalog: nil)
    }

    @Test func folderOnlyProtections() {
        for path in ["/Users", home, "/Users/someone-else", home + "/Library", home + "/Documents",
                     home + "/Library/Caches", home + "/Library/Application Support", "/"] {
            #expect(!contentsProtected(path), "\(path)")
            #expect(protections.match(canonicalPath: path, home: home, catalog: nil)?.scope == .folderOnly, "\(path)")
        }
    }

    @Test func folderAndContentsProtections() {
        for path in ["/System", "/Library", "/usr", home + "/Library/Mail", home + "/Library/Keychains",
                     home + "/Library/Keychains/login.keychain-db", home + "/.ssh",
                     home + "/Library/Application Support/Google/Chrome/Default",
                     home + "/Library/Application Support/Firefox/Profiles/abc.default",
                     home + "/Library/Safari"] {
            #expect(contentsProtected(path), "\(path)")
            #expect(protections.match(canonicalPath: path, home: home, catalog: nil)?.scope == .folderAndContents,
                    "\(path)")
        }
    }

    @Test func scopeNeverChangesWhatIsProtected() {
        // The probe is only a display question: the folder stays protected, its children stay as they were.
        for path in ["/Users", home, home + "/Library"] {
            #expect(protections.match(canonicalPath: path, home: home, catalog: nil) != nil, "\(path)")
        }
        #expect(protections.match(canonicalPath: home + "/Library/Caches/com.example.app", home: home,
                                  catalog: nil) == nil)
        #expect(protections.match(canonicalPath: home + "/Library/Mail/V10", home: home, catalog: nil) != nil)
    }

    @Test func probeNameMatchesNothingByItself() {
        #expect(protections.matches(canonicalPath: "/tmp-free/" + HardProtections.contentsProbeName, home: home,
                                    catalog: nil).isEmpty)
        #expect(HardProtections.sensitiveAppName(HardProtections.contentsProbeName) == nil)
    }

    @Test func userProtectionScope() {
        var settings = AirySettings()
        settings.protectedPaths = ["~/Work/secret"]
        let classifier = RiskClassifier(catalog: Catalog(entries: []), settings: settings, home: home)
        // A parent of what the user protected: only the folder as a whole.
        #expect(classifier.classify(path: home + "/Work").protection?.scope == .folderOnly)
        // The protected folder itself and what is inside it.
        #expect(classifier.classify(path: home + "/Work/secret").protection?.scope == .folderAndContents)
        #expect(classifier.classify(path: home + "/Work/secret/app").protection?.scope == .folderAndContents)
    }

    @Test func scopeSentences() {
        let folder = ProtectionMatch(source: .airy, pattern: "/Users", reason: "r", rule: .critical, scope: .folderOnly)
        let sealed = ProtectionMatch(source: .airy, pattern: "/System", reason: "r", rule: .sealedSystem)
        #expect(CleanupBoard.protectionScopeText(folder)
            == "Airy won’t delete this whole folder, but you can clean what’s inside.")
        #expect(CleanupBoard.protectionScopeText(sealed) == "Neither this folder nor anything inside it is deleted.")
    }
}
