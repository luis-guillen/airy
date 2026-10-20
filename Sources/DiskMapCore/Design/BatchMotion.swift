import Foundation

/// Reglas puras de una tanda de borrado en Limpieza: cuándo hay ráfaga y qué dice el contador.
public enum BatchMotion {
    /// Ids en el orden de ejecución si la tanda merece ráfaga (dos filas o más); si no, `nil`.
    public static func gustOrder(ids: [String]) -> [String]? {
        ids.count >= 2 ? ids : nil
    }

    /// Lo que va despejando una tanda. Suma lo liberado y lo movido a la Papelera, pero no los
    /// confunde: lo de la Papelera no se libera hasta vaciarla.
    public struct Tally: Equatable, Sendable {
        public private(set) var freed: Int64 = 0
        public private(set) var movedToTrash: Int64 = 0

        public init() {}

        public var bytes: Int64 { freed + movedToTrash }

        /// «liberados» solo si nada fue a la Papelera; si no, «despejados».
        public var label: String { movedToTrash == 0 ? "liberados" : "despejados" }

        public var help: String? {
            movedToTrash == 0 ? nil : "Lo movido a la Papelera se libera al vaciarla"
        }

        public mutating func add(_ outcome: CleanupOutcome) {
            switch outcome {
            case .freed(let bytes): freed += max(bytes, 0)
            case .movedToTrash(let bytes): movedToTrash += max(bytes, 0)
            case .blocked, .failed: break
            }
        }
    }

    public static func tally(_ outcomes: [CleanupOutcome]) -> Tally {
        outcomes.reduce(into: Tally()) { $0.add($1) }
    }
}
