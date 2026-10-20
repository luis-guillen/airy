import Foundation
import CoreGraphics

/// Pose de una hoja en un instante (puntos, o unidades normalizadas según la función).
public struct LeafPose: Equatable, Sendable {
    public var x, y, rotation, scale, opacity: Double
    public init(x: Double, y: Double, rotation: Double, scale: Double, opacity: Double) {
        self.x = x; self.y = y; self.rotation = rotation; self.scale = scale; self.opacity = opacity
    }
}

public enum MotionMode: Equatable, Sendable { case running, paused, reduced }

/// Portero de movimiento: decide si una animación corre, se salta o se reduce a un fundido.
public enum AnimationGate {
    /// Ambiente (brisa, remolino): oculta o inactiva ⇒ pausada.
    public static func ambient(windowVisible: Bool, appActive: Bool, reduceMotion: Bool) -> MotionMode {
        if !windowVisible || !appActive { return .paused }
        return reduceMotion ? .reduced : .running
    }

    /// Transitoria (borrar, ráfaga, arranque): corre aunque la app esté inactiva.
    public static func transient(windowVisible: Bool, reduceMotion: Bool) -> MotionMode {
        if !windowVisible { return .paused }
        return reduceMotion ? .reduced : .running
    }
}

public enum BreezeIntensity: Sendable { case ambient, scan }

public struct BreezeStreak: Equatable, Sendable {
    public var yFraction, lengthFraction, thickness, opacity, period, phase: Double
}

/// Integra el ángulo del remolino para que un cambio de velocidad no produzca saltos.
public struct SwirlPhase: Sendable {
    public var angle: Double
    private var lastTime: Double?

    public init(angle: Double = 0) { self.angle = angle }

    @discardableResult
    public mutating func advance(to time: Double, revolutionsPerSecond: Double) -> Double {
        defer { lastTime = time }
        guard let last = lastTime else { return angle }
        let dt = min(max(time - last, 0), 1.0 / 15.0)
        let step = 2 * Double.pi * revolutionsPerSecond * dt
        if step.isFinite {
            angle = (angle + step).truncatingRemainder(dividingBy: 2 * .pi)
        }
        return angle
    }
}

public enum WindMotion {
    // MARK: Ruido determinista

