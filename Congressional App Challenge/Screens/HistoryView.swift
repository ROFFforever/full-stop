import SwiftUI

// The practice hour log: progress toward WA's 50 hours (10 at night), every drive, and export for a parent.
struct HistoryView: View {
    @ObservedObject var log: DriveLog

    var body: some View {
        List {
            Section {
                HourProgress(log: log)
                ShareLink(item: log.exportCSV()) { Label("Export hour log", systemImage: "square.and.arrow.up") }
                    .disabled(log.drives.isEmpty)
            } footer: {
                Text("Night = sunset to sunrise where the drive started. This log helps a parent review hours; it doesn't replace the official parent certification.")
            }

            Section("Drives") {
                if log.drives.isEmpty { Text("No drives yet").foregroundStyle(.secondary) }
                ForEach(log.drives) { drive in
                    NavigationLink { ReportCardView(drive: drive) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(summary(drive)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in offsets.map { log.drives[$0] }.forEach(log.delete) }
            }
        }
        .navigationTitle("History")
        .toolbar(.visible, for: .navigationBar) // Home hides its bar; show this page's from the first frame (no jump).
    }

    private func summary(_ drive: DriveSummary) -> String {
        var parts = [ReportCardView.duration(drive.duration), String(format: "%.1f mi", drive.miles)]
        if drive.nightSeconds >= 60 { parts.append("\(ReportCardView.duration(drive.nightSeconds)) night") }
        if !drive.stopSigns.isEmpty { parts.append("\(drive.fullStops)/\(drive.stopSigns.count) full stops") }
        parts.append(drive.supervisor)
        return parts.joined(separator: " · ")
    }
}

// Two progress bars: total hours and night hours. Used on Home and in History.
struct HourProgress: View {
    @ObservedObject var log: DriveLog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar("Practice hours", log.totalHours, DriveLog.goalHours)
            bar("Night hours", log.nightHours, DriveLog.goalNightHours)
        }
    }

    private func bar(_ title: String, _ hours: Double, _ goal: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f of %.0f h", hours, goal)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(hours, goal), total: goal)
        }
    }
}
