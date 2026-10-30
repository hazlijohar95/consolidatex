import AccCore
import AppKit
import SwiftUI

/// The last 7 days: how much of each subscription was used, and how long each sat at a limit.
struct ReportView: View {
    @ObservedObject var model: Model
    @State private var reports: [WeekReport] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.title2.weight(.semibold))
                Text("How much of each subscription you used, and how long each sat at its limit.")
                    .foregroundStyle(.secondary)
            }
            let covered = reports.map(\.coveredHours).max() ?? 0
            if covered == 0 {
                Text("Consolidatex records usage every 15 minutes while it runs. Check back in a day.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(reports, id: \.account.id) { report in row(report) }
                }
                if covered < 24 * 6 {
                    Text("Based on \(Int(covered.rounded())) hours of history so far.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 320, alignment: .topLeading)
        .onAppear { reports = model.weekReports() }
        // Picking "Last 7 Days…" again only brings an open window forward, so it reloads then too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reports = model.weekReports() }
    }

    private func row(_ report: WeekReport) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(report.account.label).font(.body.weight(.medium))
                Text([report.account.tool.spec.name, model.monitor.identities[report.account.id]?.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let used = report.weekUsed {
                ProgressView(value: min(used, 100), total: 100).tint(Theme.level(used)).frame(width: 140)
                Text("\(Int(used.rounded()))% of the week").monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("no weekly limit").foregroundStyle(.tertiary).gridCellColumns(2)
            }
            Text(report.cappedHours >= 0.5 ? "\(Int(report.cappedHours.rounded()))h at limit" : "never at limit")
                .monospacedDigit().foregroundStyle(report.cappedHours >= 1 ? Theme.bad : .secondary)
            Text(report.note.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "")
                .font(.callout).foregroundStyle(Theme.warn)
        }
    }
}
