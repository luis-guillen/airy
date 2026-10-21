import SwiftUI
import DiskMapCore

/// Hoja de confirmación antes de cualquier borrado: qué se hace, cuánto ocupa y con qué método.
/// Es la única de la app (Limpieza, barra lateral, mapa y asistente). Si la petición trae un aviso
/// ("Esto depende de ti"), lo enseña primero y la confirmación real llega tras "Sí, quiero moverlo…".
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest
    @ViewState private var warningAccepted = false
    /// Vista previa del ejecutor (mismo plan que al confirmar), por fila. `nil` mientras se calcula.
    @ViewState private var previews: [String: CleanupPreview]?
    /// Filas que no se harán (id de elemento, ruta suelta o "trash") con su motivo.
    @ViewState private var blockReasons: [String: String]?
    /// Filas quitadas con un clic («Quitar»): no se borran y salen del total.
    @ViewState private var removed: Set<String> = []

    var body: some View {
        Group {
            if isQuit {
                QuitConfirmation(request: request)
            } else if let warning = request.warning, !warningAccepted {
                warningStep(warning)
                    .transition(.opacity.combined(with: .offset(x: -12)))
            } else if isUninstallerKind {
                UninstallConfirmContent(request: request)
                    .transition(.opacity.combined(with: .offset(x: 12)))
            } else {
                confirmation
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
        }
        .padding(24)
        .frame(width: 540)
        .animation(Theme.sectionSpring, value: warningAccepted)
        // Con aviso previo («Esto depende de ti», propuesta por enlace), la vista previa espera a que el
        // usuario lo acepte: abrir la hoja no consulta nada al ejecutor.
        .task(id: warningAccepted) {
            guard !isQuit, request.warning == nil || warningAccepted, blockReasons == nil else { return }
            await loadPreview()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .airyAssistantDebug)) { note in
            switch note.userInfo?["action"] as? String {
            case "second": warningAccepted = true
            case "cancel": flow.cancelSheet()
            default: break
            }
        }
        #endif
    }

    // MARK: Primer paso ("Depende de ti")

    private func warningStep(_ warning: CleanupFlow.ConfirmRequest.Warning) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Theme.Airy.riskFill(.yourCall).opacity(0.16))
                    Image(systemName: Theme.symbol(for: .yourCall))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(warning.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(warning.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("«\(warning.reason)»")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(nil)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(warning.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryButton("Sí, quiero moverlo…", systemImage: "arrow.right", style: .secondary) {
                    warningAccepted = true
                }
                .fixedSize()
            }
        }
    }

    // MARK: Confirmación

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if isItems {
                // Hasta cuatro filas caben sin desplazamiento; con más, alto fijo.
                if rows.count + reviewRows.count <= 4 {
                    itemBlocks
                } else {
                    ScrollView { itemBlocks }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 340)
                }
            } else {
                Group {
                    if rows.count <= 4 {
                        rowList
                    } else {
                        ScrollView { rowList }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: 300)
                    }
                }
                .modifier(RowBox())
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.text) { note in
                    Label {
                        Text(note.text)
                    } icon: {
                        Image(systemName: note.symbol).foregroundStyle(note.tint)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Intro solo confirma lo que se puede deshacer (todo a la Papelera). Vaciar la Papelera o
                // ejecutar un comando oficial es irreversible: hay que pulsar el botón.
                if returnConfirms {
                    confirmButton.keyboardShortcut(.defaultAction)
                } else {
                    confirmButton
                }
            }
        }
    }

    private var confirmButton: some View {
        PrimaryButton(confirmTitle, systemImage: confirmSymbol, style: isEmptyTrash ? .destructive : .primary) {
            flow.confirm(request, model: model, blocked: Set((blockReasons ?? [:]).keys), excluding: excluded)
        }
        .fixedSize()
        // Hasta tener la vista previa no se confirma; si todo está bloqueado o quitado, no hay nada que hacer.
        .disabled(blockReasons == nil || (rows + reviewRows).allSatisfy { blockReasons?[$0.id] != nil })
    }

    // MARK: Vista previa

    /// Pregunta al ejecutor qué haría cada fila ahora, con el `runID` de la tanda. Lo bloqueado sale
    /// tachado con su motivo y no se ejecuta.
    private func loadPreview() async {
        var reasons: [String: String] = [:]
        switch request.kind {
        case .items(let items):
            let previews = await model.preview(items, context: request.context)
            guard !Task.isCancelled else { return }
            for (id, preview) in previews { if case .blocked(let reason) = preview { reasons[id] = reason } }
            self.previews = previews
        case .trashPaths(let paths, _):
            for path in paths {
                if let refusal = model.destructiveRefusal ?? model.trashRefusal(path: path) { reasons[path] = refusal }
            }
        case .emptyTrash:
            if let refusal = model.destructiveRefusal { reasons["trash"] = refusal }
        case .uninstall, .orphans, .brokenLinks, .duplicates:
            break  // `UninstallConfirmContent` decide lo bloqueado.
        case .quitApps, .forceQuitApps: break
        }
        blockReasons = reasons
    }

    /// `true` solo si todo va a la Papelera (recuperable): ni vaciarla ni comandos oficiales.
    private var returnConfirms: Bool {
        switch request.kind {
        case .emptyTrash, .uninstall, .brokenLinks, .quitApps, .forceQuitApps: return false
        case .trashPaths, .orphans, .duplicates: return true
        case .items:
            return keptItems.allSatisfy { if case .trash = liveMethod($0) { true } else { false } }
        }
    }

    // MARK: Contenido

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.5).padding(.leading, 52) }
                ConfirmRowView(row: row, onRemove: isItems ? { remove([row.id]) } : nil)
            }
        }
    }

    /// Lista verde y, aparte, el bloque ámbar resaltado (cada fila con su «por qué»).
    private var itemBlocks: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !rows.isEmpty { rowList.modifier(RowBox()) }
            if !reviewRows.isEmpty {
                let amber = Theme.color(for: .yourCall)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Theme.symbol(for: .yourCall))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        Text(CleanupBoard.reviewBlockTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(nil)
                        Spacer(minLength: 8)
                        Button("Quitar todo lo ámbar") { remove(reviewRows.map(\.id)) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    ForEach(Array(reviewRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.5).padding(.leading, 52) }
                        ConfirmRowView(row: row, onRemove: { remove([row.id]) })
                    }
                }
                .background(amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(amber.opacity(0.6), lineWidth: 1)
                }
            }
            if rows.isEmpty && reviewRows.isEmpty {
                Text("Has quitado todo: no queda nada que borrar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private func remove(_ ids: [String]) {
        withAnimation(Theme.pressSpring) { removed.formUnion(ids) }
    }

    private var isItems: Bool { if case .items = request.kind { true } else { false } }

    /// Verde y ámbar que siguen en la hoja (lo quitado y lo que no se puede marcar no entran).
    private var sections: (regular: [CleanupItem], review: [CleanupItem]) {
        CleanupBoard.confirmSections(items, excluding: removed)
    }

    private var keptItems: [CleanupItem] { let s = sections; return s.regular + s.review }

    /// Lo que no se ejecuta: lo quitado y lo que la hoja no enseña (rojo, protegido o bloqueado).
    private var excluded: Set<String> {
        let kept = Set(keptItems.map(\.id))
        return Set(items.map(\.id).filter { !kept.contains($0) })
    }

    private var isEmptyTrash: Bool { if case .emptyTrash = request.kind { true } else { false } }

    private var isUninstallerKind: Bool {
        switch request.kind {
        case .uninstall, .orphans, .brokenLinks, .duplicates: true
        case .items, .emptyTrash, .trashPaths: false
        case .quitApps, .forceQuitApps: false
        }
    }

    private var isQuit: Bool {
        switch request.kind {
        case .quitApps, .forceQuitApps: true
        default: false
        }
    }

    private var items: [CleanupItem] {
        if case .items(let items) = request.kind { return items }
        return []
    }

    private func liveMethod(_ item: CleanupItem) -> CleanupMethod {
        model.catalog?.entry(id: item.entry.id)?.cleanup ?? item.entry.cleanup
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(isEmptyTrash
                              ? AnyShapeStyle(Theme.Airy.destructiveGradient)
                              : AnyShapeStyle(Theme.brand))
                Image(systemName: isEmptyTrash ? "trash.fill" : "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch request.kind {
        case .emptyTrash: return "¿Vaciar la Papelera?"
        case .trashPaths(let paths, let title):
            return paths.count == 1 ? "¿Mover «\(title)» a la Papelera?" : "¿Mover \(Theme.count(paths.count)) elementos a la Papelera?"
        case .items:
            let count = keptItems.count
            return count == 1 ? "¿Borrar 1 elemento?" : "¿Borrar \(Theme.count(count)) elementos?"
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        case .quitApps, .forceQuitApps: return ""
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .emptyTrash(let bytes):
            return bytes.map { "Se borrarán definitivamente \(Format.bytes($0))." }
                ?? "Airy no puede leer la Papelera, así que no sabe cuánto ocupa."
        case .quitApps, .forceQuitApps: return ""
        case .trashPaths(let paths, _):
            let total = paths.compactMap { model.node(atPath: $0)?.allocatedSize }.reduce(0, +)
            return total > 0 ? "\(Format.bytes(total)) irán a la Papelera. Se liberan al vaciarla."
                             : "Irá a la Papelera. Se libera al vaciarla."
        case .items:
            let items = keptItems
            guard !items.isEmpty else { return "No queda nada que borrar." }
            // Con limpiezas parciales (p. ej. `pnpm store prune`) la cifra es solo un máximo: "hasta X".
            let (total, upperBound) = CleanupBoard.total(items)
            let trash = items.filter { if case .trash = liveMethod($0) { true } else { false } }
            if trash.count == items.count { return "\(Format.bytes(total)) irán a la Papelera. Se liberan al vaciarla." }
            if trash.isEmpty {
                guard total > 0 else { return "Esto es lo que se va a hacer:" }
                return upperBound ? "Se liberarán hasta \(Format.bytes(total))." : "Se liberarán unos \(Format.bytes(total))."
            }
            return upperBound
                ? "Hasta \(Format.bytes(total)) en total. Lo que va a la Papelera se libera al vaciarla."
                : "Unos \(Format.bytes(total)) en total. Lo que va a la Papelera se libera al vaciarla."
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        }
    }

    private var rows: [ConfirmRow] {
        switch request.kind {
        case .quitApps, .forceQuitApps: return []
        case .emptyTrash(let bytes):
            return [ConfirmRow(id: "trash", title: "Vaciar Papelera", symbol: "trash.fill", tint: Theme.Airy.riskInk(.doNotTouch),
                               size: bytes.map(Format.bytes) ?? "Tamaño desconocido",
                               method: .text(bytes == nil ? "Lo hace Finder, en todos los discos" : "Borrado definitivo"),
                               location: "~/.Trash", blockedReason: blockReasons?["trash"])]
        case .trashPaths(let paths, _):
            return paths.map { path in
                ConfirmRow(id: path, title: (path as NSString).lastPathComponent, symbol: "doc", tint: Theme.Airy.accent,
                           size: model.node(atPath: path).map { Format.bytes($0.allocatedSize) } ?? "—",
                           method: .text(blockReasons == nil ? "A la Papelera" : "Irá a la Papelera"),
                           location: Format.tildePath(path), blockedReason: blockReasons?[path])
            }
        case .items:
            return sections.regular.map(itemRow)
        case .uninstall, .orphans, .brokenLinks, .duplicates: return []
        }
    }

    /// El bloque ámbar de la hoja (vacío para el resto de peticiones).
    private var reviewRows: [ConfirmRow] {
        isItems ? sections.review.map(itemRow) : []
    }

    private func itemRow(_ item: CleanupItem) -> ConfirmRow {
                let method = liveMethod(item)
                let size = item.id == TrashFollowUp.snapshotEntryID
                    ? (item.bytes > 0 ? "≈ \(Format.bytes(item.bytes))" : "Tamaño desconocido")
                    : CleanupBoard.sizeText(item)
                let planned: ConfirmRow.Method? = switch previews?[item.id] {
                case .wouldTrash: .text("Irá a la Papelera")
                case .wouldRun(let command, _, _): .willRun(CleanupBoard.commandLine(command))
                case .blocked, nil: nil
                }
                return ConfirmRow(id: item.id, title: item.title, symbol: CleanupIcon.symbol(for: item.entry),
                                  tint: Theme.ink(for: item.entry.kind), size: size,
                                  method: planned ?? CleanupBoard.commandLine(method).map(ConfirmRow.Method.command)
                                      ?? .text(CleanupBoard.methodDescription(method)),
                                  // Dónde: imprescindible cuando una ficha abarca muchas carpetas (p. ej. ~/Library/Logs/*).
                                  location: CleanupBoard.locationSummary(item),
                                  blockedReason: blockReasons?[item.id],
                                  why: item.risk == .yourCall ? RiskExplanation.why(item) : nil,
                                  detail: Self.detailLine(item))
    }

    /// «Contenedores parados: a, b y c» (Docker); para el resto, nada.
    static func detailLine(_ item: CleanupItem) -> String? {
        guard item.entry.id == "docker-containers", !item.details.isEmpty else { return nil }
        let names = item.details
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " y " + names.last! : names[0]
        return "Contenedores parados: \(list)"
    }

    private struct Note { let symbol: String; let tint: Color; let text: String }

    private var notes: [Note] {
        previewNotes + kindNotes
    }

    private var previewNotes: [Note] {
        guard let blockReasons else {
            return [Note(symbol: "hourglass", tint: .secondary, text: "Comprobando qué se hará con cada elemento…")]
        }
        guard !blockReasons.isEmpty else { return [] }
        return [Note(symbol: "nosign", tint: Theme.Airy.riskInk(.doNotTouch),
                     text: "Lo tachado no se hará: Airy no puede hacerlo ahora.")]
    }

    private var kindNotes: [Note] {
        switch request.kind {
        case .quitApps, .forceQuitApps: return []
        case .emptyTrash(let bytes):
            let red = Theme.Airy.riskInk(.doNotTouch)
            if bytes == nil {
                return [Note(symbol: "exclamationmark.triangle.fill", tint: red,
                             text: "Sin Acceso total al disco se la pedirá a Finder, que vacía definitivamente la Papelera de todos los discos, también los externos."),
                        Note(symbol: "arrow.uturn.backward.circle", tint: red, text: "No se puede deshacer.")]
            }
            return [Note(symbol: "arrow.uturn.backward.circle", tint: red, text: "No se puede deshacer."),
                    Note(symbol: "externaldrive", tint: .secondary,
                         text: "Si algún archivo no se deja borrar, se le pedirá a Finder, que vacía también la Papelera de los discos externos.")]
        case .trashPaths:
            return [Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                         text: "Lo que va a la Papelera se puede recuperar hasta que la vacíes.")]
        case .items:
            let items = keptItems
            var notes: [Note] = []
            let methods = items.map(liveMethod)
            if methods.contains(where: { if case .trash = $0 { true } else { false } }) {
                notes.append(Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                                  text: "Lo que va a la Papelera se puede recuperar hasta que la vacíes."))
            }
            if items.allSatisfy({ $0.entry.section == .maintenance }) {
                notes.append(Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                                  text: "Es un ajuste reversible: la explicación dice cómo deshacerlo."))
            } else if methods.contains(where: { if case .command = $0 { true } else { false } }) {
                notes.append(Note(symbol: "terminal", tint: Theme.Airy.accent,
                                  text: "Los comandos oficiales liberan el espacio al momento y no se pueden deshacer."))
            }
            if items.contains(where: CleanupBoard.isPartial) {
                notes.append(Note(symbol: "chart.bar.xaxis", tint: .secondary,
                                  text: "«Hasta»: ese comando solo quita lo que ya no se usa, así que puede liberar menos."))
            }
            if items.count > 1 {
                notes.append(Note(symbol: "list.number", tint: .secondary,
                                  text: "Se hacen de uno en uno; antes de cada uno se vuelve a comprobar que sigue siendo seguro."))
            }
            return notes
        case .uninstall, .orphans, .brokenLinks, .duplicates: return []
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .emptyTrash(let bytes): return bytes == nil ? "Vaciar con Finder" : "Vaciar Papelera"
        case .trashPaths: return "Mover a la Papelera"
        case .items:
            if keptItems.allSatisfy({ $0.entry.section == .maintenance }) { return "Aplicar" }
            let (bytes, upperBound) = CleanupBoard.total(keptItems)
            return "Borrar \(Theme.count(keptItems.count)) · " + CleanupBoard.amountText(bytes, upperBound: upperBound)
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        case .quitApps, .forceQuitApps: return ""
        }
    }

    private var confirmSymbol: String { isEmptyTrash ? "trash.slash" : "sparkles" }
}

