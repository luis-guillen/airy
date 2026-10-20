import SwiftUI
import DiskMapCore

/// Sección Asistente IA: selector Informe / Chat sobre el análisis, con Claude Code local.
struct AssistantView: View {
    @Environment(AppModel.self) private var model

    private var session: AssistantSession { model.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Asistente IA", subtitle: "Claude revisa tu análisis: rutas, tamaños y fechas, nunca el contenido") {
                Picker("Modo", selection: Binding(get: { session.mode }, set: { session.mode = $0 })) {
                    ForEach(AssistantSession.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 34)
        // Durante un reanálisis la píldora de progreso ocupa el pie.
        .padding(.bottom, model.isScanning && model.scan != nil ? 76 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            session.locateIfNeeded()
            consumePendingQuestion()
        }
        .onChange(of: model.pendingAssistantQuestion) { _, _ in consumePendingQuestion() }
        #if DEBUG
        .task { await AssistantDebugScript.run(model: model) }
        #endif
    }

    @ViewBuilder private var content: some View {
        Group {
            // «Conectar agente» no depende de Claude Code: otros agentes también pueden usar Airy.
            if session.mode == .agents {
                AgentsView()
                    .transition(.opacity)
            } else {
            switch session.claude {
            case .unknown, .searching:
                SearchingClaudeView()
                    .transition(.opacity)
            case .missing(let chosen):
                ClaudeMissingView(chosen: chosen)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .ready:
                ZStack {
                    if session.mode == .report {
                        ReportView()
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -14)), removal: .opacity))
                    } else {
                        ChatView()
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
                    }
                }
                .animation(Theme.sectionSpring, value: session.mode)
            }
            }
        }
        .animation(Theme.sectionSpring, value: session.claude)
        .animation(Theme.sectionSpring, value: session.mode == .agents)
    }

    /// "Explicar con IA" del mapa: pasa al chat y la envía una sola vez.
    private func consumePendingQuestion() {
        guard let question = model.pendingAssistantQuestion else { return }
        model.pendingAssistantQuestion = nil
        session.mode = .chat
        session.ask(question, model: model)
    }
}

/// Mientras se comprueba `claude --version` (un instante).
private struct SearchingClaudeView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Buscando Claude Code…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Piezas compartidas

/// Icono de la marca en un cuadrado redondeado (cabeceras del informe y del chat).
struct AssistantGlyph: View {
    var symbol = "sparkles"
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.brand)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.userFilesColor.opacity(0.3), radius: size * 0.2, y: size * 0.08)
    }
}

/// Coste y tiempo, sin precios: la llamada usa la cuenta de Claude Code del usuario.
struct CostNote: View {
    var body: some View {
        Text("Usa tu Claude Code · puede tardar hasta un minuto")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// Barrido de brillo para el estado de carga: un degradado que recorre el contenido (enmascarado
/// por él). La animación va acotada al desplazamiento para no arrastrar cambios de diseño.
struct Shimmer: ViewModifier {
    @ViewState private var phase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(colors: [.clear, .white.opacity(colorScheme == .dark ? 0.16 : 0.55), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(width * 0.45, 120))
                        .animation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            $0.offset(x: -max(width * 0.45, 120) + phase * (width + max(width * 0.45, 120)))
                        }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .geometryGroup()
            .onAppear { phase = 1 }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Distribuye chips en filas (salta de línea cuando no caben).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(fitted))
                x += fitted.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !current.indices.isEmpty, current.width + spacing + itemWidth > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Píldora "Ver en el mapa" para una ruta.
struct MapRouteChip: View {
    @Environment(AppModel.self) private var model
    let path: String
    @ViewState private var hovering = false

    var body: some View {
        Button {
            model.showInMap(path: path)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.square")
                    .foregroundStyle(Theme.userFilesColor)
                Text(Format.tildePath(path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Text("Ver en el mapa")
                    .foregroundStyle(Theme.userFilesColor)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.userFilesColor.opacity(hovering ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.userFilesColor.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.pressSpring, value: hovering)
        .help("Abrir \(Format.tildePath(path)) en el mapa")
    }
}

#if DEBUG
/// Solo en Debug: pasos programados del asistente para revisarlo sin ratón.
/// `AIRY_ASSISTANT_SCRIPT="report@3,chat@20,ask:¿Qué ocupa más?@21,confirm:0@30,missing@40"`.
/// Acciones: `report` (lanza el informe), `chat`, `agents`, `informe`, `ask:<pregunta>`, `stop`,
/// `confirm:<columna>` (abre la confirmación de la primera recomendación con botón de esa columna),
/// `second` (pasa a la segunda confirmación), `cancel`, `pending:<pregunta>` (como "Explicar con IA").
@MainActor
enum AssistantDebugScript {
    nonisolated(unsafe) static var didRun = false

    static func run(model: AppModel) async {
        guard !didRun, let script = ProcessInfo.processInfo.environment["AIRY_ASSISTANT_SCRIPT"] else { return }
        didRun = true
        let start = DebugSnapshot.start
        for raw in script.split(separator: ",") {
            guard let at = raw.lastIndex(of: "@"), let time = Double(raw[raw.index(after: at)...]) else { continue }
            let step = raw[..<at].split(separator: ":", maxSplits: 1).map(String.init)
            let wait = max(time - Date().timeIntervalSince(start), 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated { perform(step[0], step.count > 1 ? step[1] : nil, model: model) }
            }
        }
    }

    private static func perform(_ action: String, _ argument: String?, model: AppModel) {
        FileHandle.standardError.write(Data("[assistant] \(action) \(argument ?? "")\n".utf8))
        let session = model.assistant
        switch action {
        case "report": session.mode = .report; session.runReport(model: model)
        case "chat": session.mode = .chat
        case "informe": session.mode = .report
        case "agents": session.mode = .agents
        case "ask": session.mode = .chat; session.ask(argument ?? "", model: model)
        case "draft": session.mode = .chat; session.draft = argument ?? ""
        case "stop": session.stop()
        case "route":
            if let path = session.transcript.bubbles.last?.routes.first { model.showInMap(path: path) }
        case "pending": model.section = .map; model.pendingAssistantQuestion = argument; model.section = .assistant
        case "confirm", "second", "cancel":
            NotificationCenter.default.post(name: .airyAssistantDebug, object: nil,
                                            userInfo: ["action": action, "argument": argument ?? ""])
        default: break
        }
    }
}

extension Notification.Name {
    static let airyAssistantDebug = Notification.Name("AiryAssistantDebug")
}
#endif
