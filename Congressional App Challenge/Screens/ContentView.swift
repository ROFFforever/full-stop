import SwiftUI

// The app's name and tagline, shown on Home.
enum AppInfo {
    static let name = "Full Stop"
    static let tagline = "Your driving coach"
}

// Home screen: app name, hour-log progress, the 3 most recent drives, who's supervising, and a big Start drive button.
// History and Settings sit in the top corner (Debug tools live in Settings).
struct ContentView: View {
    @StateObject private var detector = DetectorDashboard() // Shared by Driving and Debug.
    @StateObject private var session = DriveSession() // Camera + sensors + coach + voice for a real drive.
    @StateObject private var log = DriveLog() // Saved drives: hour log and report cards.
    @AppStorage("supervisor") private var supervisor = "" // Remembered between drives; asked while parked.
    @State private var driving = false // Full-screen dark driving mode.
    @State private var showingDebug = false // Debug tools (normally opened from Settings; OPEN_DEBUG opens them at launch).
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var debugHours: HourKind? // OPEN_HOURS launch option only (normally the rings open their own screen).
    @Namespace private var ringZoom // Links each small ring to its full screen for the zoom transition.
    @State private var editingSupervisor = false // Name prompt.
    @State private var nameDraft = ""
    @State private var startAfterName = false // The prompt came from Start drive: start once a name is entered.
    @State private var report: DriveSummary? // Report card shown after a drive ends.
    @State private var shownDrives = RecentDrives.count // Recent drive cards on Home; fewer on short screens.
    @State private var contentHeight: CGFloat = 0 // Height of the portrait content (more than the screen = it overflows).
    @State private var leftover: CGFloat = 0 // Empty space above Supervisor.
    @State private var cardHeight: CGFloat = 0 // One recent drive card.

