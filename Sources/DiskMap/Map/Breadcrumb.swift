import SwiftUI

/// Ruta de navegación del mapa: botón Atrás (⌘[) y un botón por nivel para volver a él.
struct Breadcrumb: View {
    let items: [String]
    var onBack: () -> Void
    var onJump: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(items.count > 1 ? 0.08 : 0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .disabled(items.count <= 1)
            .opacity(items.count > 1 ? 1 : 0.35)
            .help("Subir un nivel (Esc o ⌘[)")
            .padding(.trailing, 6)

            ForEach(Array(items.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
                CrumbButton(title: title, isRoot: index == 0, isCurrent: index == items.count - 1) {
                    onJump(index)
                }
                .layoutPriority(index == items.count - 1 ? 1 : 0)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -8)), removal: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(Theme.zoomSpring, value: items)
    }
}

private struct CrumbButton: View {
    /// Nombres muy largos se recortan por el medio para que la ruta quepa en una línea.
    static func shortened(_ title: String, limit: Int = 30) -> String {
        guard title.count > limit else { return title }
        let half = (limit - 1) / 2
        return title.prefix(half) + "…" + title.suffix(half)
    }

    let title: String
    let isRoot: Bool
    let isCurrent: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isRoot {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(Self.shortened(title))
                    .lineLimit(1)
            }
            .font(.callout.weight(isCurrent ? .semibold : .medium))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(.primary.opacity(isCurrent ? 0.09 : (hovering ? 0.06 : 0)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.pressSpring, value: hovering)
        .help(isCurrent ? title : "Volver a \(title)")
    }
}
