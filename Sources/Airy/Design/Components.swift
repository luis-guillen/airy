import SwiftUI
import DiskMapCore

/// In the macOS 27 SDK, `@State` resolves to a macro (`SwiftUIMacros.StateMacro`) whose plugin
/// only ships with Xcode; with Command Line Tools it doesn't compile. This alias points to the classic
/// `SwiftUI.State` *property wrapper* (same behaviour) and skips the macro lookup.
typealias ViewState = SwiftUI.State

// MARK: - GlassCard

/// Glass card: translucent material, a thin light border and a soft shadow.
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

/// Risk badge: "Safe to remove", "Your call" or "Don't delete". Text and icon in the mode's AA ink;
/// the background and border carry the fixed safety signal.
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

/// A size that counts up when it appears and rolls its digits on every change.
struct BytesCounter: View {
    let bytes: Int64
    var font: Font = .system(.title, design: .rounded, weight: .semibold)
    /// If `false`, it starts at the value already (useful in long lists).
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

/// Primary button with the brand gradient; `.secondary` is the glass variant.
struct PrimaryButton: View {
    enum Style { case primary, secondary, destructive }

    let title: Text
    var systemImage: String?
    var style: Style = .primary
    var isBusy = false
    let action: () -> Void

    /// A literal title is a localization key (like SwiftUI's `Button`).
    init(_ title: LocalizedStringKey, systemImage: String? = nil, style: Style = .primary,
         isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.style = style
        self.isBusy = isBusy
        self.action = action
    }

    /// A title already localized (a `String` value) is shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String? = nil, style: Style = .primary,
                            isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = Text(title)
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
                title
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

/// A separate view because the hover state needs `@State`, which a `ButtonStyle` doesn't keep.
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

// MARK: - Section header

/// Large title of each section with a dimmed subtitle.
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

// MARK: - Checkbox

/// Checkbox drawn in SwiftUI. The system `.checkbox` is an `NSButton` and, in lists that reorder
/// with animation (Performance every 1.5 s), it fell into a constraint loop that crashed the app.
struct AiryCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AiryCheckbox(configuration: configuration)
    }
}

private struct AiryCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(Theme.Airy.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == AiryCheckboxStyle {
    static var airyCheckbox: AiryCheckboxStyle { AiryCheckboxStyle() }
}
