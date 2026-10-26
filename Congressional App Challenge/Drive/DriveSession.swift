import Foundation
import CoreGraphics // CGRect (sign boxes).
import CoreLocation // Start coordinate, for sunset/sunrise.
import Combine // ObservableObject/@Published.

// One real drive: starts the camera and sensors, and once per analyzed camera frame (~7 a second) hands the coach
// the latest numbers, then acts on what it says (speak, show the phase, keep the result for the report card).
// This is the same glue as Scripts/coach_replay.swift, just with live data instead of a recording.
@MainActor
final class DriveSession: ObservableObject {
    // These four are chosen in Settings (AppSettings) and read when a drive starts.
    // Save video + sensors of every drive on the phone (Documents/Drives). Kept in the final app so the driver can
    // review a drive afterward; never uploaded. Also lets a bad coach call be replayed in the viewer during testing.
    static var recordDrives: Bool { AppSettings.record }
    // Label buttons for a passenger on the Driving screen. Testing only: off for the submission build (zero-touch).
    static var showPassengerMarks: Bool { AppSettings.passengerMarks }
    // Look-both-ways check: calibrate the driver's head turns at the start, then watch them at every full stop.
    static var lookCheck: Bool { AppSettings.lookCheck }
    // Show the front camera with the face drawing on the Driving screen during calibration and stops. Testing only.
    static var showFacePreview: Bool { AppSettings.facePreview }
    // TEMPORARY (testing): also save the front camera's video while it runs (head-turn setup + each stop) into the drive
    // folder as front_00_setup.mov, front_01.mov, ..., for later analysis of head yaw. sensors.csv gets a "front_clip" row
    // per clip (t = the clip's first frame, so clip seconds = t - that row's t) and a "face" row per analyzed frame (yaw).
    // Only when drive video is saved. To remove: set false (or delete the "Front camera clips" code below).
    static let saveFrontCamera = true
    static let lookPromptSeconds = 3.0 // Stopped this long without both looks: say which side is missing (once per stop).

    @Published private(set) var phase = CoachPhase.idle
    @Published private(set) var lastSpoken: String?
    @Published private(set) var results: [StopSignResult] = [] // This drive's stop signs, for the report card.
    @Published private(set) var active = false
    @Published private(set) var lastSummary: DriveSummary? // The drive that just ended, for its report card.
    @Published private(set) var lookStatus = "" // Calibration step or this stop's look state, for the screen.
    @Published private(set) var frontCamera = false // True while the front camera runs (back camera off).
    @Published private(set) var lookChecks: [Bool] = [] // One per full stop the head check watched: true = looked both ways.

    let motion = MotionService()
    let recorder = DriveRecorder()
    private var coach = StopSignCoach()
    private let voice = Voice()
    private var stopSigns: [DriveSummary.StopSign] = []
    private var startDate = Date()
    private var startUptime = 0.0
    private var supervisor = ""
    private weak var log: DriveLog?

    // Look check. Only one camera can run at a time here, so: calibrate with the front camera first, then use the back
    // camera to drive, and swap to the front camera from STOPPING until the car leaves (the sign is already confirmed;
    // only speed matters). Starting at STOPPING, not STOPPED, catches looks made in the 1-2 s before the coach is sure
    // the car stopped (Oct 24 drive: STOPPED fired 1-2 s after the car really stopped, plus the camera swap time).
    let look = LookCheckService()
    private var lookReady = false // Calibrated for this drive.
    private var headCheck = false // The front camera is watching this stop (STOPPING or STOPPED).
    private var stoppedAt: Double? // When this stop reached STOPPED (prompt timing, and whether it gets graded).
    private var coachTicker: Task<Void, Never>? // Steps the coach while the back camera is off.
    private var prompted = false // Said "look left/right" at this stop.
    private var praised = false // Said "good" at this stop.
    private weak var detector: DetectorDashboard?

    // Front camera clips (see saveFrontCamera).
    private var frontClip: VideoWriter?
    private var frontClipCount = 0
    private var frontClipSaving: Task<Void, Never>? // Finishing the last clip; the drive's end waits for it.
    private var setupFaces: [(yaw: Double?, t: Double)] = [] // Yaw during setup, before the recorder (and its CSV) starts.

