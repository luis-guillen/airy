import SwiftUI
import DiskMapCore

/// Battery, disk, network, uptime and zombie processes; "—" for what isn't known.
struct ExtrasCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.performance.snapshot
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("More Data").font(.headline)
                line("battery.75percent", battery(snapshot))
                line("internaldrive", String(localized: "Disk: read \(rate(snapshot?.disk?.readPerSecond))/s · write \(rate(snapshot?.disk?.writePerSecond))/s"))
                line("network", String(localized: "Network: down \(rate(snapshot?.network?.readPerSecond))/s · up \(rate(snapshot?.network?.writePerSecond))/s"))
                line("clock", String(localized: "Up for \(snapshot?.uptime.map(Self.duration) ?? "—")"))
                HStack(spacing: 6) {
                    line("exclamationmark.bubble", zombies(snapshot))
                    HelpDot(text: "Processes that have finished but haven’t been reaped by their program; they use no resources, but many of them point to a buggy program.")
                }
            }
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).monospacedDigit()
    }

    private func battery(_ snapshot: PerformanceSnapshot?) -> String {
        guard let snapshot else { return String(localized: "Battery: —") }
        guard let b = snapshot.battery else { return String(localized: "No battery") }
        let cycles = b.cycleCount.map(String.init) ?? "—"
        let health = b.healthPercent.map(String.init) ?? "—"
        return String(localized: "\(b.percent)% · \(cycles) cycles · health \(health)%")
    }

    private func rate(_ value: Double?) -> String { value.map { Format.bytes(Int64($0)) } ?? "—" }

    private func zombies(_ snapshot: PerformanceSnapshot?) -> String {
        guard let zombies = snapshot?.zombies else { return String(localized: "Zombie processes: —") }
        let parents = Array(Set(zombies.compactMap(\.parentName))).sorted().prefix(3)
        return parents.isEmpty ? String(localized: "Zombie processes: \(zombies.count)")
            : String(localized: "Zombie processes: \(zombies.count) (from \(parents.joined(separator: ", ")))")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(mins) min" }
        return "\(mins) min"
    }
}
