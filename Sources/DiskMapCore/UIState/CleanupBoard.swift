import Foundation

/// Lógica pura de la vista Limpieza: grupos por riesgo, qué se puede marcar, qué entra en
/// "Limpiar todo lo seguro" y los textos de bloqueo y método. Sin SwiftUI, para poder probarla.
public struct CleanupBoard: Sendable {
    public struct Group: Sendable, Identifiable {
        public let risk: Risk
        /// Primero los destacados por perfil; luego de mayor a menor tamaño (empates por id, para un orden estable).
        public let items: [CleanupItem]
        public var id: Risk { risk }
        /// «Sin problema», «Tú decides» o «No borrar».
        public var title: String { risk.label }
        public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    /// «Sin problema», «Tú decides» y «No borrar», en ese orden y sin grupos vacíos. Lo de «Solo revisar» va
    /// aparte (`reviewItems`).
    public let groups: [Group]

    /// «Solo revisar»: informativos sin acción, de mayor a menor tamaño (empates por id).
    public let reviewItems: [CleanupItem]

    /// `hidden`: elementos ya limpiados que se ocultan al momento, antes de que llegue la nueva detección.
    public init(items: [CleanupItem], hidden: Set<String> = []) {
        let visible = items.filter { !hidden.contains($0.id) }
        reviewItems = visible.filter(Self.isReviewOnly).sorted { (a, b) in (a.bytes, b.id) > (b.bytes, a.id) }
        let actionable = visible.filter { !Self.isReviewOnly($0) }
        groups = [Risk.safe, .yourCall, .doNotTouch].compactMap { risk in
            // Por tamaño (el perfil «Para ti» está retirado: `highlighted` ya no ordena).
            let members = actionable.filter { $0.risk == risk }
                .sorted { a, b in (a.bytes, b.id) > (b.bytes, a.id) }
            return members.isEmpty ? nil : Group(risk: risk, items: members)
        }
    }

    /// Los elementos con grupo (sin «Solo revisar») en el orden de la pantalla.
    public var items: [CleanupItem] { groups.flatMap(\.items) }

    /// Todo lo que se enseña: los grupos (verde, ámbar, rojo) y después «Solo revisar».
    public var displayItems: [CleanupItem] { items + reviewItems }

    /// Informativo que se enseña con su consejo y sin casilla: `.info` con `reviewHint`, o que no es «No tocar»
    /// (Docker volumes y similares siguen en «No borrar»). Aunque las protecciones lo dejen en rojo, si tiene
    /// consejo es de revisión.
    public static func isReviewOnly(_ item: CleanupItem) -> Bool {
        guard case .info = item.entry.cleanup else { return false }
        return item.entry.reviewHint != nil || item.risk != .doNotTouch
    }

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

    /// `sizeNote` si existe («Tamaño desconocido»); si no, «hasta 3,6 GB» para limpiezas parciales, y «+» si el
    /// análisis no pudo leerlo todo.
    public static func sizeText(_ item: CleanupItem) -> String {
        if let note = item.sizeNote { return note }
        return amountText(item.bytes, upperBound: isPartial(item)) + (item.sizeIsPartial ? "+" : "")
    }

    public static func amountText(_ bytes: Int64, upperBound: Bool) -> String {
        upperBound ? "hasta \(Format.bytes(bytes))" : Format.bytes(bytes)
    }

    /// Suma de los elementos y si es solo un máximo (alguno es parcial).
    public static func total(_ items: [CleanupItem]) -> (bytes: Int64, upperBound: Bool) {
        (items.reduce(0) { $0 + $1.bytes }, items.contains(where: isPartial))
    }

    // MARK: Selección

    /// Tiene casilla si Airy puede actuar sobre él: ni "No tocar", ni protegido, ni solo informativo.
    public static func showsCheckbox(_ item: CleanupItem) -> Bool {
        guard item.risk != .doNotTouch, item.entry.risk != .doNotTouch, item.protection == nil else { return false }
        if case .info = item.entry.cleanup { return false }
        return true
    }

    /// Se puede marcar ahora: con casilla, sin apps abiertas que lo bloqueen, sin proyectos que lo usen,
    /// sin protección y sin otro bloqueo.
    public static func canSelect(_ item: CleanupItem) -> Bool {
        showsCheckbox(item) && item.blockedByOpenApps.isEmpty && item.usedBy.isEmpty
            && item.protection == nil && item.blockedReason == nil
    }