    func start(detector: DetectorDashboard, supervisor: String, log: DriveLog) {
        guard !active else { return }
        active = true
        self.supervisor = supervisor; self.log = log
        startDate = Date(); startUptime = ProcessInfo.processInfo.systemUptime
        coach = StopSignCoach(); phase = .idle; lastSpoken = nil; results = []; stopSigns = []
        lookChecks = []; lookReady = false; headCheck = false; stoppedAt = nil; lookStatus = ""
        self.detector = detector
        voice.prepare()
        detector.onLiveFrame = { [weak self] boxes in self?.frame(boxes) }
        look.onSample = { [weak self] yaw, time in self?.faceSample(yaw, time); self?.lookSample() }
        frontClip = nil; frontClipCount = 0; setupFaces = []
        guard Self.lookCheck else { beginDriving(detector); return }
        // Parked: calibrate first (about 12 s of "look straight / left / right"), then start the road camera.
        lookStatus = "Head check setup: follow the voice"
        frontCamera = true
        startFrontClip(name: "front_00_setup.mov", in: FileManager.default.temporaryDirectory) // No drive folder yet.
        look.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5)) // Let the camera find the face.
            guard let self, self.active else { return }
            self.look.calibrate { [weak self] ok in
                guard let self, self.active else { return }
                self.lookReady = ok
                self.lookStatus = ok ? "" : "Head check off for this drive (calibration failed)"
                self.recorder.note("look calibration: \(ok ? "ok" : "failed")")
                self.look.stop(); self.frontCamera = false
                let setupClip = self.frontClip; self.frontClip = nil; self.look.setClip(nil)
                self.beginDriving(detector)
                Task { await self.keepSetupClip(setupClip) }
            }
        }
    }

    private func beginDriving(_ detector: DetectorDashboard) {
        if Self.recordDrives { recorder.start(detector: detector, motion: motion) } // Starts camera + sensors too.
        if !recorder.recording { motion.start(); detector.start() } // Not recording (or the recorder failed).
    }

    func stop(detector: DetectorDashboard) async {
        guard active else { return }
        active = false
        detector.onLiveFrame = nil
        look.onSample = nil
        coachTicker?.cancel(); coachTicker = nil; headCheck = false
        look.stop(); frontCamera = false
        endFrontClip()
        await frontClipSaving?.value // Its CSV row must land before the recorder closes the file.
        voice.finish()
        let end = Date()
        let wasRecording = recorder.recording
        if wasRecording { await recorder.stop(detector: detector, motion: motion) } else { detector.stop(); motion.stop() }
        saveSummary(end: end, recordingFolder: wasRecording ? recorder.last?.folder.lastPathComponent : nil)
    }

    private func saveSummary(end: Date, recordingFolder: String?) {
        let place = motion.firstCoordinate.map { (latitude: $0.latitude, longitude: $0.longitude) } ?? SunTimes.fallbackCoordinate
        func offset(_ date: Date) -> Double { date.timeIntervalSince(startDate) }
        var summary = DriveSummary(
            start: startDate, end: end, distanceMeters: motion.distance,
            nightSeconds: SunTimes.nightSeconds(from: startDate, to: end, latitude: place.latitude, longitude: place.longitude),
            supervisor: supervisor, stopSigns: stopSigns,
            hardBrakes: motion.events.filter { $0.kind == .hardBrake }.map { .init(secondsIntoDrive: offset($0.date), g: $0.accel) },
            hardAccels: motion.events.filter { $0.kind == .hardAccel }.map { .init(secondsIntoDrive: offset($0.date), g: $0.accel) },
            recordingFolder: recordingFolder)
        if lookReady { summary.lookChecksPassed = lookChecks.filter { $0 }.count; summary.lookChecksMissed = lookChecks.filter { !$0 }.count }
        lastSummary = summary.duration >= DriveLog.minSecondsToKeep ? summary : nil
        log?.add(summary)
    }

    private func frame(_ boxes: [SignDetection]) {
        let sign = boxes.first(where: \.isPrimary) // Closest sign front on your side (see DetectionEngine.perform).
        step(signHeight: sign.map { Double($0.box.height) })
    }

    // One coach update. Called per back-camera frame, and per front-camera frame while stopped (no sign info then).
    private func step(signHeight: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        let gps = motion.freshGPS(now: now)
        let input = CoachInput(t: now, signBoxHeight: signHeight, speed: gps.speed,
                               forwardAccel: motion.forwardAccel, stopHint: gps.stopHint, isStill: motion.isStill)
        for output in coach.update(input) {
            switch output {
            case .speak(let words):
                voice.say(words)
                lastSpoken = words
                recorder.note("speak: \(words)")
            case .phaseChanged(let from, let to):
                phase = to
                recorder.note("phase: \(from) -> \(to)")
                if to == .stopping { startHeadCheck() }
                if to == .stopped, headCheck { stoppedAt = now }
                if from == .stopping, to != .stopped { endHeadCheck(graded: false) } // Never fully stopped.
                if from == .stopped { endHeadCheck(graded: true) }
            case .result(let result):
                recorder.note("result: \(result.outcome), min speed \(result.minSpeed.map { String(format: "%.2f", $0) } ?? "none")"
                              + String(format: ", peak brake %.2f g", result.peakBrakeG))
                guard result.outcome != .passedThrough else { break } // Drove past a sign for another road: not a stop.
                results.append(result)
                stopSigns.append(.init(secondsIntoDrive: input.t - startUptime, outcome: "\(result.outcome)",
                                       minSpeed: result.minSpeed, peakBrakeG: result.peakBrakeG))
            }
        }
    }

    // MARK: Look both ways

    private func startHeadCheck() {
        guard lookReady, let detector else { return }
        detector.stop() // The front camera needs the back one off.
        look.resetCheck()
        look.start()
        if let folder = recorder.folderURL {
            frontClipCount += 1
            startFrontClip(name: String(format: "front_%02d.mov", frontClipCount), in: folder)
        }
        frontCamera = true; headCheck = true
        stoppedAt = nil; prompted = false; praised = false
        lookStatus = "Check left and right"
        // The coach needs steps to see the car stop and leave. Drive them from a timer at the back camera's rate,
        // so the coach keeps going even while the front camera is starting up or can't find a face.
        coachTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.15))
                guard let self, self.headCheck else { return }
                self.step(signHeight: nil)
            }
        }
    }

    // The car is leaving the stop: judge it (only if it fully stopped), then go back to watching the road.
    private func endHeadCheck(graded: Bool) {
        guard headCheck, let detector else { return }
        coachTicker?.cancel(); coachTicker = nil
        if graded {
            let passed = look.detector?.passed ?? false
            lookChecks.append(passed)
            recorder.note("look check: \(passed ? "passed" : "missed")")
            if !passed { say("Remember to look both ways") }
            lookStatus = passed ? "Looked both ways" : "Missed the look-both-ways check"
        } else {
            recorder.note("look check: not graded (no full stop)") // The rolling stop is what gets coached here.
            lookStatus = ""
        }
        look.stop()
        endFrontClip()
        frontCamera = false; headCheck = false
        stoppedAt = nil
        detector.start()
    }

    // MARK: Front camera clips (testing, see saveFrontCamera)

    private func startFrontClip(name: String, in folder: URL) {
        guard Self.saveFrontCamera, Self.recordDrives else { return }
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url) // AVAssetWriter fails if the file exists.
        let writer = VideoWriter(url: url, bitRate: 1_500_000) // 640x480 face: half the road video's rate is plenty.
        frontClip = writer
        look.setClip(writer)
    }

    // Stop feeding the current clip, then finish it in the background and log where it starts.
    private func endFrontClip() {
        guard let writer = frontClip else { return }
        frontClip = nil
        look.setClip(nil)
        let previous = frontClipSaving
        frontClipSaving = Task { [weak self] in
            await previous?.value
            await writer.finish()
            guard let self else { return }
            guard let start = writer.startTime else { try? FileManager.default.removeItem(at: writer.url); return }
            self.recorder.frontClip(file: writer.url.lastPathComponent, startT: start, frames: writer.frames)
        }
    }

    // The setup clip was written before the drive folder existed: move it in once the recorder has started.
    private func keepSetupClip(_ writer: VideoWriter?) async {
        let faces = setupFaces; setupFaces = []
        guard let writer else { return }
        await writer.finish()
        guard let folder = recorder.folderURL, let start = writer.startTime else {
            try? FileManager.default.removeItem(at: writer.url); return
        }
        let destination = folder.appendingPathComponent(writer.url.lastPathComponent)
        do { try FileManager.default.moveItem(at: writer.url, to: destination) } catch { return }
        recorder.frontClip(file: destination.lastPathComponent, startT: start, frames: writer.frames, note: "setup")
        for face in faces { recorder.face(yaw: face.yaw, at: face.t) }
    }

    private func faceSample(_ yaw: Double?, _ time: TimeInterval) {
        guard Self.saveFrontCamera, Self.recordDrives else { return }
        if recorder.recording { recorder.face(yaw: yaw, at: time) } else if !lookReady { setupFaces.append((yaw, time)) }
    }

    // Each front-camera frame during a stop: update the look state; speak only once the car has fully stopped.
    private func lookSample() {
        guard headCheck, let check = look.detector else { return } // Calibration frames are handled by LookCheckService.
        if check.passed {
            lookStatus = "Looked both ways"
            if !praised, stoppedAt != nil { praised = true; say("Good") }
            return
        }
        lookStatus = "Left \(check.leftSeen ? "✓" : "–")   Right \(check.rightSeen ? "✓" : "–")"
        if !prompted, let stoppedAt, ProcessInfo.processInfo.systemUptime - stoppedAt >= Self.lookPromptSeconds {
            prompted = true
            say(check.leftSeen ? "Look right" : check.rightSeen ? "Look left" : "Look left and right")
        }
    }

    private func say(_ words: String) {
        voice.say(words)
        lastSpoken = words
        recorder.note("speak: \(words)")
    }
}