    /// Mezcla tipo splitmix64; resultado en [0, 1).
    public static func noise(_ index: Int, _ salt: Int) -> Double {
        var z = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        z = z &+ UInt64(bitPattern: Int64(salt)) &* 0xD1B5_4A32_D192_ED03 &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    // MARK: Arranque

    public static let launchLeafCount = 18

    public static func launchTimeline(_ mode: MotionMode) -> (gather: Double, hold: Double, fade: Double) {
        switch mode {
        case .running: return (1.4, 0.25, 0.35)
        case .reduced: return (0.25, 0.2, 0.25)
        case .paused: return (0, 0, 0)
        }
    }

    /// Opacidad común de las hojas del arranque: 1 hasta `gather + hold`, baja linealmente a 0
    /// durante `fade` (no desaparecen de golpe al terminar).
    public static func launchLeafFade(elapsed: Double) -> Double {
        let t = launchTimeline(.running)
        guard !elapsed.isNaN, t.fade > 0 else { return 1 }
        return clamp(1 - (elapsed - t.gather - t.hold) / t.fade, 0, 1)
    }

    /// Coordenadas normalizadas (centro 0). Sale de un radio 2,4…3,2, gira en espiral y llega al objetivo.
    public static func launchLeaf(index: Int, count: Int, progress: Double) -> LeafPose {
        let targets = AiryLogoGeometry.launchTargets(count: count)
        guard targets.indices.contains(index) else {
            return LeafPose(x: 0, y: 0, rotation: 0, scale: 1, opacity: 0)
        }
        let target = targets[index]
        let p = progress.isNaN ? 0 : clamp(progress, 0, 1)
        let e = easeOut(p)
        let startRadius = 2.4 + 0.8 * noise(index, 1)
        let startAngle = 2 * Double.pi * noise(index, 2)
        // Desfase inicial (S - objetivo) girado hacia atrás lo que girará, para que en p = 0 sea exactamente S.
        let totalTurn = 1.1 * 2 * Double.pi
        let dx = startRadius * cos(startAngle) - target.x
        let dy = startRadius * sin(startAngle) - target.y
        let sx = dx * cos(totalTurn) + dy * sin(totalTurn)
        let sy = -dx * sin(totalTurn) + dy * cos(totalTurn)
        let remaining = 1 - e
        let theta = remaining * totalTurn
        let c = cos(theta), s = sin(theta)
        return LeafPose(
            x: target.x + remaining * (sx * c - sy * s),
            y: target.y + remaining * (sx * s + sy * c),
            // Cada hoja da su propio número de vueltas (±1,5) además del giro de la espiral.
            rotation: theta + remaining * 3 * Double.pi * (2 * noise(index, 11) - 1),
            scale: 1 - 0.4 * remaining,
            opacity: min(1, p / 0.25))
    }

    // MARK: Órbita

    public static let orbitAngularSpeed = 0.9

    public static func orbitLeaf(index: Int, count: Int, time: Double, radius: Double) -> LeafPose {
        let n = Double(max(count, 1))
        let angle = 2 * Double.pi * Double(index) / n + orbitAngularSpeed * time
        let r = radius * (1 + 0.06 * sin(0.7 * time + 2 * Double.pi * noise(index, 3)))
        return LeafPose(x: r * cos(angle), y: r * sin(angle), rotation: angle + .pi / 2, scale: 1, opacity: 1)
    }

    // MARK: Deshacerse en hojas

    public static let dissolveDuration = 0.75

    public static func leafCount(for rect: CGRect) -> Int {
        let area = Double(rect.width) * Double(rect.height)
        guard area.isFinite else { return 0 }
        return Int(clamp((area / 1800).rounded(.down), 6, 24))
    }

    public static func dissolveLeaf(index: Int, count: Int, progress: Double, in rect: CGRect) -> LeafPose {
        let p = progress.isNaN ? 0 : clamp(progress, 0, 1)
        let finite = rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
        let w = finite ? max(Double(rect.width), 0) : 0, h = finite ? max(Double(rect.height), 0) : 0
        let ox = finite ? Double(rect.minX) : 0, oy = finite ? Double(rect.minY) : 0
        let rows = Double(max(count, 1))
        let x0 = ox + w * noise(index, 4) * 0.999
        let y0 = oy + h * min((Double(index) + noise(index, 5)) / rows, 0.999)
        let dx = 80 + 160 * noise(index, 6)
        let flutter = sin(2 * Double.pi * (p * (1 + noise(index, 7)) + noise(index, 8)))
        let opacity = p <= 0.15 ? p / 0.15 : (1 - p) / 0.85
        return LeafPose(
            x: x0 + dx * easeOut(p),
            y: y0 - 30 * p + 6 * flutter * p,
            rotation: p * (2 + 3 * noise(index, 9)) * (noise(index, 10) < 0.5 ? -1 : 1),
            scale: 1 - 0.4 * p,
            opacity: opacity)
    }

    // MARK: Salir volando

    public static func leafAwayTransform(progress: Double)
        -> (dx: Double, dy: Double, rotationDegrees: Double, scale: Double, opacity: Double) {
        let p = progress.isNaN ? 0 : clamp(progress, 0, 1)
        return (220 * p * p, -24 * p, 6 * p, 1 - 0.12 * p, 1 - p)
    }

    // MARK: Ráfaga

    public static let gustRowDelay = 0.04
    public static let gustRowDuration = 0.55
    public static let gustMaxDuration = 1.2
    public static let gustBandDuration = 0.9

    private static let gustMaxDelay = 0.65

    public static func gustDuration(rowCount: Int) -> Double {
        guard rowCount > 0 else { return 0 }
        return min(min(Double(rowCount - 1) * gustRowDelay, gustMaxDelay) + gustRowDuration, gustMaxDuration)
    }

    public static func gustRowOffset(row: Int, rowCount: Int, elapsed: Double) -> Double {
        let delay = min(Double(max(row, 0)) * gustRowDelay, gustMaxDelay)
        let q = (elapsed - delay) / gustRowDuration
        guard q > 0, q < 1 else { return 0 }
        return 14 * sin(Double.pi * q)
    }

    // MARK: Brisa

    public static func breezeStreaks(_ intensity: BreezeIntensity) -> [BreezeStreak] {
        let count = intensity == .ambient ? 3 : 6
        return (0..<count).map { i in
            let salt = intensity == .ambient ? 20 : 40
            let n = { (k: Int) in noise(i, salt + k) }
            switch intensity {
            case .ambient:
                return BreezeStreak(yFraction: (Double(i) + 0.2 + 0.6 * n(0)) / 3, lengthFraction: 0.25 + 0.2 * n(1),
                                    thickness: 1 + n(2), opacity: 0.03 + 0.03 * n(3),
                                    period: 18 + 8 * n(4), phase: n(5))
            case .scan:
                return BreezeStreak(yFraction: (Double(i) + 0.2 + 0.6 * n(0)) / 6, lengthFraction: 0.2 + 0.25 * n(1),
                                    thickness: 1 + 1.5 * n(2), opacity: 0.08 + 0.06 * n(3),
                                    period: 4 + 2 * n(4), phase: n(5))
            }
        }
    }

    // MARK: Remolino

    public static func swirlRevolutionsPerSecond(cpuLoad: Double) -> Double {
        let load = cpuLoad.isNaN ? 0 : clamp(cpuLoad, 0, 1)
        return 0.06 + 0.84 * load
    }

    public static func heat(for state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: return 0
        case .fair: return 0.35
        case .serious: return 0.7
        case .critical: return 1
        @unknown default: return 0
        }
    }

    // MARK: Balanceo

    public static let swayKeyframes: [(degrees: Double, time: Double)] =
        [(1.6, 0.12), (-1.1, 0.26), (0.5, 0.42), (0, 0.6)]
}