    /// Lo verde que se puede limpiar ya.
    public var greenSelection: Set<String> { Set(readySafeItems.map(\.id)) }

    /// «Seleccionar todo»: verde y ámbar que se pueden marcar. Nunca rojo, protegido, bloqueado ni informativo.
    public var fullSelection: Set<String> {
        Set(items.filter { $0.risk != .doNotTouch && Self.canSelect($0) }.map(\.id))
    }

    /// Tras una nueva detección: quita lo que ya no vale y marca los preseleccionados que el usuario aún no había
    /// visto (`seen`), para no volver a marcar lo que desmarcó. Devuelve también el `seen` actualizado.
    public func nextSelection(current: Set<String>, seen: Set<String>) -> (selection: Set<String>, seen: Set<String>) {
        var selection = pruned(current)
        var seenNow = seen
        for item in items where Self.canSelect(item) {
            if item.preselected, !seen.contains(item.id) { selection.insert(item.id) }
            seenNow.insert(item.id)
        }
        return (selection, seenNow)
    }

    /// «Borrar todo · 3,2 GB» o «Borrar todo · hasta 3,2 GB» si alguna limpieza es parcial.
    public static func deleteAllTitle(_ items: [CleanupItem]) -> String {
        let sum = total(items)
        return "Borrar todo · " + amountText(sum.bytes, upperBound: sum.upperBound)
    }

    public static let reviewBlockTitle = "Revisa: esto no se regenera solo o puede tener estado"

    /// Confirmación única: `regular` = verde; `review` = ámbar, en el orden recibido. Lo quitado (`removed`) y lo
    /// que no se puede marcar (rojo, protegido, bloqueado) no entran.
    public static func confirmSections(_ items: [CleanupItem], excluding removed: Set<String>)
        -> (regular: [CleanupItem], review: [CleanupItem]) {
        let kept = items.filter { !removed.contains($0.id) && canSelect($0) }
        return (kept.filter { $0.risk == .safe }, kept.filter { $0.risk == .yourCall })
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

    /// La orden de una vista previa (`CleanupPreview.wouldRun`), con el mismo entrecomillado.
    public static func commandLine(_ argv: [String]) -> String {
        argv.map(displayQuoted).joined(separator: " ")
    }

    /// Por qué una fila con casilla no se puede limpiar ahora (procesos abiertos, comprobación
    /// incompleta…), para enseñarlo en la propia fila. `nil` si no está bloqueada así o está protegida
    /// (entonces lo dice `protectionText`).
    public static func blockedReasonText(_ item: CleanupItem) -> String? {
        guard item.protection == nil, let reason = item.blockedReason, !reason.isEmpty else { return nil }
        return reason
    }

    /// Qué dice una fila protegida: «Protegido por ti» o «Protegido por Airy: <motivo>».
    public static func protectionText(_ protection: ProtectionMatch) -> String {
        switch protection.source {
        case .user: "Protegido por ti"
        case .airy: "Protegido por Airy: \(protection.reason)"
        }
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
            ? "Incluye 1 elemento marcado «Tú decides»: perderás algo al borrarlo."
            : "Incluye \(count) elementos marcados «Tú decides»: perderás algo al borrarlo."
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
    public var successes: [Success] = []
    public var problems: [Problem] = []

    /// Una limpieza que salió bien: título y qué pasó («Liberados 2 GB» / «1,2 GB a la Papelera»).
    public struct Success: Sendable, Equatable, Identifiable {
        public let title: String
        public let text: String
        public var id: String { title + "\u{1F}" + text }
        public init(title: String, text: String) { self.title = title; self.text = text }
    }

    public init() {}

    public mutating func record(id: String, title: String, outcome: CleanupOutcome) {
        switch outcome {
        case .freed(let bytes):
            freed += bytes
            succeededIDs.append(id)
            successes.append(Success(title: title, text: "Liberados \(Format.bytes(bytes))"))
        case .movedToTrash(let bytes):
            movedToTrash += bytes
            succeededIDs.append(id)
            successes.append(Success(title: title, text: "\(Format.bytes(bytes)) a la Papelera"))
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
