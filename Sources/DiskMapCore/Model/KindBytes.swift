/// Bytes per `ContentKind` of a node, stored inline (ten `Int64`) instead of in an `Array`: one heap object and
/// one allocation less per node of the tree, and no reference counting when sizes are added up.
/// Index = position in `ContentKind.allCases`. It behaves as a fixed-size collection of ten values.
public struct KindBytes: RandomAccessCollection, MutableCollection, Equatable, Hashable, Sendable,
    CustomStringConvertible, ExpressibleByArrayLiteral {
    public typealias Index = Int
    public typealias Element = Int64

    private var storage: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    public static let width = 10

    public init() {}

    /// The first ten values of `values`; missing ones are 0.
    public init<S: Sequence>(_ values: S) where S.Element == Int64 {
        var index = 0
        for value in values {
            guard index < Self.width else { break }
            self[index] = value
            index += 1
        }
    }

    public init(arrayLiteral elements: Int64...) { self.init(elements) }

    /// All zero except `bytes` for `kind`.
    public init(_ kind: ContentKind, _ bytes: Int64) {
        self[kind.index] = bytes
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { Self.width }

    public subscript(position: Int) -> Int64 {
        get {
            precondition(position >= 0 && position < Self.width, "KindBytes index out of range")
            return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: position * 8, as: Int64.self) }
        }
        set {
            precondition(position >= 0 && position < Self.width, "KindBytes index out of range")
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: newValue, toByteOffset: position * 8, as: Int64.self) }
        }
    }

    /// Adds `other` value by value.
    public mutating func add(_ other: KindBytes) {
        for index in 0..<Self.width { self[index] += other[index] }
    }

    public var total: Int64 { reduce(0, +) }

    public static func == (a: KindBytes, b: KindBytes) -> Bool { a.elementsEqual(b) }

    public func hash(into hasher: inout Hasher) {
        for value in self { hasher.combine(value) }
    }

    /// The same text as an `Array` of the values.
    public var description: String { Array(self).description }
}
