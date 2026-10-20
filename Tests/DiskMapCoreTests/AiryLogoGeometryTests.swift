import Testing
import Foundation
import CoreGraphics
@testable import DiskMapCore

struct AiryLogoGeometryTests {
    @Test func fullHasThreeConcentricArcsAndLeaves() {
        let arcs = AiryLogoGeometry.arcs(.full)
        #expect(arcs.count == 3)
        #expect(zip(arcs, arcs.dropFirst()).allSatisfy { $0.radius > $1.radius })
        #expect(arcs.allSatisfy { $0.opacity > 0 && $0.opacity < 1 })
        let leaves = AiryLogoGeometry.leaves(.full)
        #expect(leaves.count == 3)
        #expect(leaves.allSatisfy { [0xFFFFFF, 0xBFE9FF].contains($0.tint) })
    }

    @Test func smallHasOneThickArcAndOneLeaf() {
        let thickest = AiryLogoGeometry.arcs(.full).map(\.lineWidth).max()!
        #expect(AiryLogoGeometry.arcs(.small).count == 1)
        #expect(AiryLogoGeometry.arcs(.small)[0].lineWidth >= 2 * thickest)
        #expect(AiryLogoGeometry.leaves(.small).count == 1)
    }

    @Test func variantSwitchesAt64Pixels() {
        for px in [16.0, 32, 64] { #expect(AiryLogoGeometry.variant(forPixelSize: px) == .small) }
        for px in [65.0, 128, 1024] { #expect(AiryLogoGeometry.variant(forPixelSize: px) == .full) }
    }

    @Test(arguments: [AiryLogoGeometry.Variant.full, .small])
    func leavesSitAtArcEnds(_ variant: AiryLogoGeometry.Variant) {
        for (arc, leaf) in zip(AiryLogoGeometry.arcs(variant), AiryLogoGeometry.leaves(variant)) {
            let end = (arc.startDegrees + arc.sweepDegrees).truncatingRemainder(dividingBy: 360)
            #expect(abs(((end + 360).truncatingRemainder(dividingBy: 360)) - leaf.angleDegrees) < 1e-9)
            #expect(arc.radius == leaf.radius)
        }
    }

    @Test(arguments: [AiryLogoGeometry.Variant.full, .small])
    func everythingFitsInsideTheSquircle(_ variant: AiryLogoGeometry.Variant) {
        let limit = AiryLogoGeometry.unit - 40
        for arc in AiryLogoGeometry.arcs(variant) { #expect(arc.radius + arc.lineWidth / 2 <= limit) }
        for leaf in AiryLogoGeometry.leaves(variant) { #expect(leaf.radius + leaf.length / 2 <= limit) }
    }

    @Test func leafPathSpansItsLength() {
        let box = AiryLogoGeometry.leafPath(length: 100, width: 40).boundingBoxOfPath
        #expect(abs(box.width - 100) < 0.5)
        #expect(box.height > 20 && box.height < 40)
    }

    @Test func launchTargetsStartWithTheLeavesAndStayInside() {
        let targets = AiryLogoGeometry.launchTargets(count: 18)
        #expect(targets.count == 18)
        for (target, leaf) in zip(targets, AiryLogoGeometry.leaves(.full)) {
            let c = AiryLogoGeometry.leafCenter(leaf)
            #expect(abs(target.x - (c.x - 512) / 412) < 1e-9 && abs(target.y - (c.y - 512) / 412) < 1e-9)
        }
        #expect(targets.allSatisfy { hypot($0.x, $0.y) <= 1 })
    }

    @Test func iconScriptCarriesTheGeometryFingerprint() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-icon.swift")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("// logo-geometry: \(AiryLogoGeometry.fingerprint)"))
    }
}
