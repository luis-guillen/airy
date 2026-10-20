import Testing
@testable import DiskMapCore

@Suite struct DiskUsageBreakdownTests {
    // Cifras reales de este Mac (df -k / y URLResourceValues), redondeadas.
    @Test func realUsedIncludesPurgeable() {
        let usage = DiskUsageBreakdown(totalBytes: 494_000, availableBytes: 118_000,
                                       importantAvailableBytes: 149_000, analyzedBytes: 300_000)
        #expect(usage.free == 118_000)
        #expect(usage.used == 376_000)
        #expect(usage.purgeable == 31_000)
        #expect(usage.other == 45_000)
        #expect(usage.analyzedShown + (usage.other ?? 0) + usage.purgeable + usage.free == usage.total)
    }

    @Test func analyzedAboveUsedShowsUnknownRemainder() {
        // Analizar `/` cuenta macOS y apps: lo analizado puede pasar de lo usado no purgable.
        let usage = DiskUsageBreakdown(totalBytes: 1_000, availableBytes: 200,
                                       importantAvailableBytes: 300, analyzedBytes: 900)
        #expect(usage.other == nil)
        #expect(usage.analyzed == 900)
        #expect(usage.analyzedShown == 700)
        #expect(usage.analyzedShown + usage.purgeable + usage.free == usage.total)
        let ring = usage.ringFractions
        #expect(abs(ring.analyzed + ring.other + ring.purgeable - usage.usedFraction) < 1e-9)
    }

    @Test func analyzedEqualToRestIsUnknownNotZero() {
        let usage = DiskUsageBreakdown(totalBytes: 1_000, availableBytes: 200,
                                       importantAvailableBytes: 200, analyzedBytes: 800)
        #expect(usage.other == nil)
    }

    @Test func importantBelowAvailableMeansNoPurgeable() {
        let usage = DiskUsageBreakdown(totalBytes: 1_000, availableBytes: 400,
                                       importantAvailableBytes: 350, analyzedBytes: 100)
        #expect(usage.purgeable == 0)
        #expect(usage.other == 500)
    }

    @Test func unknownVolumeIsAllZero() {
        let usage = DiskUsageBreakdown(totalBytes: 0, availableBytes: 0, importantAvailableBytes: 0, analyzedBytes: 50)
        #expect(usage.total == 0 && usage.used == 0 && usage.free == 0 && usage.purgeable == 0)
        #expect(usage.ringFractions == (0, 0, 0))
        #expect(usage.usedFraction == 0)
    }

    @Test func clampsOutOfRangeValues() {
        let usage = DiskUsageBreakdown(totalBytes: 1_000, availableBytes: 5_000,
                                       importantAvailableBytes: 9_000, analyzedBytes: -3)
        #expect(usage.free == 1_000)
        #expect(usage.used == 0)
        #expect(usage.purgeable == 0)
        #expect(usage.analyzed == 0)
    }
}
