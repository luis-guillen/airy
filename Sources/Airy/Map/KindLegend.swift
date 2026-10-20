import SwiftUI
import DiskMapCore

/// Chips por tipo con lo que ocupa cada uno en el nivel actual. Al pasar el ratón por un chip,
/// el mapa atenúa las teselas de los demás tipos.
struct KindLegend: View {
    let node: FileNode
    var onHighlight: (ContentKind?) -> Void
    @ViewState private var hovered: ContentKind?

    private var slices: [(kind: ContentKind, bytes: Int64)] {
        zip(ContentKind.allCases, node.kindBytes)
            .map { (kind: $0, bytes: $1) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(slices.enumerated()), id: \.element.kind) { index, slice in
                    chip(slice.kind, bytes: slice.bytes)
                        .modifier(StaggeredAppear(index: index))
                }
            }
            .padding(.vertical, 2)
            // Cada nivel trae su fila nueva, con entrada escalonada (sin chips que se crucen).
            .id(node.id)
        }
        .scrollIndicators(.never)
        .onDisappear { onHighlight(nil) }
    }

    private func chip(_ kind: ContentKind, bytes: Int64) -> some View {
        let active = hovered == kind
        let dimmed = hovered != nil && !active
        return HStack(spacing: 7) {
            Circle()
                .fill(Theme.gradient(for: kind))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Theme.ink(for: kind), lineWidth: 1))
                .shadow(color: Theme.color(for: kind).opacity(active ? 0.7 : 0), radius: 4)
            Text(kind.title)
                .font(.callout.weight(.medium))
            Text(Format.bytes(bytes))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(active ? AnyShapeStyle(Theme.color(for: kind).opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.05)))
        }
        .overlay {
            Capsule().strokeBorder(Theme.color(for: kind).opacity(active ? 0.55 : 0.0), lineWidth: 0.75)
        }
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Capsule())
        .onHover { inside in
            if inside {
                hovered = kind
            } else if hovered == kind {
                hovered = nil
            }
            onHighlight(hovered)
        }
        .animation(Theme.pressSpring, value: active)
        .animation(Theme.pressSpring, value: dimmed)
        .help("\(kind.title): \(Format.bytes(bytes))")
    }
}

/// Aparece desde abajo y transparente, 12 ms después del anterior.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    @ViewState private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear { withAnimation(Theme.stagger(index: index)) { shown = true } }
    }
}
