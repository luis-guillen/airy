import Testing
import CoreGraphics
import Foundation
@testable import DiskMapCore

struct SpringCurveTests {
    let spring = SpringCurve(response: 0.45, dampingFraction: 0.82)

    @Test func startsAtZeroAndSettlesAtOne() {
        #expect(spring.value(at: 0) == 0)
        #expect(spring.value(at: -1) == 0)
        #expect(abs(spring.value(at: 3) - 1) < 1e-6)
        #expect(abs(spring.value(at: spring.settlingDuration) - 1) < 0.002)
    }

    /// Mismo oscilador amortiguado que `.spring(response:dampingFraction:)` desde reposo.
    @Test func matchesDampedOscillatorClosedForm() {
        // ω0 = 2π/0,45; ζ = 0,82 → x(0,1) ≈ 0,4513 (calculado a mano).
        #expect(abs(spring.value(at: 0.1) - 0.4513) < 0.002)
    }

    @Test func overshootIsSmallAndRealistic() {
        let samples = stride(from: 0.0, through: 1.5, by: 0.002).map { spring.value(at: $0) }
        let peak = samples.max() ?? 0
        #expect(peak > 1.0)        // subamortiguado: pasa un pelo
        #expect(peak < 1.02)       // ζ = 0,82 → ≈ 1,1 %
    }

    @Test func settlingDurationIsAboutSixTenths() {
        #expect(spring.settlingDuration > 0.45 && spring.settlingDuration < 0.9)
    }

    @Test func criticallyAndOverDampedDoNotOvershoot() {
        for zeta in [1.0, 1.4] {
            let s = SpringCurve(response: 0.4, dampingFraction: zeta)
            let values = stride(from: 0.0, through: 2.0, by: 0.01).map { s.value(at: $0) }
            #expect((values.max() ?? 2) <= 1.0 + 1e-9)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
            #expect(abs(s.value(at: 4) - 1) < 1e-3)
        }
    }
}

struct RectMathTests {
    let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let focus = CGRect(x: 200, y: 100, width: 100, height: 50)

    @Test func mapSendsSourceOntoDestination() {
        #expect(RectMath.map(focus, from: focus, to: canvas) == canvas)
        let inner = CGRect(x: 250, y: 125, width: 10, height: 5)
        let mapped = RectMath.map(inner, from: focus, to: canvas)
        #expect(mapped == CGRect(x: 500, y: 300, width: 100, height: 60))
        let back = RectMath.map(mapped, from: canvas, to: focus)
        #expect(abs(back.minX - inner.minX) < 1e-9 && abs(back.width - inner.width) < 1e-9)
    }

    @Test func lerpInterpolatesAndExtrapolates() {
        #expect(RectMath.lerp(focus, canvas, 0) == focus)
        #expect(RectMath.lerp(focus, canvas, 1) == canvas)
        #expect(RectMath.lerp(focus, canvas, 0.5) == CGRect(x: 100, y: 50, width: 550, height: 325))
        let over = RectMath.lerp(focus, canvas, 1.01)
        #expect(over.width > canvas.width)
    }

    @Test func scaleAboutCenterKeepsCenter() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 40)
        let s = RectMath.scaled(r, by: 0.85)
        #expect(abs(s.midX - r.midX) < 1e-9 && abs(s.midY - r.midY) < 1e-9)
        #expect(abs(s.width - 85) < 1e-9 && abs(s.height - 34) < 1e-9)
    }

    @Test func degenerateSourceDoesNotProduceNaN() {
        let r = RectMath.map(focus, from: .zero, to: canvas)
        #expect(!r.minX.isNaN && !r.width.isNaN)
    }
}

