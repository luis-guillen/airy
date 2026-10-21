import SwiftUI
import DiskMapCore

/// Confirmación del Desinstalador (`.uninstall`, `.orphans`, `.brokenLinks`) dentro de `ConfirmSheet`.
/// Dice qué se cierra, qué va a la Papelera, qué borra Homebrew directamente y qué se queda.
struct UninstallConfirmContent: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
            }
            if let refusal = model.destructiveRefusal {
                Label(refusal, systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Intro solo confirma lo que va entero a la Papelera (restos huérfanos).
                if case .orphans = request.kind {
                    confirmButton.keyboardShortcut(.defaultAction)
                } else {
                    confirmButton
                }
            }
        }
    }

    private var confirmButton: some View {
        PrimaryButton(confirmTitle, systemImage: "trash", style: isIrreversible ? .destructive : .primary) {
            flow.confirm(request, model: model, blocked: blocked)
        }
        .fixedSize()
        .disabled(model.destructiveRefusal != nil || nothingToDo)
    }

    // MARK: Datos

    /// Apps que Airy no desinstala (rechazo del plan): no se ejecutan.
    private var blocked: Set<String> {
        guard case .uninstall(let requests) = request.kind else { return [] }
        return Set(requests.filter { $0.plan.refusal != nil }.map(\.id))
    }

    private var nothingToDo: Bool {
        guard case .uninstall(let requests) = request.kind else { return false }
        return requests.allSatisfy { blocked.contains($0.id) }
    }

    private var isIrreversible: Bool {
        switch request.kind {
        case .brokenLinks: true
        case .uninstall(let requests): requests.contains { $0.plan.app.caskToken != nil }
        default: false
        }
    }

    private var title: String {
        switch request.kind {
        case .uninstall(let requests):
            requests.count == 1 ? "¿Desinstalar «\(requests[0].plan.app.name)»?"
                                : "¿Desinstalar \(Theme.count(requests.count)) apps?"
        case .orphans(let groups):
            groups.count == 1 ? "¿Mover los restos de «\(groups[0].bundleID)» a la Papelera?"
                              : "¿Mover \(Theme.count(groups.count)) restos huérfanos a la Papelera?"
        case .brokenLinks(let links):
            links.count == 1 ? "¿Quitar 1 enlace roto?" : "¿Quitar \(Theme.count(links.count)) enlaces rotos?"
        default: ""
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .uninstall(let requests):
            let total = requests.filter { !blocked.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.plan.bytes(selected: $1.selected) }
            return "Total: \(Format.bytes(total))."
        case .orphans(let groups):
            return "\(Format.bytes(groups.reduce(0) { $0 + $1.bytes })) irán a la Papelera. Se liberan al vaciarla."
        case .brokenLinks:
            return "Enlaces de /usr/local/bin que ya no apuntan a nada."
        default: return ""
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .uninstall(let requests):
            let count = requests.count - blocked.count
            return count <= 1 ? "Desinstalar" : "Desinstalar \(Theme.count(count)) apps"
        case .orphans: return "Mover a la Papelera"
        case .brokenLinks: return "Quitar enlaces rotos"
        default: return ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(isIrreversible ? AnyShapeStyle(Theme.Airy.destructiveGradient) : AnyShapeStyle(Theme.brand))
                Image(systemName: "xmark.app.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.title2, design: .rounded, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        switch request.kind {
        case .uninstall(let requests):
            ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                if index > 0 { Divider().opacity(0.5) }
                appSection(request)
            }
            if requests.count > 1 {
                note("list.number", .secondary,
                     "Se desinstalan de una en una; antes de cada una se vuelve a comprobar que sigue siendo seguro.")
            }
        case .orphans(let groups):
            ForEach(groups) { group in
                line(group.bundleID, detail: group.paths.map { Format.tildePath($0) }.joined(separator: "\n"),
                     size: group.bytes, risk: group.risk)
            }
            note("arrow.uturn.backward.circle", Theme.Airy.riskInk(.safe),
                 "Lo que va a la Papelera se puede recuperar hasta que la vacíes.")
            note("checkmark.shield", .secondary,
                 "Justo antes de moverlos, Airy vuelve a comprobar que su app sigue sin estar instalada.")
        case .brokenLinks(let links):
            ForEach(links) { link in
                line("\((link.path as NSString).lastPathComponent) → \(link.target)", detail: link.path, size: nil,
                     risk: nil)
            }
            note("exclamationmark.triangle.fill", Theme.Airy.riskInk(.yourCall),
                 "Los enlaces rotos se borran: no apuntan a nada y no van a la Papelera.")
            if links.contains(where: \.needsAdmin) {
                note("lock.fill", .secondary, "Pedirá tu contraseña de administrador.")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func appSection(_ request: UninstallRequest) -> some View {
        let plan = request.plan
        let app = plan.app
        let chosen = plan.leftovers.filter { $0.canSelect && request.selected.contains($0.id) }
        let green = chosen.filter { $0.risk == .safe }
        let amber = chosen.filter { $0.risk == .yourCall }
        let red = plan.leftovers.filter { !$0.canSelect }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.name).font(.headline).strikethrough(plan.refusal != nil)
                Spacer()
                Text(Format.bytes(plan.bytes(selected: request.selected)))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            if let refusal = plan.refusal {
                note("nosign", Theme.Airy.riskInk(.doNotTouch), "No se hará: \(refusal)")
            } else {
                note("power", .secondary, "Se cerrará «\(app.name)» si está abierta (podrá pedirte guardar).")
                if let token = app.caskToken {
                    if UninstallerStore.zapExpected(request) {
                        note("terminal", Theme.Airy.riskInk(.yourCall),
                             "Homebrew la desinstala con `brew uninstall --cask --zap \(token)`; lo que borra Homebrew no pasa por la Papelera.")
                    } else {
                        note("terminal", .secondary,
                             "Homebrew la desinstala con `brew uninstall --cask \(token)` (sin --zap: hay restos que no eliges o que Airy protege).")
                    }
                } else {
                    note("trash", Theme.Airy.riskInk(.safe), "La app irá a la Papelera.")
                }
                ForEach(green) { leftover in
                    line(Format.tildePath(leftover.path), detail: leftover.reason, size: leftover.bytes, risk: .safe)
                }
                if !amber.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Revisa: esto no se regenera solo", systemImage: Theme.symbol(for: .yourCall))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        ForEach(amber) { leftover in
                            line(Format.tildePath(leftover.path), detail: leftover.reason, size: leftover.bytes,
                                 risk: .yourCall)
                        }
                    }
                    .padding(10)
                    .background(Theme.Airy.riskFill(.yourCall).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !red.isEmpty {
                    Text("Se quedan").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(red) { leftover in
                        line(Format.tildePath(leftover.path), detail: leftover.reason, size: nil, risk: .doNotTouch)
                    }
                }
                if chosen.contains(where: { $0.kind == .receipt }) {
                    note("lock.fill", .secondary, "Pedirá tu contraseña de administrador.")
                }
            }
        }
    }

    private func line(_ title: String, detail: String?, size: Int64?, risk: Risk?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let risk { RiskBadge(risk: risk, compact: true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            if let size { Text(Format.bytes(size)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func note(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
