import Testing
import Foundation
import CoreGraphics
@testable import DiskMapCore

struct WindMotionTests {
    @Test func ambientPausesWhenHiddenOrInactive() {
        #expect(AnimationGate.ambient(windowVisible: false, appActive: true, reduceMotion: false) == .paused)
        #expect(AnimationGate.ambient(windowVisible: true, appActive: false, reduceMotion: false) == .paused)
        #expect(AnimationGate.ambient(windowVisible: false, appActive: false, reduceMotion: true) == .paused)
        #expect(AnimationGate.ambient(windowVisible: true, appActive: true, reduceMotion: false) == .running)
    }

    @Test func reduceMotionWinsOverRunning() {
        #expect(AnimationGate.ambient(windowVisible: true, appActive: true, reduceMotion: true) == .reduced)
        #expect(AnimationGate.transient(windowVisible: true, reduceMotion: true) == .reduced)
        #expect(AnimationGate.transient(windowVisible: true, reduceMotion: false) == .running)
        #expect(AnimationGate.transient(windowVisible: false, reduceMotion: false) == .paused)
    }

    @Test func launchTimelineIsShortWithReduceMotion() {
        let running = WindMotion.launchTimeline(.running), reduced = WindMotion.launchTimeline(.reduced)
        #expect(running.gather + running.hold + running.fade <= 2.0)
        #expect(reduced.gather + reduced.hold + reduced.fade <= 0.7)
        let paused = WindMotion.launchTimeline(.paused)
        #expect(paused.gather + paused.hold + paused.fade == 0)
    }

