import SwiftUI
import DiskMapCore

/// Notice when Full Disk Access is missing: the app works, but it doesn't see everything.
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model
    var onDismiss: () -> Void

    var body: some View {
        GlassCard(padding: 16, radius: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Airy.riskFill(.yourCall))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.Airy.night)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Airy can’t see the whole disk")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                PrimaryButton("Grant Access", systemImage: "gearshape") {
                    model.openFullDiskAccessSettings()
                }
                .fixedSize()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Hide until next time")
            }
        }
    }

    private var detail: String {
        let base = String(localized: "Turn on Airy in System Settings › Privacy & Security › Full Disk Access to include Mail, Safari and apps’ protected data.")
        let count = model.inaccessibleCount
        guard count > 0 else { return base }
        return count == 1 ? String(localized: "\(base) 1 folder is skipped right now.")
                          : String(localized: "\(base) \(Theme.count(count)) folders are skipped right now.")
    }
}