struct ConfirmRow: Identifiable {
    /// `command`: la orden del catálogo; `willRun`: la que el ejecutor confirmó en la vista previa.
    enum Method { case text(String), command(String), willRun(String) }
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let size: String
    let method: Method
    /// Dónde está lo que se toca ("~/Library/Logs/A", "Todo lo que hay en ~/Library/Logs (17 elementos)").
    var location: String?
    /// La vista previa dice que no se hará (y por qué): la fila sale tachada.
    var blockedReason: String?
    /// Por qué es ámbar (solo en el bloque ámbar).
    var why: String?
    /// Línea extra, p. ej. «Contenedores parados: a, b y c».
    var detail: String?
}

/// Caja de la lista de filas de la hoja.
private struct RowBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
            }
    }
}

private struct ConfirmRowView: View {
    let row: ConfirmRow
    /// «Quitar» (un clic): la fila sale de la hoja y del total.
    var onRemove: (() -> Void)? = nil

    private func isWillRun(_ method: ConfirmRow.Method) -> Bool {
        if case .willRun = method { true } else { false }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(row.tint.opacity(0.18))
                Image(systemName: row.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .strikethrough(row.blockedReason != nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.size)
                        .font(.callout.weight(.semibold))
                        .strikethrough(row.blockedReason != nil)
                        .monospacedDigit()
                    if let onRemove {
                        Button("Quitar", action: onRemove)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Airy.accent)
                            .help("No borrar esto")
                    }
                }
                .foregroundStyle(row.blockedReason == nil ? .primary : .secondary)
                if let why = row.why {
                    Text(why)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        .lineLimit(nil)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let reason = row.blockedReason {
                    Label(reason, systemImage: "nosign")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                        .lineLimit(3)
                }
                switch row.method {
                case .text(let text):
                    Label(text, systemImage: text.lowercased().hasSuffix("a la papelera") ? "trash" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(row.blockedReason != nil)
                case .command(let line), .willRun(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isWillRun(row.method) ? "Se ejecutará" : "Comando oficial:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                if let location = row.location {
                    Label(location, systemImage: "folder")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Instantáneas de Time Machine

/// Tras vaciar la Papelera, si el espacio no ha aparecido y hay instantáneas locales, lo explica
/// y ofrece reducirlas con la ficha `time-machine-snapshots` del catálogo (con su confirmación).
struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let notice: CleanupFlow.SnapshotNotice

    var body: some View {
        let entry = model.catalog?.entry(id: TrashFollowUp.snapshotEntryID)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Theme.gradient(for: .system))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("El espacio aún no ha aparecido")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Has vaciado \(Format.bytes(notice.emptied)), pero el espacio libre solo ha subido \(Format.bytes(notice.rose)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GlassCard(padding: 16, radius: 14, material: .thinMaterial) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(notice.snapshotCount == 1 ? "1 instantánea local de Time Machine"
                                  : "\(Theme.count(notice.snapshotCount)) instantáneas locales de Time Machine",
                              systemImage: "camera.metering.matrix")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("≈ \(Format.bytes(notice.retained)) retenidos")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("Las instantáneas guardan una copia de lo que había en el disco, así que lo que acabas de borrar sigue ocupando sitio hasta que caduquen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let entry {
                        Text(entry.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("Comando oficial:").font(.caption).foregroundStyle(.secondary)
                            Text(CleanupBoard.commandLine(entry.cleanup) ?? "")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                RiskBadge(risk: entry?.risk ?? .yourCall)
                Spacer()
                Button("Ahora no") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryButton("Reducir instantáneas…", systemImage: "clock.arrow.circlepath") {
                    flow.requestSnapshotCleanup(notice, model: model)
                }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .disabled(entry == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

// MARK: - Cerrar apps (Rendimiento)

/// Las dos variantes de cierre: normal («¿Cerrar…?») y forzado («¿Forzar el cierre de…?»). Una propuesta de
/// agente enseña su aviso arriba; nada se cierra hasta pulsar el botón.
struct QuitConfirmation: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest

    private var groups: [AppGroup] {
        switch request.kind {
        case .quitApps(let g), .forceQuitApps(let g): g
        default: []
        }
    }

    private var isForce: Bool { if case .forceQuitApps = request.kind { true } else { false } }

    private var title: String {
        if isForce {
            return groups.count == 1 ? "¿Forzar el cierre de \(groups[0].name)?" : "¿Forzar el cierre de \(groups.count) apps?"
        }
        return groups.count == 1 ? "¿Cerrar \(groups[0].name)?" : "¿Cerrar \(groups.count) apps?"
    }

    var body: some View {
        let apps = groups.filter { $0.kind != .looseProcess }
        let loose = groups.filter { $0.kind == .looseProcess }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(isForce ? AnyShapeStyle(Theme.Airy.destructiveGradient) : AnyShapeStyle(Theme.brand))
                    Image(systemName: isForce ? "xmark.octagon.fill" : "power")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(2)
            }

            if let warning = request.warning {
                VStack(alignment: .leading, spacing: 4) {
                    Label(warning.title, systemImage: Theme.symbol(for: .yourCall))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    Text(warning.subtitle).font(.callout).foregroundStyle(.secondary)
                    Text(warning.reason).font(.callout).lineLimit(nil)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !apps.isEmpty { rowBlock(apps) }
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Revisa: puede que estés usándolo", systemImage: Theme.symbol(for: .yourCall))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    Text(QuitPolicy.looseWarning).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                    rowBlock(loose)
                }
                .padding(10)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Label(isForce ? "No respondió al cierre normal. Se perderá lo que no esté guardado."
                          : "Primero se pide a cada app que se cierre; si tiene algo sin guardar, te lo preguntará.",
                  systemImage: isForce ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(nil)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Forzar: rol destructivo y sin Intro.
                PrimaryButton(isForce ? "Forzar cierre" : "Cerrar", systemImage: isForce ? "xmark.octagon" : "power",
                              style: isForce ? .destructive : .primary) {
                    flow.confirm(request, model: model)
                }
                .fixedSize()
            }
        }
    }

    private func rowBlock(_ groups: [AppGroup]) -> some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                HStack {
                    Text(group.detail.map { "\(group.name) · \($0)" } ?? group.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(Format.bytes(group.memory)) · \(group.pids.count == 1 ? "1 proceso" : "\(group.pids.count) procesos")")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