    @Test func launchLeavesLandExactlyOnTheLogo() {
        let n = WindMotion.launchLeafCount
        let targets = AiryLogoGeometry.launchTargets(count: n)
        for i in 0..<n {
            let start = WindMotion.launchLeaf(index: i, count: n, progress: 0)
            #expect(hypot(start.x, start.y) >= 2.4)
            #expect(start.opacity == 0)
            let end = WindMotion.launchLeaf(index: i, count: n, progress: 1)
            #expect(abs(end.x - targets[i].x) < 1e-9 && abs(end.y - targets[i].y) < 1e-9)
            #expect(end.opacity == 1 && end.scale == 1)
            #expect(WindMotion.launchLeaf(index: i, count: n, progress: 0.4)
                    == WindMotion.launchLeaf(index: i, count: n, progress: 0.4))   // determinista
        }
    }

    @Test func launchLeavesTumbleIndividuallyAndLandUpright() {
        let n = WindMotion.launchLeafCount
        for progress in [0.0, 0.2, 0.4] {
            let rotations = (0..<n).map { WindMotion.launchLeaf(index: $0, count: n, progress: progress).rotation }
            // Cada hoja gira a su aire: nada de un bando apuntando igual.
            #expect(Set(rotations.map { ($0 * 100).rounded() }).count == n)
            #expect(rotations.max()! - rotations.min()! > 1)
        }
        for i in 0..<n { #expect(WindMotion.launchLeaf(index: i, count: n, progress: 1).rotation == 0) }
    }

    @Test func launchLeavesFadeOutDuringTheFadeSegment() {
        let t = WindMotion.launchTimeline(.running)
        let end = t.gather + t.hold + t.fade
        #expect(WindMotion.launchLeafFade(elapsed: 0) == 1)
        #expect(WindMotion.launchLeafFade(elapsed: t.gather + t.hold) == 1)
        #expect(abs(WindMotion.launchLeafFade(elapsed: t.gather + t.hold + t.fade / 2) - 0.5) < 1e-9)
        #expect(WindMotion.launchLeafFade(elapsed: end) == 0)
        #expect(WindMotion.launchLeafFade(elapsed: end + 5) == 0)
        #expect(WindMotion.launchLeafFade(elapsed: .nan) == 1)
    }

    @Test func orbitStaysOnTheRing() {
        for i in 0..<7 { for t in stride(from: 0.0, through: 10, by: 0.37) {
            let p = WindMotion.orbitLeaf(index: i, count: 7, time: t, radius: 100)
            #expect((92...108).contains(hypot(p.x, p.y)))
        } }
        let a = WindMotion.orbitLeaf(index: 0, count: 7, time: 0, radius: 100)
        let b = WindMotion.orbitLeaf(index: 0, count: 7, time: 1, radius: 100)
        #expect(a != b)
    }

    @Test func dissolveStartsInsideAndBlowsRightUntilGone() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 60)
        let n = WindMotion.leafCount(for: rect)
        for i in 0..<n {
            let start = WindMotion.dissolveLeaf(index: i, count: n, progress: 0, in: rect)
            #expect(rect.contains(CGPoint(x: start.x, y: start.y)))
            let xs = stride(from: 0.0, through: 1, by: 0.1).map { WindMotion.dissolveLeaf(index: i, count: n, progress: $0, in: rect).x }
            #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(WindMotion.dissolveLeaf(index: i, count: n, progress: 1, in: rect).opacity == 0)
        }
    }

    @Test func dissolveHandlesDegenerateRect() {
        let pose = WindMotion.dissolveLeaf(index: 3, count: 6, progress: 0.5, in: .zero)
        #expect([pose.x, pose.y, pose.rotation, pose.scale, pose.opacity].allSatisfy { $0.isFinite })
        #expect(WindMotion.leafCount(for: .zero) == 6)
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)) == 0)
    }

    @Test func leafCountIsClamped() {
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: 4000, height: 3000)) == 24)
        #expect(WindMotion.leafCount(for: CGRect(x: 0, y: 0, width: 20, height: 20)) == 6)
    }

    @Test func leafAwayGoesFromIdentityToGone() {
        let start = WindMotion.leafAwayTransform(progress: 0)
        #expect(start.dx == 0 && start.dy == 0 && start.rotationDegrees == 0 && start.scale == 1 && start.opacity == 1)
        let end = WindMotion.leafAwayTransform(progress: 1)
        #expect(end.dx == 220 && end.opacity == 0)
        #expect(WindMotion.leafAwayTransform(progress: 5).opacity == 0)
    }

    @Test func gustSweepsTopRowFirstAndSettles() {
        #expect(WindMotion.gustDuration(rowCount: 0) == 0)
        #expect(WindMotion.gustRowOffset(row: 0, rowCount: 5, elapsed: 0) == 0)
        #expect(WindMotion.gustRowOffset(row: 0, rowCount: 5, elapsed: 0.1) > WindMotion.gustRowOffset(row: 4, rowCount: 5, elapsed: 0.1))
        let end = WindMotion.gustDuration(rowCount: 5)
        for row in 0..<5 { #expect(abs(WindMotion.gustRowOffset(row: row, rowCount: 5, elapsed: end)) < 1e-9) }
    }

    @Test func gustDurationIsCappedForHugeLists() {
        #expect(WindMotion.gustDuration(rowCount: 500) <= WindMotion.gustMaxDuration)
        #expect(abs(WindMotion.gustRowOffset(row: 499, rowCount: 500, elapsed: WindMotion.gustMaxDuration)) < 1e-9)
    }

    @Test func gustNeedsTwoRowsAndKeepsExecutionOrder() {
        #expect(BatchMotion.gustOrder(ids: []) == nil)
        #expect(BatchMotion.gustOrder(ids: ["a"]) == nil)
        #expect(BatchMotion.gustOrder(ids: ["c", "a", "b"]) == ["c", "a", "b"])
    }

    @Test func batchTallySumsFreedAndTrashAndSaysWhichIsWhich() {
        var tally = BatchMotion.Tally()
        #expect(tally.bytes == 0 && tally.label == "liberados" && tally.help == nil)
        tally.add(.freed(1_000))
        tally.add(.blocked(reason: "abierto"))
        tally.add(.failed("sin permiso"))
        #expect(tally.bytes == 1_000 && tally.label == "liberados" && tally.help == nil)
        tally.add(.movedToTrash(500))
        #expect(tally.bytes == 1_500 && tally.freed == 1_000 && tally.movedToTrash == 500)
        #expect(tally.label == "despejados")
        #expect(tally.help == "Lo movido a la Papelera se libera al vaciarla")
        #expect(BatchMotion.tally([.freed(1), .movedToTrash(2), .freed(3)]).bytes == 6)
    }

    @Test func ambientBreezeIsSoftAndScanBreezeIsLively() {
        let ambient = WindMotion.breezeStreaks(.ambient), scan = WindMotion.breezeStreaks(.scan)
        #expect(ambient.count == 3 && scan.count == 6)
        #expect(ambient.allSatisfy { $0.opacity <= 0.06 && $0.period >= 18 })
        #expect(scan.allSatisfy { $0.period <= 6 && $0.opacity <= 0.14 })
        #expect(WindMotion.breezeStreaks(.scan) == scan)
    }

    @Test func swirlSpeedFollowsCPUAndClampsGarbage() {
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0) == 0.06)
        #expect(abs(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 1) - 0.9) < 1e-12)
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0.5) < WindMotion.swirlRevolutionsPerSecond(cpuLoad: 0.8))
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: .nan) == 0.06)
        #expect(WindMotion.swirlRevolutionsPerSecond(cpuLoad: -3) == 0.06)
        #expect(abs(WindMotion.swirlRevolutionsPerSecond(cpuLoad: 40) - 0.9) < 1e-12)
    }

    @Test func heatFollowsThermalState() {
        #expect(WindMotion.heat(for: .nominal) == 0)
        #expect(WindMotion.heat(for: .fair) == 0.35)
        #expect(WindMotion.heat(for: .serious) == 0.7)
        #expect(WindMotion.heat(for: .critical) == 1)
    }

    @Test func swirlPhaseIsContinuousWhenSpeedChanges() {
        var phase = SwirlPhase()
        _ = phase.advance(to: 0, revolutionsPerSecond: 0.1)
        let a = phase.advance(to: 1.0 / 60, revolutionsPerSecond: 0.1)
        let b = phase.advance(to: 2.0 / 60, revolutionsPerSecond: 0.9)
        #expect(abs(b - a - 2 * .pi * 0.9 / 60) < 1e-9)
    }

    @Test func swirlPhaseDoesNotJumpAfterPause() {
        var phase = SwirlPhase()
        _ = phase.advance(to: 0, revolutionsPerSecond: 0.9)
        let before = phase.advance(to: 0.016, revolutionsPerSecond: 0.9)
        let after = phase.advance(to: 120, revolutionsPerSecond: 0.9)   // dos minutos en pausa
        #expect(abs(after - before) <= 2 * .pi * 0.9 / 15 + 1e-9)
    }

    @Test func swayEndsAtRestAndDecays() {
        let keys = WindMotion.swayKeyframes
        #expect(keys.last?.degrees == 0 && keys.last?.time == 0.6)
        let amplitudes = keys.map { abs($0.degrees) }
        #expect(zip(amplitudes, amplitudes.dropFirst()).allSatisfy { $0 > $1 })
    }
}
