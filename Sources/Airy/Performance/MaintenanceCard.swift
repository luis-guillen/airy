import SwiftUI
import DiskMapCore

/// Mantenimiento reversible (siempre ámbar, por el embudo de limpieza) y elementos de inicio rotos (solo aviso).
struct MaintenanceCard: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    var body: some View {
        let session = model.performance
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Mantenimiento").font(.headline)
                    Spacer()
                    PrimaryButton(session.isCheckingSpotlight ? "Midiendo…" : "Comprobar Spotlight",
                                  systemImage: "magnifyingglass", style: .secondary,
                                  isBusy: session.isCheckingSpotlight) {
                        Task { await session.checkSpotlight() }
                    }
                    .fixedSize()
                }
                if let text = spotlightText(session) {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(nil)
                }
                if session.maintenance.isEmpty {
                    Text("Nada que ajustar.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(session.maintenance) { item in
                    HStack(alignment: .top, spacing: 10) {
                        RiskBadge(risk: .yourCall, compact: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout.weight(.semibold))
                            Text(item.entry.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                            if let result = session.maintenanceResults[item.id] {
                                Text(result).font(.caption.weight(.medium)).foregroundStyle(Theme.Airy.riskInk(.safe))
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Aplicar…") {
                            flow.requestClean([item], onOutcome: { outcome in
                                session.setMaintenanceResult(item.id, outcome)
                                Task { await session.refreshMaintenance() }
                            })
                        }
                        .disabled(flow.isBusy)
                    }
                }

                Divider().opacity(0.5)
                Text("Elementos de inicio rotos").font(.subheadline.weight(.semibold))
                if session.loginItems.isEmpty {
                    Text("Ningún elemento de inicio roto.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(session.loginItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.callout.weight(.semibold))
                            Text("Falta: \(item.missingProgram)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack {
                        Button("Abrir Ajustes de elementos de inicio") { NSWorkspace.shared.open(LoginItemsAudit.settingsURL) }
                        Spacer()
                    }
                    Text("Airy solo avisa; quítalos tú en Ajustes del Sistema.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func spotlightText(_ session: PerformanceSession) -> String? {
        switch session.spotlight {
        case nil: return nil
        case .fine(let s): return "Spotlight responde bien (\(Self.seconds(s)) s)."
        case .slow(let s):
            let onAC = session.snapshot?.battery?.onACPower ?? true
            return "Spotlight tarda \(Self.seconds(s)) s en buscar." + (onAC ? "" : " Conecta el cargador para poder reindexar.")
        case .disabled: return "Spotlight está desactivado en este disco."
        case .unknown: return "No se pudo medir Spotlight."
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Theme.locale))
    }
}
