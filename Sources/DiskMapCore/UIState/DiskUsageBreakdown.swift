import Foundation

/// Disk breakdown for the sidebar card, with figures that add up:
/// `analyzedShown + (other ?? 0) + purgeable + free == total`.
///
/// - `free`: truly free (`volumeAvailableCapacityKey`, what `df` reports).
/// - `purgeable`: what macOS can free only when needed (snapshots, purgeable caches):
///   `volumeAvailableCapacityForImportantUsageKey − volumeAvailableCapacityKey`. It is part of the used space.
/// - `used = total − free` (includes the purgeable space).
/// - `analyzed`: what the scan adds up to ("Analyzed"); when scanning `/` it includes macOS and the apps.
/// - `other` ("System and other"): used space that is neither purgeable nor in the scan. `nil` when the
///   analyzed space already reaches or exceeds that remainder (it cannot be known; the UI shows "—", never "0").
public struct DiskUsageBreakdown: Sendable, Equatable {
    public let total: Int64
    public let free: Int64
    public let purgeable: Int64
    public let used: Int64
    public let analyzed: Int64
    public let other: Int64?

    public init(totalBytes: Int64, availableBytes: Int64, importantAvailableBytes: Int64, analyzedBytes: Int64) {
        let total = max(totalBytes, 0)
        let free = min(max(availableBytes, 0), total)
        let used = total - free
        // The "important" figure includes the purgeable space; it can never exceed the total nor go below the free space.
        let important = min(max(importantAvailableBytes, free), total)
        let purgeable = min(important - free, used)
        let analyzed = max(analyzedBytes, 0)
        let rest = used - purgeable
        self.total = total
        self.free = free
        self.purgeable = purgeable
        self.used = used
        self.analyzed = analyzed
        self.other = analyzed < rest ? rest - analyzed : nil
    }

    /// The analyzed space as it goes into the ring (never more than the used, non-purgeable space).
    public var analyzedShown: Int64 { min(analyzed, used - purgeable) }

    /// Ring fractions, in order: analyzed, system and other, purgeable. They add up to `used / total`.
    public var ringFractions: (analyzed: Double, other: Double, purgeable: Double) {
        guard total > 0 else { return (0, 0, 0) }
        let t = Double(total)
        return (Double(analyzedShown) / t, Double(other ?? 0) / t, Double(purgeable) / t)
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}
