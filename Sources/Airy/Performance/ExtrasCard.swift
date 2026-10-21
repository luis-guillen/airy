import SwiftUI
import DiskMapCore

/// Batería, disco, red, tiempo encendido y procesos zombi; «—» para lo que no se sabe.
struct ExtrasCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.performance.snapshot
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Más datos").font(.headline)
                line("battery.75percent", battery(snapshot))
                line("internaldrive", "Disco: lee \(rate(snapshot?.disk?.readPerSecond))/s · escribe \(rate(snapshot?.disk?.writePerSecond))/s")
                line("network", "Red: baja \(rate(snapshot?.network?.readPerSecond))/s · sube \(rate(snapshot?.network?.writePerSecond))/s")
                line("clock", "Encendido desde hace \(snapshot?.uptime.map(Self.duration) ?? "—")")
                HStack(spacing: 6) {
                    line("exclamationmark.bubble", zombies(snapshot))
                    HelpDot(text: "Procesos ya terminados que su programa no ha recogido; no gastan recursos, pero muchos indican un programa con fallos.")
                }
            }
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).monospacedDigit()
    }

    private func battery(_ snapshot: PerformanceSnapshot?) -> String {
        guard let snapshot else { return "Batería: —" }
        guard let b = snapshot.battery else { return "Sin batería" }
        let cycles = b.cycleCount.map(String.init) ?? "—"
        let health = b.healthPercent.map(String.init) ?? "—"
        return "\(b.percent) % · \(cycles) ciclos · salud \(health) %"
    }

    private func rate(_ value: Double?) -> String { value.map { Format.bytes(Int64($0)) } ?? "—" }

    private func zombies(_ snapshot: PerformanceSnapshot?) -> String {
        guard let zombies = snapshot?.zombies else { return "Procesos zombi: —" }
        let parents = Array(Set(zombies.compactMap(\.parentName))).sorted().prefix(3)
        return "Procesos zombi: \(zombies.count)" + (parents.isEmpty ? "" : " (de \(parents.joined(separator: ", ")))")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(mins) min" }
        return "\(mins) min"
    }
}
