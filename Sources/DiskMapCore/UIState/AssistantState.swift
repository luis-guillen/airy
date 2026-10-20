import Foundation

// MARK: - Rutas mencionadas en una respuesta

/// Rutas del contexto que Claude menciona en una respuesta, para ofrecer "Ver en el mapa".
public enum AssistantRoutes {
    /// Rutas absolutas del contexto enviado a la IA (nodos y rutas de los elementos de limpieza),
    /// sin repetir y en el orden del contexto. Un contexto ilegible no da ninguna.
    public static func contextPaths(_ context: String, home: String) -> [String] {
        guard let payload = try? JSONDecoder().decode(AIContextPayload.self, from: Data(context.utf8)) else {
            return []
        }
        var seen = Set<String>()
        var paths: [String] = []
        for raw in payload.nodes.map(\.path) + payload.cleanupItems.flatMap(\.paths) {
            let absolute = AIPaths.expand(raw, home: home)
            guard absolute.hasPrefix("/"), seen.insert(absolute).inserted else { continue }
            paths.append(absolute)
        }
        return paths
    }

    /// Rutas de `candidates` (absolutas) que aparecen en `text` con su forma absoluta o con `~`,
    /// en el orden en que aparecen por primera vez. Si una mención contiene a otra
    /// ("~/Library/Containers" frente a "~/Library"), gana la más larga. Se ignoran "/" y la
    /// carpeta personal ("~"), demasiado generales para llevar al mapa.
    public static func mentioned(in text: String, candidates: [String], home: String, limit: Int = 6) -> [String] {
        let base = AIPaths.base(home)
        var matches: [(range: Range<String.Index>, path: String)] = []
        for path in Set(candidates) where path != "/" && path != base && path.hasPrefix("/") {
            for form in Set([path, AIPaths.display(path, home: home)]) {
                var start = text.startIndex
                while start < text.endIndex, let range = text.range(of: form, range: start..<text.endIndex) {
                    if isBoundedMention(range, in: text) { matches.append((range, path)) }
                    start = text.index(after: range.lowerBound)
                }
            }
        }
        // La mención más larga se queda con su trozo de texto.
        let kept = matches.filter { match in
            !matches.contains { other in
                other.path != match.path && other.range.lowerBound <= match.range.lowerBound
                    && other.range.upperBound >= match.range.upperBound
                    && (other.range.lowerBound < match.range.lowerBound || other.range.upperBound > match.range.upperBound)
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var seen = Set<String>()
        var result: [String] = []
        for match in kept where seen.insert(match.path).inserted {
            result.append(match.path)
            if result.count == max(0, limit) { break }
        }
        return result
    }

    private static func isPathCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == "/" || c == "~"
    }

    /// Ni empieza en medio de otra ruta ni sigue con más nombre (".cache/uvx", "uv.zip", "uv/archive").
    /// Un "." o "/" final vale si detrás no sigue la ruta (fin de frase, comillas…).
    private static func isBoundedMention(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex, isPathCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        guard range.upperBound < text.endIndex else { return true }
        let next = text[range.upperBound]
        if next.isLetter || next.isNumber || next == "_" || next == "-" { return false }
        if next == "." || next == "/" {
            let after = text.index(after: range.upperBound)
            return after == text.endIndex || !isPathCharacter(text[after])
        }
        return true
    }
}

// MARK: - Columnas del informe

/// Las tres columnas de riesgo del informe, siempre en el mismo orden y aunque estén vacías.
public enum ReportColumns {
    public struct Column: Sendable, Identifiable {
        public var risk: Risk
        /// De mayor a menor tamaño.
        public var recommendations: [AIRecommendation]
        /// Suma sin contar dos veces una ruta que está dentro de otra de la misma columna.
        public var totalBytes: Int64
        public var id: Int { risk.rawValue }
    }

