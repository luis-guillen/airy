import Testing
@testable import DiskMapCore

@Suite struct CleanupDisclosureTests {
    @Test func defaultsOpenSafeAndSmallYourCall() {
        let disclosure = CleanupDisclosure()
        #expect(disclosure.isOpen(.safe, count: 40))
        #expect(disclosure.isOpen(.yourCall, count: 0))
        #expect(disclosure.isOpen(.yourCall, count: CleanupDisclosure.smallGroupLimit))
        #expect(!disclosure.isOpen(.yourCall, count: CleanupDisclosure.smallGroupLimit + 1))
        #expect(!disclosure.isOpen(.doNotTouch, count: 1))
        #expect(!disclosure.isOpen(.review, count: 1))
    }

    @Test func choiceWinsOverDefault() {
        var disclosure = CleanupDisclosure()
        disclosure.toggle(.safe, count: 3)
        disclosure.toggle(.doNotTouch, count: 3)
        disclosure.toggle(.yourCall, count: 12)
        #expect(!disclosure.isOpen(.safe, count: 3))
        #expect(disclosure.isOpen(.doNotTouch, count: 3))
        #expect(disclosure.isOpen(.yourCall, count: 12))
        // An explicit choice no longer follows the size.
        #expect(disclosure.isOpen(.yourCall, count: 2))
        #expect(!disclosure.isOpen(.review, count: 1))
    }

    @Test func roundTripsThroughStoredDictionary() {
        var disclosure = CleanupDisclosure()
        disclosure.setOpen(false, for: .safe)
        disclosure.setOpen(true, for: .review)
        #expect(disclosure.stored == ["safe": false, "review": true])
        let restored = CleanupDisclosure(stored: disclosure.stored.merging(["bogus": true]) { a, _ in a })
        #expect(restored == disclosure)
        #expect(!restored.isOpen(.safe, count: 1))
        #expect(restored.isOpen(.review, count: 1))
    }

    @Test func groupFollowsRisk() {
        #expect(CleanupDisclosure.Group(risk: .safe) == .safe)
        #expect(CleanupDisclosure.Group(risk: .yourCall) == .yourCall)
        #expect(CleanupDisclosure.Group(risk: .doNotTouch) == .doNotTouch)
    }
}
