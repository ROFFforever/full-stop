import SwiftUI
import Charts

// Which hour total a ring shows: all practice hours toward 50, or night hours toward 10.
enum HourKind: String, Identifiable {
    case total, night
    var id: String { rawValue }
    var title: String { self == .total ? "Practice hours" : "Night hours" }
    var color: Color { self == .total ? .blue : .indigo }
    var goal: Double { self == .total ? DriveLog.goalHours : DriveLog.goalNightHours }
    var caption: String { self == .total ? "of \(Int(goal)) h" : "of \(Int(goal)) night h" }
    func hours(_ log: DriveLog) -> Double { self == .total ? log.totalHours : log.nightHours }
    func hours(_ drive: DriveSummary) -> Double { (self == .total ? drive.duration : drive.nightSeconds) / 3600 }
}

// A progress ring: a faint full circle with the filled part on top, starting at 12 o'clock.
struct ProgressRing: View {
    let progress: Double // 0...1; more is drawn as a full ring.
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.28), lineWidth: lineWidth) // The unfilled track, visible on black or white.
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2) // Keep the stroke inside the frame.
    }
}

// Full screen for one ring (opened by tapping it on Home, which zooms into this). The ring fills up from empty,
// like the Fitness app, then shows how far there is to go and this week's hours by day.
struct HourDetailView: View {
    let kind: HourKind
    @ObservedObject var log: DriveLog
    @State private var shown = 0.0 // Hours drawn so far; animates from 0 up to the real total.
    @Environment(\.dismiss) private var dismiss

    private var hours: Double { kind.hours(log) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ZStack {
                    ProgressRing(progress: shown / kind.goal, color: kind.color, lineWidth: 34)
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", shown))
                            .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(value: shown)) // Digits roll up with the ring.
                        Text(kind.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 270, height: 270)
                .frame(maxWidth: .infinity)
                .padding(.top, 52) // Room for the back button.

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.headline)
                    Text(String(format: "%.1f/%.0f h", hours, kind.goal))
                        .font(.system(.largeTitle, design: .rounded).bold()).foregroundStyle(kind.color)
                    Text(hours >= kind.goal ? "Goal reached" : String(format: "%.1f h to go", kind.goal - hours))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last 7 days").font(.headline)
                    Chart(week, id: \.day) { day in
                        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Hours", day.hours))
                            .foregroundStyle(kind.color)
                            .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
                    }
                    .chartYAxisLabel("hours")
                    .frame(height: 160)
                }

                if kind == .night {
                    Text("Night = sunset to sunrise where the drive started.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        // No navigation bar, and our own back button instead. With a bar, the zoom from Home (which has no bar) drew
        // this page without one, then added the bar when the zoom ended, which shoved everything down a second later.
        // Swiping back from the left edge still works.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back")
            .padding(.leading)
        }
        .onAppear {
            shown = 0
            withAnimation(.easeOut(duration: 1.2).delay(0.35)) { shown = hours } // Starts once the zoom has settled.
        }
    }

    // Hours on each of the last 7 days (today last), counted on the day each drive started.
    private var week: [(day: Date, hours: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let total = log.drives.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + kind.hours($1) }
            return (day, total)
        }
    }
}
