import Foundation

/// How complete the last scan is: the disk card, the Map and the MCP say so.
public enum ScanCompleteness: Sendable, Equatable {
    case complete
    case partial(unreadable: Int)
    case unavailable

    public static func of(_ result: ScanResult?) -> ScanCompleteness {
        guard let result else { return .unavailable }
        return result.inaccessible.isEmpty ? .complete : .partial(unreadable: result.inaccessible.count)
    }

    public var label: String {
        switch self {
        case .complete: String(localized: "Complete scan", bundle: .airyCore)
        case .partial(let count):
            count == 1 ? String(localized: "Partial scan: 1 folder could not be read", bundle: .airyCore)
                : String(localized: "Partial scan: \(count) folders could not be read", bundle: .airyCore)
        case .unavailable: String(localized: "No scan", bundle: .airyCore)
        }
    }

    public var jsonName: String {
        switch self {
        case .complete: "complete"
        case .partial: "partial"
        case .unavailable: "unavailable"
        }
    }
}

/// Which paths have something unreadable inside (themselves or something hanging from them): their scanned size is a
/// minimum and is shown with "+". Sorts once; each query is a binary search.
public struct PartialScanIndex: Sendable {
    private let sorted: [String]

    public init(inaccessible: [String]) {
        sorted = inaccessible.map(Self.trimmed).sorted()
    }

    public var isEmpty: Bool { sorted.isEmpty }

    public func isPartial(_ path: String) -> Bool {
        guard !sorted.isEmpty else { return false }
        let path = Self.trimmed(path)
        let start = lowerBound(path)
        if start < sorted.count, sorted[start] == path { return true }
        // What hangs from `path` starts with "path/" and is contiguous from its first candidate.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let inside = lowerBound(prefix)
        return inside < sorted.count && sorted[inside].hasPrefix(prefix)
    }

    /// First index with `sorted[i] >= key`.
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
