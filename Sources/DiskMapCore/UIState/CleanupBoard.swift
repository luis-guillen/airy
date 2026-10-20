import Foundation

/// Lógica pura de la vista Limpieza: grupos por riesgo, qué se puede marcar, qué entra en
/// "Limpiar todo lo seguro" y los textos de bloqueo y método. Sin SwiftUI, para poder probarla.
public struct CleanupBoard: Sendable {
    public struct Group: Sendable, Identifiable {
        public let risk: Risk
        /// Ordenados de mayor a menor tamaño (empates por id, para un orden estable).
        public let items: [CleanupItem]
        public var id: Risk { risk }
        public var title: String { risk.title }
        public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    /// "Borrar sin riesgo", "Depende de ti" y "No tocar", en ese orden y sin grupos vacíos.
    public let groups: [Group]

    /// `hidden`: elementos ya limpiados que se ocultan al momento, antes de que llegue la nueva detección.
    public init(items: [CleanupItem], hidden: Set<String> = []) {
        let visible = items.filter { !hidden.contains($0.id) }
        groups = [Risk.safe, .yourCall, .doNotTouch].compactMap { risk in
            let members = visible.filter { $0.risk == risk }
                .sorted { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
            return members.isEmpty ? nil : Group(risk: risk, items: members)
        }
    }

    /// Todos los elementos visibles en el orden de la pantalla.
    public var items: [CleanupItem] { groups.flatMap(\.items) }

    // MARK: Cabecera

    /// "Puedes liberar X": solo lo `.safe` que tiene acción (incluido lo que espera a que cierres una
    /// app; no lo que usa un proyecto).
    public var safeBytes: Int64 {
        items.filter { $0.risk == .safe && Self.showsCheckbox($0) && $0.usedBy.isEmpty }.reduce(0) { $0 + $1.bytes }
    }

    /// Lo que "Limpiar todo lo seguro" ejecuta: `.safe`, con acción y sin bloqueo.
    public var readySafeItems: [CleanupItem] {
        items.filter { $0.risk == .safe && Self.canSelect($0) }
    }

    public var readySafeBytes: Int64 { readySafeItems.reduce(0) { $0 + $1.bytes } }

    /// `true` si `safeBytes` incluye limpiezas parciales: la cabecera dice "Puedes liberar hasta".
    public var safeBytesIsUpperBound: Bool {
        items.contains { $0.risk == .safe && Self.showsCheckbox($0) && $0.usedBy.isEmpty && Self.isPartial($0) }
    }

    // MARK: Limpiezas parciales

    /// El comando oficial solo quita una parte (`partialCleanup` en el catálogo): su tamaño es un máximo.
    public static func isPartial(_ item: CleanupItem) -> Bool { item.entry.partialCleanup }

    /// "hasta 3,6 GB" para limpiezas parciales; si no, el tamaño tal cual.
    public static func sizeText(_ item: CleanupItem) -> String {
        amountText(item.bytes, upperBound: isPartial(item))
    }

    public static func amountText(_ bytes: Int64, upperBound: Bool) -> String {
        upperBound ? "hasta \(Format.bytes(bytes))" : Format.bytes(bytes)
    }

    /// Suma de los elementos y si es solo un máximo (alguno es parcial).
    public static func total(_ items: [CleanupItem]) -> (bytes: Int64, upperBound: Bool) {
        (items.reduce(0) { $0 + $1.bytes }, items.contains(where: isPartial))
    }

    // MARK: Selección

    /// Tiene casilla si DiskMap puede actuar sobre él: ni "No tocar" ni solo informativo.
    public static func showsCheckbox(_ item: CleanupItem) -> Bool {
        guard item.risk != .doNotTouch, item.entry.risk != .doNotTouch else { return false }
        if case .info = item.entry.cleanup { return false }
        return true
    }

    /// Se puede marcar ahora: con casilla, sin apps abiertas que lo bloqueen y sin proyectos que lo usen.
    public static func canSelect(_ item: CleanupItem) -> Bool {
        showsCheckbox(item) && item.blockedByOpenApps.isEmpty && item.usedBy.isEmpty
    }

    /// Los marcados que siguen siendo válidos, en el orden de la pantalla.
    public func selected(_ ids: Set<String>) -> [CleanupItem] {
        items.filter { ids.contains($0.id) && Self.canSelect($0) }
    }

    public func selectedBytes(_ ids: Set<String>) -> Int64 {
        selected(ids).reduce(0) { $0 + $1.bytes }
    }

    /// La selección sin lo que ya no existe o ya no se puede marcar (tras una nueva detección).
    public func pruned(_ ids: Set<String>) -> Set<String> {
        Set(selected(ids).map(\.id))
    }

    // MARK: Textos

    private static let knownApps: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.brave.Browser": "Brave",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
    ]

