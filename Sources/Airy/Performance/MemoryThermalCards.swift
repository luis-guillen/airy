import SwiftUI
import DiskMapCore

/// Memoria: usada / caché de archivos / libre, presión y swap. Sin botón de «liberar RAM».
struct MemoryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let memory = model.performance.snapshot?.memory
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Memoria").font(.headline)
                if let memory, memory.total > 0 {
                    MemoryBar(memory: memory).frame(height: 14)
                    HStack(spacing: 14) {
                        legend("Usada", Format.bytes(memory.used), Theme.Airy.accent)
                        HStack(spacing: 4) {
                            legend("Caché de archivos", Format.bytes(memory.fileCache), Theme.purgeableColor)
                            HelpDot(text: "Archivos que macOS guarda en memoria para abrirlos antes; la suelta en cuanto otra app la necesita.")
                        }
                        legend("Libre", Format.bytes(memory.free), .secondary.opacity(0.35))
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("Presión de memoria").font(.callout)
                    HelpDot(text: "La presión de memoria dice si a macOS le cuesta encontrar memoria libre. En verde va sobrado; en ámbar empieza a comprimir y a usar el disco; en rojo, las apps irán lentas.")
                    Spacer()
                    pressurePill(memory?.pressure)
                }
                HStack(spacing: 6) {
                    Text(memory.map { "Swap: \(Format.bytes($0.swapUsed)) de \(Format.bytes($0.swapTotal))" } ?? "Swap: —")
                        .font(.callout)
                        .monospacedDigit()
                    HelpDot(text: "La swap es memoria que macOS guarda temporalmente en el disco cuando no cabe todo en la RAM. Crece cuando abres muchas cosas a la vez y no baja sola hasta que cierras apps o reinicias; un poco es normal, mucha hace que todo vaya más lento.")
                }
                Text("Airy no tiene botón de «liberar RAM»: macOS ya gestiona la memoria y esos botones no ayudan. Lo que alivia de verdad es cerrar lo que más consume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
        }
    }

    private func legend(_ title: String, _ value: String, _ color: some ShapeStyle) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) \(value)").font(.caption).monospacedDigit()
        }
    }

    @ViewBuilder private func pressurePill(_ pressure: MemoryPressure?) -> some View {
        let (text, risk): (String, Risk?) = switch pressure {
        case .normal: ("Normal", .safe)
        case .warning: ("Alta", .yourCall)
        case .critical: ("Crítica", .doNotTouch)
        case nil: ("—", nil)
        }
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(risk.map { Theme.Airy.riskInk($0) } ?? .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background((risk.map { Theme.Airy.riskFill($0) } ?? .secondary).opacity(0.16), in: Capsule())
    }
}

private struct MemoryBar: View {
    let memory: MemoryStats
    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(memory.total))
            HStack(spacing: 1.5) {
                Capsule().fill(Theme.Airy.accent).frame(width: geo.size.width * Double(memory.used) / total)
                Capsule().fill(Theme.purgeableColor).frame(width: geo.size.width * Double(memory.fileCache) / total)
                Capsule().fill(.secondary.opacity(0.25))
            }
        }
        .animation(.easeOut(duration: 0.4), value: memory.used)
    }
}

/// Temperatura sin grados (solo el estado de macOS) y si ha bajado la velocidad.
struct ThermalCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let thermal = model.performance.snapshot?.thermal
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Temperatura: \(thermal?.level.label ?? "—")").font(.headline)
                    HelpDot(text: "Airy no muestra grados: leerlos exige interfaces privadas de Apple que pueden romperse.")
                }
                if let thermal {
                    Text(thermal.throttling ? "macOS ha bajado la velocidad para enfriarlo." : "Sin reducción de velocidad.")
                        .font(.callout)
                        .foregroundStyle(thermal.throttling ? Theme.Airy.riskInk(.yourCall) : .secondary)
                }
            }
        }
    }
}

/// Procesador: total y núcleos P/E; lo que más CPU y energía usa (barras relativas, sin vatios).
struct CPUCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.performance
        let cpu = session.snapshot?.cpu
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Procesador: \(cpu.map { "\(Int($0.total.rounded())) %" } ?? "—")").font(.headline)
                if let cpu, cpu.performance != nil || cpu.efficiency != nil {
                    Text("Núcleos de rendimiento \(percent(cpu.performance)) · de eficiencia \(percent(cpu.efficiency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bars("Más procesador", session.board.topByCPU.map { ($0.id, $0.name, $0.cpuPercent ?? 0) })
                bars("Más energía", session.board.topByEnergy.map { ($0.id, $0.name, $0.energy ?? 0) })
            }
        }
    }

    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) %" } ?? "—" }

    @ViewBuilder private func bars(_ title: String, _ items: [(String, String, Double)]) -> some View {
        if !items.isEmpty {
            let top = max(items.map(\.2).max() ?? 1, 0.0001)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items, id: \.0) { item in
                    HStack(spacing: 8) {
                        Text(item.1).font(.caption).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Theme.brand).frame(width: max(3, geo.size.width * item.2 / top))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }
}
