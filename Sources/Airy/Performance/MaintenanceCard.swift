import SwiftUI
import DiskMapCore

/// Maintenance (amber at least, through the cleanup funnel; Spotlight can't be undone but deletes nothing) and broken login items (notice only).
struct MaintenanceCard: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    var body: some View {
        let session = model.performance
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Maintenance").font(.headline)
                    Spacer()
                    PrimaryButton(session.isCheckingSpotlight ? "Measuring…" : "Check Spotlight",
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
                    Text("Nothing to adjust.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(session.maintenance) { item in
                    HStack(alignment: .top, spacing: 10) {
                        RiskBadge(risk: item.risk, compact: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout.weight(.semibold))
                            Text(item.entry.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                            if let result = session.maintenanceResults[item.id] {
                                Text(result).font(.caption.weight(.medium)).foregroundStyle(Theme.Airy.riskInk(.safe))
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Apply…") {
                            flow.requestClean([item], onOutcome: { outcome in
                                session.setMaintenanceResult(item.id, outcome)
                                Task { await session.refreshMaintenance() }
                            })
                        }
                        .disabled(flow.isBusy)
                    }
                }

                Divider().opacity(0.5)
                Text("Broken Login Items").font(.subheadline.weight(.semibold))
                if session.loginItems.isEmpty {
                    Text("No broken login items.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(session.loginItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.callout.weight(.semibold))
                            Text("Missing: \(item.missingProgram)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack {
                        Button("Open Login Items Settings") { NSWorkspace.shared.open(LoginItemsAudit.settingsURL) }
                        Spacer()
                    }
                    Text("Airy only lets you know; remove them yourself in System Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func spotlightText(_ session: PerformanceSession) -> String? {
        switch session.spotlight {
        case nil: return nil
        case .fine(let s): return String(localized: "Spotlight responds well (\(Self.seconds(s)) s).")
        case .slow(let s):
            let onAC = session.snapshot?.battery?.onACPower ?? true
            return onAC ? String(localized: "Spotlight takes \(Self.seconds(s)) s to search.")
                : String(localized: "Spotlight takes \(Self.seconds(s)) s to search. Plug in the charger to be able to reindex.")
        case .disabled: return String(localized: "Spotlight is turned off on this disk.")
        case .unknown: return String(localized: "Couldn’t measure Spotlight.")
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Theme.locale))
    }
}