    private var supervisorName: String { supervisor.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    // Landscape (the phone sits sideways in the mount): progress and drives scroll on the left;
                    // Start drive stays put on the right so it's always on screen.
                    HStack(alignment: .top, spacing: 24) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) { header; progress(drives: RecentDrives.count) }.padding(.vertical)
                        }
                        VStack(spacing: 16) { Spacer(minLength: 0); startArea }.padding(.vertical)
                    }
                    .padding(.horizontal)
                } else {
                    // Portrait: show as many recent drives (up to 3) as fit with everything else on screen, so Start drive
                    // and its hint never need a scroll. Measured from the real layout (see fitDrives). Only if even
                    // 1 card doesn't fit (very large text) does the screen scroll.
                    ScrollView {
                        portrait(drives: shownDrives)
                            .frame(minHeight: geometry.size.height)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .onChange(of: contentHeight) { fitDrives(screen: geometry.size.height) }
                    .onChange(of: leftover) { fitDrives(screen: geometry.size.height) }
                    .onChange(of: cardHeight) { fitDrives(screen: geometry.size.height) }
                    .onChange(of: geometry.size.height) { fitDrives(screen: geometry.size.height) }
                }
            }
            .toolbar(.hidden, for: .navigationBar) // The title row has its own History and Settings buttons.
            .navigationDestination(isPresented: $showingSettings) { SettingsView(detector: detector) }
            .navigationDestination(isPresented: $showingHistory) { HistoryView(log: log) }
            .navigationDestination(item: $debugHours) {
                HourDetailView(kind: $0, log: log).navigationTransition(.zoom(sourceID: $0, in: ringZoom)) // Same as a tap.
            }
        }
        .alert("Supervising driver", isPresented: $editingSupervisor) {
            TextField("Name", text: $nameDraft).textContentType(.name)
            Button("Cancel", role: .cancel) { startAfterName = false }
            Button(startAfterName ? "Start drive" : "Save") {
                supervisor = nameDraft.trimmingCharacters(in: .whitespaces)
                if startAfterName && !supervisorName.isEmpty { driving = true }
                startAfterName = false
            }
        } message: {
            Text("A licensed driver, 21 or older, with at least 3 years of experience.")
        }
        .fullScreenCover(isPresented: $driving, onDismiss: { report = session.lastSummary }) {
            DrivingView(detector: detector, session: session, motion: session.motion, recorder: session.recorder,
                        supervisor: supervisorName, log: log) { driving = false }
        }
        .sheet(item: $report) { drive in
            NavigationStack {
                ReportCardView(drive: drive)
                    .toolbar { Button("Done") { report = nil } }
            }
        }
        .sheet(isPresented: $showingDebug) {
            DebugView(detector: detector)
        }
        .onAppear {
            #if DEBUG
            // Lets automated screenshots open a screen without tapping.
            if ProcessInfo.processInfo.environment["OPEN_DEBUG"] != nil { showingDebug = true }
            if ProcessInfo.processInfo.environment["OPEN_SETTINGS"] != nil { showingSettings = true }
            if let kind = ProcessInfo.processInfo.environment["OPEN_HOURS"] { debugHours = HourKind(rawValue: kind) } // total or night
            if ProcessInfo.processInfo.environment["LANDSCAPE"] != nil, // Rotates the simulator (simctl can't).
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            // Shows a made-up report card (not saved) so the screen can be checked in the simulator.
            if ProcessInfo.processInfo.environment["SAMPLE_REPORT"] != nil {
                let start = Date().addingTimeInterval(-25 * 60)
                report = DriveSummary(start: start, end: Date(), distanceMeters: 9_800, nightSeconds: 480, supervisor: "Mom",
                                      stopSigns: [.init(secondsIntoDrive: 140, outcome: "fullStop", minSpeed: 0, peakBrakeG: -0.2),
                                                  .init(secondsIntoDrive: 515, outcome: "almostStopped", minSpeed: 0.9, peakBrakeG: -0.11),
                                                  .init(secondsIntoDrive: 700, outcome: "rolling", minSpeed: 2.1, peakBrakeG: -0.15),
                                                  .init(secondsIntoDrive: 980, outcome: "fullStop", minSpeed: 0.1, peakBrakeG: -0.22)],
                                      hardBrakes: [.init(secondsIntoDrive: 361, g: -0.55)], hardAccels: [],
                                      lookChecksPassed: 3, lookChecksMissed: 1)
                if let folder = ProcessInfo.processInfo.environment["SAMPLE_REVIEW_FOLDER"] { report = Self.sampleDrive(folder: folder) }
            }
            #endif
        }
    }

    #if DEBUG
    // A report card built from a recording folder on the Mac (simulator only), so drive review can be checked:
    // its stop signs come from the coach's result rows, its start is 12 s before recording (like a head-turn setup).
    static func sampleDrive(folder: String) -> DriveSummary? {
        let url = URL(fileURLWithPath: folder)
        guard let metaData = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let startT = meta["start_t"] as? Double, let startUnix = meta["start_unix"] as? Double, let endT = meta["end_t"] as? Double,
              let csv = try? String(contentsOf: url.appendingPathComponent("sensors.csv"), encoding: .utf8) else { return nil }
        let setup = 12.0
        var signs: [DriveSummary.StopSign] = []
        for line in csv.split(separator: "\n") where line.contains(",coach,") && line.contains("result: ") && !line.contains("passedThrough") {
            guard let t = Double(line.prefix { $0 != "," }) else { continue }
            let outcome = line.components(separatedBy: "result: ").last?.components(separatedBy: ",").first ?? "unknown"
            signs.append(.init(secondsIntoDrive: t - startT + setup, outcome: outcome, minSpeed: nil, peakBrakeG: 0))
        }
        let start = Date(timeIntervalSince1970: startUnix - setup)
        return DriveSummary(start: start, end: start.addingTimeInterval(endT - startT + setup), distanceMeters: 3_000, nightSeconds: 0,
                            supervisor: "Test", stopSigns: signs, hardBrakes: [], hardAccels: [], recordingFolder: folder)
    }
    #endif

    // App name, with History and Settings on the same row.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name).font(.largeTitle.bold())
                Text(AppInfo.tagline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 20) {
                Button { showingHistory = true } label: { Image(systemName: "clock") }
                    .accessibilityLabel("History")
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            .font(.title2)
        }
    }

    // The whole portrait screen with up to `drives` recent drives; the spacer soaks up any leftover height.
    private func portrait(drives: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            progress(drives: drives)
            Spacer(minLength: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { leftover = $0 }
            startArea
        }
        .padding()
    }

    // Hour rings (tap one for its full screen) and up to `drives` recent drives.
    private func progress(drives: Int) -> some View {
        VStack(spacing: 16) {
            HourRings(log: log, zoom: ringZoom)
            RecentDrives(drives: log.drives, limit: drives, onCardHeight: { cardHeight = $0 }) { showingHistory = true }
        }
    }

    // Supervisor, Start drive, and the mounting hint.
    private var startArea: some View {
        VStack(spacing: 16) {
            supervisorRow
            VStack(spacing: 8) {
                Button(action: startTapped) {
                    Label("Start drive", systemImage: "steeringwheel")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 18))
                Text("Mount your phone first.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // "Supervisor: Mom ✎". Tap to change the name.
    private var supervisorRow: some View {
        Button {
            nameDraft = supervisor
            editingSupervisor = true
        } label: {
            HStack {
                Text("Supervisor").foregroundStyle(.secondary)
                Spacer()
                Text(supervisorName.isEmpty ? "Add name" : supervisorName)
                    .foregroundStyle(supervisorName.isEmpty ? Color.accentColor : .primary)
                Image(systemName: "pencil").foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    // Picks how many recent drive cards fit on the portrait screen. Everything except the cards and the empty space
    // is a fixed height, so: fixed = content - empty space - cards; then take the most cards (1 to 3) that fit.
    // It gives the same answer however many cards are showing, so it settles instead of flip-flopping.
    private func fitDrives(screen: CGFloat) {
        let available = min(RecentDrives.count, log.drives.count)
        guard available > 0, cardHeight > 0, contentHeight > 0 else { return }
        let step = cardHeight + 10 // A card plus RecentDrives' spacing.
        let fixed = contentHeight - leftover - CGFloat(shownDrives) * step
        let fit = Int(((screen - fixed) / step).rounded(.down))
        let best = max(1, min(available, fit))
        if best != shownDrives { shownDrives = best }
    }

    // No name yet: ask for it first, then start.
    private func startTapped() {
        if supervisorName.isEmpty {
            nameDraft = ""
            startAfterName = true
            editingSupervisor = true
        } else {
            driving = true
        }
    }
}

// Two rings: total practice hours toward 50 and night hours toward 10. Tapping one zooms it into its full screen.
struct HourRings: View {
    @ObservedObject var log: DriveLog
    let zoom: Namespace.ID // Links each small ring to its full-screen version for the zoom transition.

    var body: some View {
        HStack {
            Spacer()
            ring(.total)
            Spacer()
            ring(.night)
            Spacer()
        }
        .padding(.vertical, 4) // No card behind the rings: they sit straight on the page background.
    }

    private func ring(_ kind: HourKind) -> some View {
        NavigationLink {
            HourDetailView(kind: kind, log: log)
                .navigationTransition(.zoom(sourceID: kind, in: zoom))
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    ProgressRing(progress: kind.hours(log) / kind.goal, color: kind.color, lineWidth: 13)
                    Text(String(format: "%.1f", kind.hours(log))).font(.title2.bold()).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, 12) // Shrinks instead of "14…" at big text sizes.
                }
                .frame(width: 124, height: 124) // About 35% bigger than the first version (92).
                .matchedTransitionSource(id: kind, in: zoom)
                Text(kind.caption).font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title): \(String(format: "%.1f", kind.hours(log))) \(kind.caption)")
    }
}

// The most recent drives (3, or fewer on short screens) as cards; tap one for its report card. "See all" opens History when there are more.
// Before the first drive, says what will show here.
struct RecentDrives: View {
    let drives: [DriveSummary]
    var limit = count // Home shows fewer on short screens.
    var onCardHeight: (CGFloat) -> Void = { _ in } // Reports a card's height so Home can tell whether another fits.
    let seeAll: () -> Void
    static let count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent drives").font(.headline)
                Spacer()
                if drives.count > limit { Button("See all", action: seeAll) }
            }
            if drives.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No drives yet").font(.headline)
                    Text("Your first drive's report card will show up here.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            ForEach(drives.prefix(limit)) { drive in
                NavigationLink { ReportCardView(drive: drive) } label: { card(drive) }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onCardHeight($0) }
            }
        }
    }

    private func card(_ drive: DriveSummary) -> some View {
        let headline = ReportCardView.headline(drive)
        return HStack(spacing: 12) {
            Image(systemName: headline.icon).font(.title2).foregroundStyle(headline.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.start.formatted(.dateTime.month().day()) + " · " + ReportCardView.duration(drive.duration))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(drive.stopSigns.isEmpty ? headline.title : "\(drive.fullStops) of \(drive.stopSigns.count) full stops")
                    .font(.headline)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
