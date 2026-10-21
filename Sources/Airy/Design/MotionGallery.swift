#if DEBUG
import SwiftUI
import DiskMapCore

/// Debug only (`AIRY_MOTION_GALLERY=1`): replaces the section content with every brand motion piece
/// to review and measure them without scanning the disk. Everything is in-memory text:
/// it doesn't call `CleanupFlow` or `AppModel`, and doesn't touch the disk.
/// `AIRY_GALLERY_AUTOPLAY=<s>` presses "Simulate Deletion" that many seconds after launch (for captures).
struct MotionGallery: View {
    private struct FakeRow: Identifiable { let id: Int; let name: String; let bytes: Int64 }

    private static let allRows = (0..<6).map {
        FakeRow(id: $0, name: ["Safari cache", "Old logs", "Xcode builds",
                               "Thumbnails", "Partial downloads", "iOS backups"][$0],
                bytes: Int64(($0 + 2) * 180_000_000))
    }

    @ViewState private var rows = MotionGallery.allRows
    @ViewState private var gustStart: Date?
    @ViewState private var tally = BatchMotion.Tally()
    @ViewState private var running = false
    @Environment(\.airyTransientMotion) private var transient

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 26) {
                section("Performance swirl") {
                    HStack(spacing: 22) {
                        swirl("Load 0", load: 0, state: .nominal)
                        swirl("Load 0.5", load: 0.5, state: .nominal)
                        swirl("Load 1", load: 1, state: .nominal)
                        swirl("Serious", load: 1, state: .serious)
                    }
                }
                section("Risk badges") {
                    HStack(spacing: 10) {
                        RiskBadge(risk: .safe)
                        RiskBadge(risk: .yourCall)
                        RiskBadge(risk: .doNotTouch)
                        RiskBadge(risk: .safe, compact: true)
                        RiskBadge(risk: .yourCall, reason: "Contains copies you might want")
                    }
                }
                section("Logo") {
                    HStack(alignment: .bottom, spacing: 22) {
                        ForEach([16, 26, 64, 128], id: \.self) { AiryLogo(size: CGFloat($0)) }
                    }
                }
            }
            section("Deletion") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PrimaryButton(running ? "Deleting…" : (rows.isEmpty ? "Restore Rows" : "Simulate Deletion"),
                                      systemImage: "wind", style: .secondary) { play() }
                            .fixedSize()
                            .disabled(running)
                        BatchFreedPill(tally: tally)
                    }
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                fakeRow(row)
                                    .gustSway(index: index, start: gustStart)
                                    .transition(.leafAway)
                            }
                        }
                        .frame(width: 420, alignment: .topLeading)
                        if let gustStart { GustSweep(start: gustStart) }
                    }
                    .frame(width: 420, height: 6 * 44 + 5 * 6, alignment: .topLeading)
                }
            }
        }
        .padding(Theme.contentPadding)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            guard let after = DebugSnapshot.environment["AIRY_GALLERY_AUTOPLAY"].flatMap(Double.init) else { return }
            let wait = DebugSnapshot.start.addingTimeInterval(after).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            play()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.Airy.textSecondary)
            content()
        }
    }

    private func swirl(_ title: String, load: Double, state: ProcessInfo.ThermalState) -> some View {
        VStack(spacing: 6) {
            WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: load), tint: Theme.Airy.swirlTint(state))
                .frame(width: 84, height: 84)
            Text(title).font(.caption).foregroundStyle(Theme.Airy.textSecondary)
        }
    }

    private func fakeRow(_ row: FakeRow) -> some View {
        HStack {
            Text(row.name)
            Spacer()
            Text(Format.bytes(row.bytes)).monospacedDigit().foregroundStyle(Theme.Airy.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Gust and rows leaving one by one, every 0.25 s; the pill goes up with each one.
    private func play() {
        guard !running else { return }
        if rows.isEmpty {
            rows = Self.allRows
            tally = BatchMotion.Tally()
            return
        }
        running = true
        let total = rows.count
        let start = Date()
        gustStart = start
        Task {
            for _ in 0..<total {
                try? await Task.sleep(for: .seconds(0.25))
                guard let row = rows.first else { break }
                withAnimation(.easeOut(duration: 0.6)) {
                    rows.removeFirst()
                    tally.add(.freed(row.bytes))
                }
            }
            try? await Task.sleep(for: .seconds(max(WindMotion.gustBandDuration - Date().timeIntervalSince(start), 0)))
            gustStart = nil
            running = false
        }
    }
}
#endif