    public static func columns(_ report: AIReport) -> [Column] {
        [Risk.safe, .yourCall, .doNotTouch].map { risk in
            let recommendations = report.recommendations.filter { $0.verdict == risk }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            let total = recommendations.filter { rec in
                !recommendations.contains { other in
                    other.path != rec.path
                        && RiskPolicy.isInside(RiskPolicy.canonical(rec.path), root: RiskPolicy.canonical(other.path))
                }
            }.reduce(Int64(0)) { $0 + $1.bytes }
            return Column(risk: risk, recommendations: recommendations, totalBytes: total)
        }
    }
}

// MARK: - Botón de cada recomendación

/// Qué hace el botón de una recomendación. Siempre pasa por `AppModel` y `CleanupExecutor`,
/// que repiten todas sus comprobaciones justo antes de actuar.
public enum AssistantCleanupAction: Sendable {
    /// Limpieza del catálogo (`AppModel.perform`): revalida ficha, rutas, apps abiertas y referencias.
    case perform(CleanupItem)
    /// Rutas sueltas a la Papelera (`AppModel.trash(paths:title:)`).
    case trashPaths([String])
}

public struct AssistantActionOffer: Sendable {
    public var action: AssistantCleanupAction
    /// "Depende de ti": hace falta una segunda confirmación explícita.
    public var needsSecondConfirmation: Bool
    /// Método para la confirmación: "A la Papelera" o "Comando oficial: …".
    public var method: String
    public var isCommand: Bool
    /// Tamaño de lo que de verdad se toca (el elemento de limpieza, o la ruta suelta).
    public var bytes: Int64
}

/// Botón (o ausencia de botón) de una recomendación del informe, ya validada por `AIAssistant`:
/// - "No tocar": nunca hay botón.
/// - "Borrar sin riesgo" con acción: un toque (y la confirmación de siempre), por el elemento de limpieza.
/// - "Depende de ti": solo "Mover a la Papelera…" (`AppModel.trash(paths:title:)`), con segunda
///   confirmación, y nunca donde la limpieza correcta es un comando oficial o la ficha es solo informativa.
public enum AssistantOffer: Sendable, Equatable {
    case none
    case offer(AssistantActionOffer)
    /// Habría botón, pero ahora no se puede (no detectado, lo usa un proyecto…).
    case unavailable(String)

    static let notDetected = "No aparece ahora en Limpieza. Vuelve a analizar el disco."

    public static func make(for rec: AIRecommendation, items: [CleanupItem], catalog: Catalog?,
                            home: String) -> AssistantOffer {
        switch rec.verdict {
        case .doNotTouch:
            return .none
        case .safe:
            switch rec.action {
            case .runCatalogCommand(let id):
                // Solo el elemento que la tarjeta muestra: el de esa ruta (o el id de un elemento sin rutas).
                let target = items.first { item in
                    item.entry.id == id && (item.id == rec.path || item.paths.contains { overlaps($0, rec.path) })
                }
                guard let target else { return .unavailable(notDetected) }
                if !target.usedBy.isEmpty { return .unavailable(usedByReason(target.usedBy)) }
                return .offer(AssistantActionOffer(action: .perform(target), needsSecondConfirmation: false,
                                                   method: method(for: target.entry.cleanup),
                                                   isCommand: !isTrash(target.entry.cleanup), bytes: target.bytes))
            case .trash(let path):
                // El elemento detectado de esa misma ruta (revalida apps abiertas y ficha) o, si no, la
                // ruta suelta: `trashPaths` aplica igualmente apps abiertas, referencias y ubicaciones protegidas.
                if let detected = detectedTrashItem(exactly: path, items: items) {
                    if !detected.usedBy.isEmpty { return .unavailable(usedByReason(detected.usedBy)) }
                    return .offer(AssistantActionOffer(action: .perform(detected), needsSecondConfirmation: false,
                                                       method: method(for: .trash), isCommand: false,
                                                       bytes: detected.bytes))
                }
                return .offer(AssistantActionOffer(action: .trashPaths([path]), needsSecondConfirmation: false,
                                                   method: method(for: .trash), isCommand: false, bytes: rec.bytes))
            case nil:
                return .none
            }
        case .yourCall:
            let path = rec.path
            guard path.hasPrefix("/") else { return .none }
            // Donde manda un comando oficial (o solo hay información), nada se borra a mano.
            let handsOff = items.contains { item in
                !isTrash(item.entry.cleanup) && item.paths.contains { overlaps($0, path) }
            }
            if handsOff { return .none }
            if let entry = catalog?.match(path: path, home: home), !isTrash(entry.cleanup) { return .none }
            if let detected = detectedTrashItem(exactly: path, items: items), !detected.usedBy.isEmpty {
                return .unavailable(usedByReason(detected.usedBy))
            }
            return .offer(AssistantActionOffer(action: .trashPaths([path]), needsSecondConfirmation: true,
                                               method: method(for: .trash), isCommand: false, bytes: rec.bytes))
        }
    }

    /// Elemento detectado (con Papelera) cuya única ruta es exactamente `path`.
    private static func detectedTrashItem(exactly path: String, items: [CleanupItem]) -> CleanupItem? {
        let key = RiskPolicy.canonical(path)
        return items.first { item in
            isTrash(item.entry.cleanup) && item.paths.count == 1 && RiskPolicy.canonical(item.paths[0]) == key
        }
    }

    static func method(for cleanup: CleanupMethod) -> String {
        switch cleanup {
        case .trash, .info: return "A la Papelera"
        case .command(let executable, let arguments, _):
            let name = (executable as NSString).lastPathComponent
            return "Comando oficial: " + ([name] + arguments).joined(separator: " ")
        }
    }

    private static func usedByReason(_ usedBy: [String]) -> String {
        "Lo usa: \(usedBy.prefix(3).joined(separator: ", "))\(usedBy.count > 3 ? "…" : "")."
    }

