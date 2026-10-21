import AppKit
import SwiftUI
import DiskMapCore

/// Detalle de una app: sus restos agrupados por riesgo (verde, ámbar, rojo) con casilla, ruta, tamaño y
/// motivo. Lo rojo nunca tiene casilla.
struct UninstallDetail: View {
    @Environment(CleanupFlow.self) private var flow
    let store: UninstallerStore
    let plan: UninstallPlan

    var body: some View {
        let selected = store.selection(for: plan)
        let refusal = store.refusal(for: plan)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Apps", systemImage: "chevron.left") { store.openedApp = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.app.name).font(.title3.weight(.semibold))
                    Text("App \(Format.bytes(plan.appBytes)) + restos \(Format.bytes(plan.leftoverBytes))"
                         + (plan.sizeComplete ? "" : " (al menos)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            if let refusal {
                Label(refusal, systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
            }
            if let shared = plan.sharedWith {
                Label("Hay otra copia instalada en \(Format.tildePath(shared)): sus datos se quedan.",
                      systemImage: "square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if plan.leftovers.isEmpty {
                        Text("No se han encontrado restos de esta app.").foregroundStyle(.secondary)
                    }
                    ForEach([Risk.safe, .yourCall, .doNotTouch], id: \.self) { risk in
                        let group = plan.leftovers.filter { $0.risk == risk }
                        if !group.isEmpty { section(risk, group, selected: selected) }
                    }
                }
                .padding(.bottom, 70)
            }
        }
        .overlay(alignment: .bottom) {
            if refusal == nil {
                PrimaryButton("Desinstalar · \(Format.bytes(plan.bytes(selected: selected)))", systemImage: "trash") {
                    flow.requestUninstall([store.request(for: plan)])
                }
                .fixedSize()
                .disabled(flow.isBusy)
                .padding(.bottom, 18)
            }
        }
    }

    private func section(_ risk: Risk, _ leftovers: [Leftover], selected: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RiskBadge(risk: risk)
                Spacer()
                Text(Format.bytes(leftovers.reduce(0) { $0 + $1.bytes }))
                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(leftovers.enumerated()), id: \.element.id) { index, leftover in
                        if index > 0 { Divider().opacity(0.5).padding(.leading, 40) }
                        row(leftover, selected: selected)
                    }
                }
            }
        }
    }

    private func row(_ leftover: Leftover, selected: Set<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if leftover.canSelect {
                    Toggle("", isOn: Binding(get: { selected.contains(leftover.id) },
                                             set: { _ in store.toggle(leftover, in: plan) }))
                        .toggleStyle(.airyCheckbox)
                        .labelsHidden()
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.kind == .receipt ? "Registro de instalación \(leftover.path)" : Format.tildePath(leftover.path))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(leftover.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(leftover.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(leftover.canSelect ? .primary : .secondary)
    }
}
