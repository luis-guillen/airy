import SwiftUI
import DiskMapCore

/// Memory: used / file cache / free, pressure and swap. No "free up RAM" button.
struct MemoryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let memory = model.performance.snapshot?.memory
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Memory").font(.headline)
                if let memory, memory.total > 0 {
                    MemoryBar(memory: memory).frame(height: 14)
                    HStack(spacing: 14) {
                        legend(String(localized: "Used"), Format.bytes(memory.used), Theme.Airy.accent)
                        HStack(spacing: 4) {
                            legend(String(localized: "File cache"), Format.bytes(memory.fileCache), Theme.purgeableColor)
                            HelpDot(text: "Files macOS keeps in memory to open them faster; it releases that memory as soon as another app needs it.")
                        }
                        legend(String(localized: "Free"), Format.bytes(memory.free), .secondary.opacity(0.35))
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("Memory Pressure").font(.callout)
                    HelpDot(text: "Memory pressure tells you whether macOS is struggling to find free memory. Green means plenty; amber means it’s starting to compress and use the disk; red means apps will be slow.")
                    Spacer()
                    pressurePill(memory?.pressure)
                }
                HStack(spacing: 6) {
                    Text(memory.map { String(localized: "Swap: \(Format.bytes($0.swapUsed)) of \(Format.bytes($0.swapTotal))") } ?? String(localized: "Swap: —"))
                        .font(.callout)
                        .monospacedDigit()
                    HelpDot(text: "Swap is memory macOS temporarily stores on the disk when everything doesn’t fit in RAM. It grows when you open many things at once and doesn’t go down by itself until you quit apps or restart; a little is normal, a lot makes everything slower.")
                }
                Text("Airy has no “free up RAM” button: macOS already manages memory and those buttons don’t help. What really helps is quitting what uses the most.")
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
        case .normal: (String(localized: "Normal"), .safe)
        case .warning: (String(localized: "High"), .yourCall)
        case .critical: (String(localized: "Critical"), .doNotTouch)
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

/// Temperature without degrees (only macOS's state) and whether it has slowed down.
struct ThermalCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let thermal = model.performance.snapshot?.thermal
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Temperature: \(thermal?.level.label ?? "—")").font(.headline)
                    HelpDot(text: "Airy doesn’t show degrees: reading them requires private Apple interfaces that can break.")
                }
                if let thermal {
                    Text(thermal.throttling ? "macOS has slowed it down to cool it." : "No slowdown.")
                        .font(.callout)
                        .foregroundStyle(thermal.throttling ? Theme.Airy.riskInk(.yourCall) : .secondary)
                }
            }
        }
    }
}

/// Processor: total and P/E cores; what uses the most CPU and energy (relative bars, no watts).
struct CPUCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.performance
        let cpu = session.snapshot?.cpu
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Processor: \(cpu.map { String(localized: "\(Int($0.total.rounded()))%") } ?? "—")").font(.headline)
                if let cpu, cpu.performance != nil || cpu.efficiency != nil {
                    Text("Performance cores \(percent(cpu.performance)) · efficiency cores \(percent(cpu.efficiency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bars(String(localized: "Most Processor"), session.board.topByCPU.map { ($0.id, $0.name, $0.cpuPercent ?? 0) })
                bars(String(localized: "Most Energy"), session.board.topByEnergy.map { ($0.id, $0.name, $0.energy ?? 0) })
            }
        }
    }

    private func percent(_ value: Double?) -> String { value.map { String(localized: "\(Int($0.rounded()))%") } ?? "—" }

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