    private static func isTrash(_ cleanup: CleanupMethod) -> Bool {
        if case .trash = cleanup { return true }
        return false
    }

    /// Una ruta dentro de la otra (o la misma).
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = RiskPolicy.canonical(a), b = RiskPolicy.canonical(b)
        return RiskPolicy.isInside(a, root: b) || RiskPolicy.isInside(b, root: a)
    }

    public static func == (a: AssistantOffer, b: AssistantOffer) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.unavailable(let x), .unavailable(let y)): return x == y
        case (.offer(let x), .offer(let y)):
            guard x.method == y.method, x.needsSecondConfirmation == y.needsSecondConfirmation,
                  x.bytes == y.bytes else { return false }
            switch (x.action, y.action) {
            case (.perform(let i), .perform(let j)): return i.id == j.id && i.paths == j.paths
            case (.trashPaths(let p), .trashPaths(let q)): return p == q
            default: return false
            }
        default: return false
        }
    }
}

// MARK: - Conversación

public struct ChatBubble: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable { case streaming, done, stopped, failed(String) }

    public let id: Int
    public var role: ChatMessage.Role
    public var text: String
    public var status: Status
    /// Rutas del contexto mencionadas en la respuesta (para "Ver en el mapa").
    public var routes: [String]
}

/// Conversación del chat: burbujas, la respuesta que llega en streaming y el historial que se
/// envía a Claude en cada turno (sin las preguntas que se quedaron sin respuesta).
public struct ChatTranscript: Sendable {
    public private(set) var bubbles: [ChatBubble] = []
    private var nextID = 0

    public init() {}

    public var isStreaming: Bool { bubbles.last?.status == .streaming }

    /// Añade la pregunta y una respuesta vacía en curso; devuelve el historial que hay que enviar.
    /// `nil` si la pregunta está vacía o ya hay una respuesta en curso.
    public mutating func begin(_ question: String) -> [ChatMessage]? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return nil }
        let history = answeredHistory(upTo: bubbles.count) + [ChatMessage(role: .user, text: text)]
        append(.user, text, .done)
        append(.assistant, "", .streaming)
        return history
    }

    public mutating func append(_ delta: String) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].text += delta
    }

    public mutating func finish(routes: [String]) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].status = .done
        bubbles[bubbles.count - 1].routes = routes
    }

    /// Detiene la respuesta: se queda lo que había llegado; si no había nada, desaparece la burbuja.
    public mutating func stop() {
        guard isStreaming else { return }
        if bubbles[bubbles.count - 1].text.isEmpty {
            bubbles.removeLast()
        } else {
            bubbles[bubbles.count - 1].status = .stopped
        }
    }

    public mutating func fail(_ message: String) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].status = .failed(message)
    }

    /// Repite la última pregunta si su respuesta falló. Devuelve el historial que hay que enviar.
    public mutating func retry() -> [ChatMessage]? {
        guard bubbles.count >= 2, case .failed = bubbles[bubbles.count - 1].status,
              bubbles[bubbles.count - 2].role == .user else { return nil }
        let question = bubbles[bubbles.count - 2].text
        let history = answeredHistory(upTo: bubbles.count - 2) + [ChatMessage(role: .user, text: question)]
        bubbles[bubbles.count - 1].text = ""
        bubbles[bubbles.count - 1].routes = []
        bubbles[bubbles.count - 1].status = .streaming
        return history
    }

    /// Pares pregunta-respuesta con respuesta (terminada o detenida) entre las primeras `end` burbujas.
    private func answeredHistory(upTo end: Int) -> [ChatMessage] {
        var history: [ChatMessage] = []
        var index = 0
        while index < end {
            let bubble = bubbles[index]
            if bubble.role == .user, index + 1 < end {
                let answer = bubbles[index + 1]
                if answer.role == .assistant, !answer.text.isEmpty,
                   answer.status == .done || answer.status == .stopped {
                    history.append(ChatMessage(role: .user, text: bubble.text))
                    history.append(ChatMessage(role: .assistant, text: answer.text))
                    index += 2
                    continue
                }
            }
            index += 1
        }
        return history
    }

    private mutating func append(_ role: ChatMessage.Role, _ text: String, _ status: ChatBubble.Status) {
        nextID += 1
        bubbles.append(ChatBubble(id: nextID, role: role, text: text, status: status, routes: []))
    }
}

// MARK: - Texto del chat

public enum ChatText {
    /// Markdown solo en línea (negritas, cursivas, `código`), conservando los saltos de línea y **sin
    /// enlaces**: una respuesta nunca puede abrir nada fuera de la app (`file://…/x.command`, esquemas…).
    public static func rendered(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        result = stripLinks(result)
        return result
    }

    public static func stripLinks(_ text: AttributedString) -> AttributedString {
        var copy = text
        for run in copy.runs where run.link != nil {
            copy[run.range].link = nil
        }
        return copy
    }
}