struct TileHitIndexTests {
    @Test func findsTileAndIgnoresGaps() {
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 102, y: 0, width: 98, height: 100),
                     CGRect(x: 0, y: 102, width: 200, height: 98)]
        let index = TileHitIndex(rects: rects, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), cellSize: 32)
        #expect(index.hit(CGPoint(x: 50, y: 50)) == 0)
        #expect(index.hit(CGPoint(x: 150, y: 10)) == 1)
        #expect(index.hit(CGPoint(x: 199, y: 199)) == 2)
        #expect(index.hit(CGPoint(x: 101, y: 50)) == nil)   // hueco
        #expect(index.hit(CGPoint(x: -5, y: 50)) == nil)    // fuera
        #expect(index.hit(CGPoint(x: 500, y: 500)) == nil)
    }

    @Test func agreesWithLinearScanOnRealLayout() {
        let kids = (1...400).map { FileNode(name: "f\($0)", isDirectory: false, allocatedSize: Int64(($0 * 7919) % 1000 + 1) * 1000) }
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 1, children: kids)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 560)
        let rects = Treemap.tiles(for: root, in: bounds).map(\.rect)
        let index = TileHitIndex(rects: rects, bounds: bounds)
        var state: UInt64 = 7
        for _ in 0..<2000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let x = Double(state >> 40 & 0xFFFF) / 65535 * 900
            let y = Double(state >> 20 & 0xFFFF) / 65535 * 560
            let p = CGPoint(x: x, y: y)
            #expect(index.hit(p) == rects.firstIndex { $0.contains(p) })
        }
    }

    @Test func emptyIndexHitsNothing() {
        let index = TileHitIndex(rects: [], bounds: .zero)
        #expect(index.hit(.zero) == nil)
    }
}

struct EntranceOrderTests {
    @Test func centerFirstThenOutwards() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100),      // esquina
                     CGRect(x: 100, y: 100, width: 100, height: 100),  // centro
                     CGRect(x: 100, y: 0, width: 100, height: 100),    // borde
                     CGRect(x: 200, y: 200, width: 100, height: 100)]  // esquina opuesta
        let ranks = EntranceOrder.ranks(for: rects, in: bounds)
        #expect(ranks[1] == 0)
        #expect(ranks[2] == 1)
        #expect(Set(ranks) == Set(0..<4))
        // Empate de distancia: decide el índice (determinista).
        #expect(ranks[0] == 2 && ranks[3] == 3)
    }
}

struct FileNodeRemovalTests {
    @Test func removingSubtractsFromEveryAncestor() {
        var kb = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        let videoIndex = ContentKind.allCases.firstIndex(of: .video)!
        kb[videoIndex] = 700
        let movie = FileNode(name: "peli.mov", isDirectory: false, allocatedSize: 700, kind: .video, kindBytes: kb)
        let doc = FileNode(name: "a.txt", isDirectory: false, allocatedSize: 300, kind: .documents)
        var folderKB = kb; folderKB[ContentKind.allCases.firstIndex(of: .documents)!] = 300
        let movies = FileNode(name: "Movies", isDirectory: true, allocatedSize: 1000, kindBytes: folderKB,
                              children: [movie, doc], descendantCount: 2)
        let root = FileNode(name: "/", isDirectory: true, allocatedSize: 1500, kindBytes: folderKB,
                            children: [movies], descendantCount: 3)
        movie.removeFromParent()
        #expect(movie.parent == nil)
        #expect(movies.children.map(\.name) == ["a.txt"])
        #expect(movies.allocatedSize == 300 && root.allocatedSize == 800)
        #expect(movies.kindBytes[videoIndex] == 0 && root.kindBytes[videoIndex] == 0)
        #expect(movies.descendantCount == 1 && root.descendantCount == 2)
        // Quitar algo que ya no tiene padre no hace nada.
        movie.removeFromParent()
        #expect(root.allocatedSize == 800)
    }

    @Test func removingAFolderSubtractsItsDescendants() {
        let f = FileNode(name: "f", isDirectory: false, allocatedSize: 10)
        let dir = FileNode(name: "d", isDirectory: true, allocatedSize: 10, children: [f], descendantCount: 1)
        let root = FileNode(name: "/", isDirectory: true, allocatedSize: 10, children: [dir], descendantCount: 2)
        dir.removeFromParent()
        #expect(root.descendantCount == 0 && root.allocatedSize == 0 && root.children.isEmpty)
    }
}

struct HomePathTests {
    @Test func abbreviatesHomeWithTilde() {
        #expect(Format.tildePath("/Users/ana/Library/Caches", home: "/Users/ana") == "~/Library/Caches")
        #expect(Format.tildePath("/Users/ana", home: "/Users/ana/") == "~")
        #expect(Format.tildePath("/Users/anabel/x", home: "/Users/ana") == "/Users/anabel/x")
        #expect(Format.tildePath("/Applications", home: "/Users/ana") == "/Applications")
    }
}