    /// Nombre legible de una app a partir de su bundle ID (la vista prefiere el de la app abierta).
    public static func appName(forBundleID bundleID: String) -> String {
        if let known = knownApps[bundleID] { return known }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// "Cierra Spotify para limpiar esto" (o "Cierra A, B y C …").
    public static func blockedMessage(appNames: [String]) -> String? {
        guard !appNames.isEmpty else { return nil }
        return "Cierra \(spanishList(appNames)) para limpiar esto"
    }

    /// "Lo usa: ~/Projects/app/main.py" (como mucho tres rutas y "y N más").
    public static func usedByMessage(_ usedBy: [String], home: String = NSHomeDirectory()) -> String? {
        guard !usedBy.isEmpty else { return nil }
        let shown = usedBy.prefix(3).map { Format.tildePath($0, home: home) }
        let rest = usedBy.count - shown.count
        return "Lo usa: " + shown.joined(separator: ", ") + (rest > 0 ? " y \(rest) más" : "")
    }

    /// "A la Papelera", "Comando oficial: docker builder prune -a -f" o "Solo informativo".
    public static func methodDescription(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: "A la Papelera"
        case .info: "Solo informativo"
        case .command: "Comando oficial: " + (commandLine(method) ?? "")
        }
    }

    /// La orden tal como se ejecuta (ejecutable y argumentos), escrita para leerla; `nil` si no es un comando.
    /// Solo es texto: la app la ejecuta con `Process` y un array de argumentos, nunca con un shell.
    public static func commandLine(_ method: CleanupMethod) -> String? {
        guard case .command(let executable, let arguments, _) = method else { return nil }
        return ([executable] + arguments).map(displayQuoted).joined(separator: " ")
    }

    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")

    private static func displayQuoted(_ word: String) -> String {
        guard word.isEmpty || !word.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Dónde está lo que se va a tocar: la ruta, "primera · y N más", o "Todo lo que hay en
    /// ~/Library/Logs (N elementos)" cuando son todos los hijos de un patrón `carpeta/*` del catálogo.
    public static func locationSummary(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String? {
        let paths = item.paths
        guard let first = paths.first else { return nil }
        if paths.count == 1 { return Format.tildePath(first, home: home) }
        let parent = (first as NSString).deletingLastPathComponent
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let wildcardParents = item.entry.paths.compactMap { pattern -> String? in
            guard pattern.hasSuffix("/*") else { return nil }
            let folder = String(pattern.dropLast(2))
            if folder == "~" { return base }
            return folder.hasPrefix("~/") ? base + folder.dropFirst(1) : folder
        }
        if wildcardParents.contains(parent),
           paths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == parent }) {
            return "Todo lo que hay en \(Format.tildePath(parent, home: home)) (\(paths.count) elementos)"
        }
        return "\(Format.tildePath(first, home: home)) · y \(paths.count - 1) más"
    }

    /// El elemento solo con las rutas que siguen existiendo (las que desaparecieron desde la
    /// detección no bloquean el resto); `nil` si no queda ninguna. Sin rutas (comandos), tal cual.
    /// El ejecutor vuelve a validar cada ruta que queda.
    public static func withExistingPaths(_ item: CleanupItem, exists: (String) -> Bool) -> CleanupItem? {
        guard !item.paths.isEmpty else { return item }
        var copy = item
        copy.paths = item.paths.filter(exists)
        return copy.paths.isEmpty ? nil : copy
    }

