import SwiftUI

// Dark, minimal screen shown while driving. The drive (camera, sensors, coach, voice) starts when it appears.
// Nothing here needs a tap while moving: the coach talks. The text is for the supervisor and for testing.
struct DrivingView: View {
    @ObservedObject var detector: DetectorDashboard
    @ObservedObject var session: DriveSession
    @ObservedObject var motion: MotionService // session.motion, observed here so the speed redraws.
    @ObservedObject var recorder: DriveRecorder // session.recorder, for the passenger's mark buttons.
    let supervisor: String
    let log: DriveLog
    let onEnd: () -> Void // Called when the drive ends (parked only).
    @State private var ending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Testing: while the front camera runs, show it big on the left (the phone is sideways, so height is scarce)
            // to see whether the face clips off the edge during head turns.
            if session.frontCamera && DriveSession.showFacePreview {
                HStack(spacing: 16) {
                    FacePreview(look: session.look)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    info.frame(maxWidth: .infinity)
                }
                .padding()
            } else {
                info.padding()
            }
        }
        .statusBarHidden()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // Keep the screen on.
            session.start(detector: detector, supervisor: supervisor, log: log)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await session.stop(detector: detector) } // No-op if End Drive already stopped it.
        }
    }

    // Phase, last words, look status, speed, totals and End Drive.
    private var info: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(Self.title(session.phase))
                .font(.largeTitle.bold()).foregroundStyle(Self.color(session.phase))
            if let words = session.lastSpoken {
                Text("“\(words)”").font(.title3).foregroundStyle(.white.opacity(0.6))
            }
            if !session.lookStatus.isEmpty {
                Text(session.lookStatus).font(.title3.bold()).foregroundStyle(.cyan)
            }
            Spacer()
            if recorder.recording && DriveSession.showPassengerMarks { marks }
            HStack(spacing: 14) {
                if session.recorder.recording {
                    Label("REC", systemImage: "circle.fill").foregroundStyle(.red.opacity(0.8))
                }
                if detector.nightCamera { Image(systemName: "moon.fill").accessibilityLabel("Night camera") }
                Text(speedText).monospacedDigit()
            }
            .font(.headline).foregroundStyle(.white.opacity(0.4))
            if !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.4)) }
            if !detector.running && !session.frontCamera { Text(detector.status).font(.caption).foregroundStyle(.orange) } // Camera problem.
            Button(ending ? "Saving…" : "End Drive") {
                ending = true
                Task { await session.stop(detector: detector); onEnd() }
            }
            .buttonStyle(.bordered).tint(.white.opacity(0.6)).disabled(ending)
        }
    }

    // For the PASSENGER (never the driver): tap right after something happens. Saved in sensors.csv as "mark" rows.
    private var marks: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(DriveRecorder.presetMarks, id: \.self) { name in
                    Button { recorder.mark(name) } label: {
                        Text(name).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).tint(.white.opacity(0.7))
                }
            }
            Text(recorder.lastMark.map { "Marked: \($0) (\(recorder.markCount) total)" } ?? "Passenger: tap to mark what just happened")
                .font(.caption).foregroundStyle(recorder.lastMark == nil ? .white.opacity(0.4) : .green)
        }
    }

    private var speedText: String {
        motion.speed.map { String(format: "%.0f mph", $0 * 2.237) } ?? "GPS –"
    }

    private var summary: String {
        let full = session.results.filter { $0.outcome == .fullStop }.count
        let almost = session.results.filter { $0.outcome == .almostStopped }.count
        let rolling = session.results.filter { $0.outcome == .rolling }.count
        var parts: [String] = []
        if !session.results.isEmpty {
            parts.append("\(full) full")
            if almost > 0 { parts.append("\(almost) almost") }
            if rolling > 0 { parts.append("\(rolling) rolling") }
        }
        if !session.lookChecks.isEmpty { parts.append("looked \(session.lookChecks.filter { $0 }.count)/\(session.lookChecks.count)") }
        return parts.joined(separator: " · ")
    }

    private static func title(_ phase: CoachPhase) -> String {
        switch phase {
        case .idle, .signCandidate: return "Watching the road" // A candidate isn't confirmed yet: say nothing new.
        case .approaching: return "Stop sign ahead"
        case .stopping: return "Slowing"
        case .stopped: return "Stopped"
        case .departing, .evaluate: return "Going"
        }
    }

    private static func color(_ phase: CoachPhase) -> Color {
        switch phase {
        case .idle, .signCandidate: return .white.opacity(0.35)
        case .approaching, .stopping: return .red
        case .stopped: return .green
        case .departing, .evaluate: return .white.opacity(0.7)
        }
    }
}
