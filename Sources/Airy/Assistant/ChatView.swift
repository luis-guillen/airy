import SwiftUI
import DiskMapCore

/// Messages-style chat: the answer streams in with a blinking cursor; the scan paths
/// it mentions show up as "Show on Map".
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var position = ScrollPosition(edge: .bottom)
    @FocusState private var composerFocused: Bool

    private var session: AssistantSession { model.assistant }

    static let suggestions = [String(localized: "What takes up the most space?"), String(localized: "What can I safely delete?"),
                              String(localized: "What is ~/Library/Containers?")]

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if session.transcript.bubbles.isEmpty {
                    ChatWelcome { session.send($0, model: model) }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    transcript
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.sectionSpring, value: session.transcript.bubbles.isEmpty)

            composer
        }
        .onAppear { composerFocused = true }
    }

    // MARK: Conversation

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(session.transcript.bubbles) { bubble in
                    ChatBubbleRow(bubble: bubble, isLast: bubble.id == session.transcript.bubbles.last?.id)
                        .id(bubble.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.97, anchor: bubble.role == .user ? .bottomTrailing : .bottomLeading)),
                            removal: .opacity))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .animation(Theme.zoomSpring, value: session.transcript.bubbles.count)
        }
        // No link in an answer opens anything outside the app (besides, `ChatText` already strips them).
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.automatic)
        .onChange(of: session.transcript.bubbles.last?.text.count) { _, _ in
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: session.transcript.bubbles.count) { _, _ in
            withAnimation(Theme.zoomSpring) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: session.transcript.bubbles.last?.routes.count) { _, _ in
            withAnimation(Theme.zoomSpring) { position.scrollTo(edge: .bottom) }
        }
    }

    // MARK: Compose

    private var composer: some View {
        @Bindable var session = session
        let streaming = session.transcript.isStreaming
        let canSend = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !streaming
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask anything about your disk…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { if canSend { session.send(session.draft, model: model) } }
                    .padding(.vertical, 6)

                Button {
                    if streaming { session.stop() } else { session.send(session.draft, model: model) }
                } label: {
                    Image(systemName: streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: streaming ? 11 : 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background {
                            Circle().fill(streaming ? AnyShapeStyle(Color.primary.opacity(0.55))
                                                    : AnyShapeStyle(Theme.brand))
                        }
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(streaming || canSend ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!streaming && !canSend)
                .keyboardShortcut(streaming ? KeyboardShortcut(".", modifiers: .command) : nil)
                .help(streaming ? "Stop the Answer (⌘.)" : "Send")
                .animation(Theme.pressSpring, value: streaming)
                .animation(Theme.pressSpring, value: canSend)
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(composerFocused ? Theme.userFilesColor.opacity(0.45) : Color.primary.opacity(0.10),
                                  lineWidth: composerFocused ? 1 : 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .animation(Theme.pressSpring, value: composerFocused)

            Text("Claude only sees paths, sizes and dates · Uses your Claude Code · may take up to a minute")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Welcome

private struct ChatWelcome: View {
    var onPick: (String) -> Void
    @ViewState private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            AssistantGlyph(symbol: "bubble.left.and.text.bubble.right.fill", size: 58)
                .symbolEffect(.bounce, value: appeared)
            VStack(spacing: 6) {
                Text("Ask Anything About Your Disk")
                    .font(.title3.weight(.semibold))
                Text("Claude knows the scan (paths, sizes, dates and Airy’s catalog), never the contents of your files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 8) {
                ForEach(Array(ChatView.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    SuggestionChip(text: suggestion) { onPick(suggestion) }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(Theme.stagger(index: index * 4), value: appeared)
                }
            }
            .padding(.top, 6)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }
}

private struct SuggestionChip: View {
    let text: String
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(hovering ? Theme.userFilesColor.opacity(0.5) : Color.primary.opacity(0.12),
                                                lineWidth: 0.75))
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 8 : 4, y: 2)
                .scaleEffect(hovering ? 1.03 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.pressSpring, value: hovering)
    }
}

// MARK: - Bubbles

private struct ChatBubbleRow: View {
    @Environment(AppModel.self) private var model
    let bubble: ChatBubble
    let isLast: Bool

    var body: some View {
        if bubble.role == .user {
            HStack {
                Spacer(minLength: 120)
                Text(bubble.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.brand, in: BubbleShape(isUser: true))
                    .shadow(color: Theme.userFilesColor.opacity(0.22), radius: 8, y: 3)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                AssistantGlyph(size: 26)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    assistantBubble
                    statusLine
                    if !bubble.routes.isEmpty {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(bubble.routes, id: \.self) { MapRouteChip(path: $0) }
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(Theme.zoomSpring, value: bubble.routes)
                Spacer(minLength: 100)
            }
        }
    }

    @ViewBuilder private var assistantBubble: some View {
        if bubble.status == .streaming && bubble.text.isEmpty {
            TypingDots()
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.regularMaterial, in: BubbleShape(isUser: false))
                .overlay(BubbleShape(isUser: false).stroke(Color.primary.opacity(0.08), lineWidth: 0.75))
        } else if !bubble.text.isEmpty {
            Group {
                if bubble.status == .streaming {
                    // The cursor blinks every half second without animating the text layout.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        Text(Self.rendered(bubble.text))
                            + Text(" ▍").foregroundStyle(Theme.userFilesColor.opacity(on ? 1 : 0.15))
                    }
                } else {
                    Text(Self.rendered(bubble.text))
                }
            }
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: BubbleShape(isUser: false))
            .overlay(BubbleShape(isUser: false).stroke(Color.primary.opacity(0.08), lineWidth: 0.75))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch bubble.status {
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                if isLast {
                    PrimaryButton("Try Again", systemImage: "arrow.clockwise", style: .secondary) {
                        model.assistant.retry(model: model)
                    }
                    .fixedSize()
                }
            }
            .padding(12)
            .background(Theme.color(for: .yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        default:
            EmptyView()
        }
    }

    /// Inline Markdown without links (see `ChatText`).
    static func rendered(_ text: String) -> AttributedString { ChatText.rendered(text) }
}

/// Bubble with the speaker's corner slightly less rounded, as in Messages.
private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18, small: CGFloat = 6
        return UnevenRoundedRectangle(
            topLeadingRadius: big, bottomLeadingRadius: isUser ? big : small,
            bottomTrailingRadius: isUser ? small : big, topTrailingRadius: big, style: .continuous)
            .path(in: rect)
    }
}

/// Three dots that pulse while the first chunk of the answer arrives.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(index == step ? 0.95 : 0.3)
                        .scaleEffect(index == step ? 1.15 : 1)
                        .animation(.easeInOut(duration: 0.25), value: step)
                }
            }
        }
        .accessibilityLabel("Claude is typing")
    }
}