    public static func yourCallNote(count: Int) -> String {
        count == 1
            ? "Incluye 1 elemento marcado «Depende de ti»: perderás algo al borrarlo."
            : "Incluye \(count) elementos marcados «Depende de ti»: perderás algo al borrarlo."
    }

    static func spanishList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " y " + names.last!
    }
}

// MARK: - Ejecución en lote

/// Resultado de una tanda de limpiezas, contado con honestidad: lo que fue a la Papelera no está liberado.
public struct CleanupRunSummary: Sendable, Equatable {
    public struct Problem: Sendable, Equatable, Identifiable {
        public let title: String
        public let message: String
        public var id: String { title + "\u{1F}" + message }
        public init(title: String, message: String) { self.title = title; self.message = message }
    }

    public var freed: Int64 = 0
    public var movedToTrash: Int64 = 0
    public var succeededIDs: [String] = []
    public var problems: [Problem] = []

    public init() {}

    public mutating func record(id: String, title: String, outcome: CleanupOutcome) {
        switch outcome {
        case .freed(let bytes):
            freed += bytes
            succeededIDs.append(id)
        case .movedToTrash(let bytes):
            movedToTrash += bytes
            succeededIDs.append(id)
        case .blocked(let reason):
            problems.append(Problem(title: title, message: reason))
        case .failed(let message):
            problems.append(Problem(title: title, message: message))
        }
    }

    /// Frase de resultado, o `nil` si nada salió bien.
    public var headline: String? {
        guard !succeededIDs.isEmpty else { return nil }
        switch (freed > 0, movedToTrash > 0) {
        case (true, true): return "Liberados \(Format.bytes(freed)) · \(Format.bytes(movedToTrash)) en la Papelera"
        case (true, false): return "Liberados \(Format.bytes(freed))"
        case (false, true): return "\(Format.bytes(movedToTrash)) en la Papelera. Se libera al vaciarla."
        case (false, false): return "Hecho. El espacio libre no ha cambiado de forma apreciable."
        }
    }
}

public enum CleanupBatch {
    /// Ejecuta los elementos de uno en uno, en orden (cada uno revalida justo antes de actuar).
    /// `onStart` recibe el índice del que empieza. En el hilo principal: lo maneja la interfaz.
    @MainActor
    public static func run(
        _ items: [CleanupItem],
        onStart: @MainActor (Int) -> Void = { _ in },
        perform: @MainActor (CleanupItem) async -> CleanupOutcome
    ) async -> CleanupRunSummary {
        var summary = CleanupRunSummary()
        for (index, item) in items.enumerated() {
            onStart(index)
            summary.record(id: item.id, title: item.title, outcome: await perform(item))
        }
        return summary
    }
}

// MARK: - Tras vaciar la Papelera

public enum TrashFollowUp {
    /// Si el espacio libre sube menos de esta fracción de lo esperado, algo lo retiene.
    public static let expectedRiseFraction = 0.8
    public static let snapshotEntryID = "time-machine-snapshots"

    /// `true` si conviene explicar las instantáneas locales: se sabía cuánto había en la Papelera,
    /// el espacio libre no subió al menos el 80 % de eso y `tmutil` lista instantáneas.
    public static func shouldExplainSnapshots(expectedBytes: Int64?, freeBefore: Int64, freeAfter: Int64,
                                              snapshotCount: Int) -> Bool {
        guard let expectedBytes, expectedBytes > 0, snapshotCount > 0 else { return false }
        return Double(freeAfter - freeBefore) < Double(expectedBytes) * expectedRiseFraction
    }

    /// Lo que se esperaba liberar y no apareció como espacio libre.
    public static func retainedBytes(expectedBytes: Int64, freeBefore: Int64, freeAfter: Int64) -> Int64 {
        max(0, expectedBytes - max(0, freeAfter - freeBefore))
    }

    /// Elemento de limpieza para la ficha `time-machine-snapshots` del catálogo vivo.
    public static func snapshotItem(catalog: Catalog, retainedBytes: Int64) -> CleanupItem? {
        guard let entry = catalog.entry(id: snapshotEntryID) else { return nil }
        return CleanupItem(id: entry.id, entry: entry, paths: [], bytes: max(0, retainedBytes), risk: entry.risk,
                           blockedByOpenApps: [], usedBy: [])
    }
}
