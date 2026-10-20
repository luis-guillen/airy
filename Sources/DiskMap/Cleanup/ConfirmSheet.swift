import SwiftUI
import DiskMapCore

/// Hoja de confirmación antes de cualquier borrado: qué se hace, cuánto ocupa y con qué método.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Group {
                // Hasta cuatro filas caben sin desplazamiento; con más, lista de alto fijo.
                if rows.count <= 4 {
                    rowList
                } else {
                    ScrollView { rowList }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 300)
                }
            }
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
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
                PrimaryButton(confirmTitle, systemImage: confirmSymbol, style: isEmptyTrash ? .destructive : .primary) {
                    flow.confirm(request, model: model)
                }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    // MARK: Contenido

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.5).padding(.leading, 52) }
                ConfirmRowView(row: row)
            }
        }
    }

    private var isEmptyTrash: Bool { if case .emptyTrash = request.kind { true } else { false } }

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
                              ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF6961), Color(hex: 0xFF3B30)],
                                                             startPoint: .top, endPoint: .bottom))
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
        case .items(let items):
            return items.count == 1 ? "¿Limpiar «\(items[0].title)»?" : "¿Limpiar \(Theme.count(items.count)) elementos?"
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .emptyTrash(let bytes):
            return bytes.map { "Se borrarán definitivamente \(Format.bytes($0))." }
                ?? "DiskMap no puede leer la Papelera, así que no sabe cuánto ocupa."
        case .trashPaths(let paths, _):
            let total = paths.compactMap { model.node(atPath: $0)?.allocatedSize }.reduce(0, +)
            return total > 0 ? "\(Format.bytes(total)) irán a la Papelera. Se liberan al vaciarla."
                             : "Irá a la Papelera. Se libera al vaciarla."
        case .items(let items):
            let total = items.reduce(Int64(0)) { $0 + $1.bytes }
            let trash = items.filter { if case .trash = liveMethod($0) { true } else { false } }
            if trash.count == items.count { return "\(Format.bytes(total)) irán a la Papelera. Se liberan al vaciarla." }
            if trash.isEmpty { return total > 0 ? "Se liberarán unos \(Format.bytes(total))." : "Esto es lo que se va a hacer:" }
            return "Unos \(Format.bytes(total)) en total. Lo que va a la Papelera se libera al vaciarla."
        }
    }

    private var rows: [ConfirmRow] {
        switch request.kind {
        case .emptyTrash(let bytes):
            return [ConfirmRow(id: "trash", title: "Vaciar Papelera", symbol: "trash.fill", tint: Theme.color(for: .doNotTouch),
                               size: bytes.map(Format.bytes) ?? "Tamaño desconocido",
                               method: .text(bytes == nil ? "Lo hace Finder, en todos los discos" : "Borrado definitivo"),
                               location: "~/.Trash")]
        case .trashPaths(let paths, _):
            return paths.map { path in
                ConfirmRow(id: path, title: (path as NSString).lastPathComponent, symbol: "doc", tint: Theme.userFilesColor,
                           size: model.node(atPath: path).map { Format.bytes($0.allocatedSize) } ?? "—",
                           method: .text("A la Papelera"), location: Format.tildePath(path))
            }
        case .items(let items):
            return items.map { item in
                let method = liveMethod(item)
                let size = item.id == TrashFollowUp.snapshotEntryID
                    ? (item.bytes > 0 ? "≈ \(Format.bytes(item.bytes))" : "Tamaño desconocido")
                    : Format.bytes(item.bytes)
                return ConfirmRow(id: item.id, title: item.title, symbol: CleanupIcon.symbol(for: item.entry),
                                  tint: Theme.color(for: item.entry.kind), size: size,
                                  method: CleanupBoard.commandLine(method).map(ConfirmRow.Method.command)
                                      ?? .text(CleanupBoard.methodDescription(method)),
                                  // Dónde: imprescindible cuando una ficha abarca muchas carpetas (p. ej. ~/Library/Logs/*).
                                  location: CleanupBoard.locationSummary(item))
            }
        }
    }

    private struct Note { let symbol: String; let tint: Color; let text: String }

    private var notes: [Note] {
        switch request.kind {
        case .emptyTrash(let bytes):
            let red = Theme.color(for: .doNotTouch)
            if bytes == nil {
                return [Note(symbol: "exclamationmark.triangle.fill", tint: red,
                             text: "Sin Acceso total al disco se la pedirá a Finder, que vacía definitivamente la Papelera de todos los discos, también los externos."),
                        Note(symbol: "arrow.uturn.backward.circle", tint: red, text: "No se puede deshacer.")]
            }
            return [Note(symbol: "arrow.uturn.backward.circle", tint: red, text: "No se puede deshacer."),
                    Note(symbol: "externaldrive", tint: .secondary,
                         text: "Si algún archivo no se deja borrar, se le pedirá a Finder, que vacía también la Papelera de los discos externos.")]
        case .trashPaths:
            return [Note(symbol: "arrow.uturn.backward.circle", tint: Theme.color(for: .safe),
                         text: "Lo que va a la Papelera se puede recuperar hasta que la vacíes.")]
        case .items(let items):
            var notes: [Note] = []
            let methods = items.map(liveMethod)
            if methods.contains(where: { if case .trash = $0 { true } else { false } }) {
                notes.append(Note(symbol: "arrow.uturn.backward.circle", tint: Theme.color(for: .safe),
                                  text: "Lo que va a la Papelera se puede recuperar hasta que la vacíes."))
            }
            if methods.contains(where: { if case .command = $0 { true } else { false } }) {
                notes.append(Note(symbol: "terminal", tint: Theme.userFilesColor,
                                  text: "Los comandos oficiales liberan el espacio al momento y no se pueden deshacer."))
            }
            let yourCall = items.filter { $0.risk == .yourCall }
            if !yourCall.isEmpty {
                notes.append(Note(symbol: Theme.symbol(for: .yourCall), tint: Theme.color(for: .yourCall),
                                  text: yourCall.count == 1 && items.count == 1
                                      ? "«Depende de ti»: \(yourCall[0].entry.explanation)"
                                      : CleanupBoard.yourCallNote(count: yourCall.count)))
            }
            if items.count > 1 {
                notes.append(Note(symbol: "list.number", tint: .secondary,
                                  text: "Se hacen de uno en uno; antes de cada uno se vuelve a comprobar que sigue siendo seguro."))
            }
            return notes
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .emptyTrash(let bytes): return bytes == nil ? "Vaciar con Finder" : "Vaciar Papelera"
        case .trashPaths: return "Mover a la Papelera"
        case .items(let items): return items.count == 1 ? "Limpiar" : "Limpiar \(Theme.count(items.count))"
        }
    }

    private var confirmSymbol: String { isEmptyTrash ? "trash.slash" : "sparkles" }
}

struct ConfirmRow: Identifiable {
    enum Method { case text(String), command(String) }
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let size: String
    let method: Method
    /// Dónde está lo que se toca ("~/Library/Logs/A", "Todo lo que hay en ~/Library/Logs (17 elementos)").
    var location: String?
}

private struct ConfirmRowView: View {
    let row: ConfirmRow

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
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.size)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                switch row.method {
                case .text(let text):
                    Label(text, systemImage: text == "A la Papelera" ? "trash" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .command(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Comando oficial:")
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
