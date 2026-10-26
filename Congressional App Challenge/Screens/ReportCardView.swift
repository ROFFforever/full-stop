import SwiftUI

// One drive's report card: shown right after End Drive, and from History.
struct ReportCardView: View {
    let drive: DriveSummary
    @State private var reviewing: ReviewMoment? // Drive review open at this moment.

    var body: some View {
        let canReview = DriveRecording.hasVideo(drive)
        let moments = ReviewMoment.all(in: drive)
        List {
            let headline = Self.headline(drive)
            Section {
                HStack(spacing: 14) {
                    Image(systemName: headline.icon).font(.largeTitle).foregroundStyle(headline.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline.title).font(.title2.bold())
                        Text(headline.detail).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                row("Date", drive.start.formatted(date: .abbreviated, time: .shortened))
                row("Time driven", Self.duration(drive.duration))
                row("Night", Self.duration(drive.nightSeconds))
                row("Distance", String(format: "%.1f mi", drive.miles))
                row("Supervising driver", drive.supervisor)
            }

            Section("Stop signs") {
                if drive.stopSigns.isEmpty {
                    Text("No stop signs this drive").foregroundStyle(.secondary)
                } else {
                    Text("\(drive.fullStops) of \(drive.stopSigns.count) full stops").font(.headline)
                    if drive.almostStops > 0 || drive.rollingStops > 0 {
                        Text("\(drive.almostStops) almost · \(drive.rollingStops) rolling").foregroundStyle(.secondary)
                    }
                    ForEach(moments.filter { $0.kind == .stopSign }) { moment in
                        momentRow(moment, canReview: canReview)
                    }
                }
            }

            if let passed = drive.lookChecksPassed, let missed = drive.lookChecksMissed, passed + missed > 0 {
                Section("Look both ways") {
                    Text("Looked both ways at \(passed) of \(passed + missed) stops").font(.headline)
                    if missed > 0 {
                        Label("\(missed) missed", systemImage: "eye.slash").foregroundStyle(.orange)
                    }
                }
            }

            Section("Braking") {
                if drive.hardBrakes.isEmpty {
                    Label("No hard brakes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ForEach(moments.filter { $0.kind == .brake }) { moment in
                        momentRow(moment, canReview: canReview)
                    }
                }
                if !drive.hardAccels.isEmpty {
                    Text("Hard accelerations: \(drive.hardAccels.count)").foregroundStyle(.secondary)
                }
            }

            Section {
                Text(canReview ? "Times are minutes:seconds into the drive. Tap one to watch that moment."
                               : "Times are minutes:seconds into the drive.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Report card")
        .toolbar(.visible, for: .navigationBar) // Home hides its bar; show this page's from the first frame (no jump).
        .fullScreenCover(item: $reviewing) { DriveReviewView(drive: drive, startMoment: $0) }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["OPEN_REVIEW"] != nil { reviewing = moments.first } }
        #endif
    }

    // A stop sign or hard brake. With a saved video, tapping it opens that moment of the drive.
    @ViewBuilder private func momentRow(_ moment: ReviewMoment, canReview: Bool) -> some View {
        let row = HStack {
            Image(systemName: moment.icon).foregroundStyle(moment.color)
            Text(moment.title).foregroundStyle(.primary)
            Spacer()
            Text(Self.clock(moment.driveSeconds)).foregroundStyle(.secondary).monospacedDigit()
            if canReview { Image(systemName: "play.circle").foregroundStyle(.tint) }
        }
        if canReview { Button { reviewing = moment } label: { row } } else { row }
    }

    // The one thing to take away from this drive, most important first.
    static func headline(_ drive: DriveSummary) -> (title: String, detail: String, icon: String, color: Color) {
        let missedLooks = drive.lookChecksMissed ?? 0
        var parts: [String] = []
        if !drive.stopSigns.isEmpty { parts.append("\(drive.fullStops) of \(drive.stopSigns.count) full stops") }
        if !drive.hardBrakes.isEmpty { parts.append(drive.hardBrakes.count == 1 ? "1 hard brake" : "\(drive.hardBrakes.count) hard brakes") }
        if missedLooks > 0 { parts.append("\(missedLooks) missed look\(missedLooks == 1 ? "" : "s")") }
        let detail = parts.isEmpty ? duration(drive.duration) + " logged" : parts.joined(separator: " · ")
        if drive.rollingStops > 0 { return ("Focus on full stops", detail, "exclamationmark.octagon.fill", .red) }
        if missedLooks > 0 { return ("Look both ways at stops", detail, "eye.trianglebadge.exclamationmark.fill", .orange) }
        if drive.almostStops > 0 { return ("Hold each stop a little longer", detail, "exclamationmark.circle.fill", .yellow) }
        if !drive.hardBrakes.isEmpty { return ("Brake earlier and gentler", detail, "exclamationmark.triangle.fill", .orange) }
        if drive.stopSigns.isEmpty { return ("Practice logged", detail, "checkmark.circle.fill", .green) }
        return ("Great drive", detail, "star.circle.fill", .green)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
    static func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    static func label(_ sign: DriveSummary.StopSign) -> String {
        let mph = sign.minSpeed.map { String(format: " (slowest %.0f mph)", $0 * 2.237) } ?? ""
        switch sign.outcome {
        case "fullStop": return "Full stop"
        case "almostStopped": return "Almost a full stop" + mph
        case "rolling": return "Rolling stop" + mph
        default: return "Couldn't tell (no GPS)"
        }
    }
    static func icon(_ outcome: String) -> String {
        switch outcome {
        case "fullStop": return "checkmark.circle.fill"
        case "almostStopped": return "exclamationmark.circle.fill"
        case "rolling": return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }
    static func color(_ outcome: String) -> Color {
        switch outcome { case "fullStop": return .green; case "almostStopped": return .yellow; case "rolling": return .red; default: return .secondary }
    }
}
