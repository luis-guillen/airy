import SwiftUI
import DiskMapCore

/// En el SDK de macOS 27, `@State` se resuelve a una macro (`SwiftUIMacros.StateMacro`) cuyo plugin
/// solo trae Xcode; con Command Line Tools no compila. Este alias apunta al *property wrapper*
/// `SwiftUI.State` de siempre (mismo comportamiento) y evita la búsqueda de la macro.
typealias ViewState = SwiftUI.State

// MARK: - GlassCard

/// Tarjeta de cristal: material translúcido, borde de luz fino y sombra suave.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.padding
    var radius: CGFloat = Theme.cardRadius
    var material: Material = .regularMaterial
    @ViewBuilder var content: Content
    @Environment(\.airyQuietShadows) private var quietShadows

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(material)
                    .shadow(color: .black.opacity(quietShadows ? 0 : 0.10), radius: quietShadows ? 0 : 14,
                            y: quietShadows ? 0 : 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
            }
    }
}

// MARK: - RiskBadge

/// Etiqueta de riesgo: «Sin problema», «Tú decides» o «No borrar». Texto e icono en la tinta AA del
/// modo; el fondo y el borde llevan la señal de seguridad fija.
struct RiskBadge: View {
    let risk: Risk
    var compact = false
    var reason: String?

    init(risk: Risk, compact: Bool = false, reason: String? = nil) {
        self.risk = risk
        self.compact = compact
        self.reason = reason
    }

    var body: some View {
        let fill = Theme.Airy.riskFill(risk)
        Label {
            if !compact { Text(risk.label) }
        } icon: {
            Image(systemName: Theme.symbol(for: risk))
                .imageScale(.small)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.Airy.riskInk(risk))
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, 4)
        .background(fill.opacity(AiryPalette.badgeTintOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(fill.opacity(0.35), lineWidth: 0.5))
        .help(reason ?? risk.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reason.map { "\(risk.label). \($0)" } ?? risk.label)
    }
}

// MARK: - BytesCounter

/// Tamaño que cuenta hacia arriba al aparecer y rueda sus cifras en cada cambio.
struct BytesCounter: View {
    let bytes: Int64
    var font: Font = .system(.title, design: .rounded, weight: .semibold)
    /// Si es `false`, empieza ya en el valor (útil en listas largas).
    var countsUpOnAppear = true

    @ViewState private var shown: Int64?

    var body: some View {
        let value = shown ?? (countsUpOnAppear ? 0 : bytes)
        Text(Format.bytes(value))
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .onAppear {
                if countsUpOnAppear {
                    shown = 0
                    withAnimation(Theme.counterSpring) { shown = bytes }
                } else {
                    shown = bytes
                }
            }
            .onChange(of: bytes) { _, newValue in
                withAnimation(Theme.counterSpring) { shown = newValue }
            }
            .accessibilityLabel(Format.bytes(bytes))
    }
}

// MARK: - PrimaryButton

/// Botón principal con degradado de marca; `.secondary` es la variante de cristal.
struct PrimaryButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    var systemImage: String?
    var style: Style = .primary
    var isBusy = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, style: Style = .primary,
         isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).imageScale(.medium)
                }
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(style: style))
        .disabled(isBusy)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var style: PrimaryButton.Style = .primary

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, style: style)
    }
}

/// Vista aparte porque el estado de hover necesita `@State`, que un `ButtonStyle` no conserva.
private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PrimaryButton.Style
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background { background }
            .overlay {
                Capsule().strokeBorder(.white.opacity(style == .secondary ? 0.15 : 0.25), lineWidth: 0.5)
            }
            .clipShape(Capsule())
            .shadow(color: shadowColor.opacity(isEnabled && style != .secondary ? 0.35 : 0),
                    radius: hovering ? 10 : 6, y: 3)
            .brightness(hovering && isEnabled ? 0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .hoverSway(hovering && isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.pressSpring, value: configuration.isPressed)
            .animation(Theme.pressSpring, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }

    private var foreground: AnyShapeStyle {
        style == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)
    }

    private var shadowColor: Color {
        style == .destructive ? Theme.Airy.destructiveBottom : Theme.Airy.accent
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .primary: Capsule().fill(Theme.brand)
        case .secondary: Capsule().fill(.thinMaterial)
        case .destructive:
            Capsule().fill(Theme.Airy.destructiveGradient)
        }
    }
}

// MARK: - Cabecera de sección

/// Título grande de cada sección con subtítulo atenuado.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 16)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
