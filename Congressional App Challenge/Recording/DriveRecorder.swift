import AVFoundation // Video writing.
import UIKit // Device info, idle timer.
import Combine // ObservableObject/@Published.

// Records a test drive to Documents/Drives/<timestamp>/ :
//   video.mov    back-camera video (HEVC, no audio)
//   sensors.csv  motion, GPS, detections, events and marks on ONE clock
//   meta.json    device, model, tuning, and the video's start time on that clock
// Clock: every `t` is ProcessInfo.systemUptime seconds. Core Motion, camera frames and this app all use it,
// so video time = t - meta.video_start_t.

// MARK: - CSV

// Thread-safe appender. One file, many row kinds; unused columns are left empty.
nonisolated final class CSVLog: @unchecked Sendable {
    static let columns = [
        "t", "kind",
        "ax", "ay", "az", // userAcceleration, g (gravity removed), phone frame.
        "gx", "gy", "gz", // gravity vector, g, phone frame.
        "rx", "ry", "rz", // gyroscope rotation rate, rad/s, phone frame.
        "roll", "pitch", "yaw", // attitude, rad.
        "m11", "m12", "m13", "m21", "m22", "m23", "m31", "m32", "m33", // rotation matrix (world -> phone).
        "fwd_raw", "fwd", // forward acceleration, g: projected only / fully filtered. Empty when not tracking.
        "fx", "fy", "fz", // Axis row: the learned forward axis, phone frame (fwd_raw = a · axis).
        "speed", "speed_acc", "course", "lat", "lon", "h_acc", "gps_age", // GPS fix. gps_age = seconds between fix time and t.
        "label", "conf", "bx", "by", "bw", "bh", // Detection: Vision box, 0...1, origin bottom-left.
        "red", // Stop signs only: share of red pixels in the box (SignColor). Empty if the box was too small to judge.
        "ms", "thermal", // Frame row: inference milliseconds, ProcessInfo thermal state 0...3.
        "iso", "exp_s", "night", // Frame row: camera ISO, shutter seconds, 1 = night camera settings (CameraTuning).
        "note", // Marks, events, errors.
        "head_yaw", // Face row: head yaw in degrees from the front camera (empty = no face found).
    ]

    private let index: [String: Int]
    private let queue = DispatchQueue(label: "drive.csv")
    private let handle: FileHandle
    private var buffer = ""
    private var lastFlush = ProcessInfo.processInfo.systemUptime
    private(set) var rows = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        index = Dictionary(Self.columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) // A repeated name must not crash a drive.
        buffer = Self.columns.joined(separator: ",") + "\n"
    }

    // fields: column name -> text. Unknown names are ignored.
    func write(t: Double, kind: String, _ fields: [String: String] = [:]) {
        var cells = [String](repeating: "", count: Self.columns.count)
        cells[0] = Self.num(t, 4)
        cells[1] = kind
        for (name, text) in fields { if let i = index[name] { cells[i] = Self.escape(text) } }
        let line = cells.joined(separator: ",") + "\n"
        queue.async {
            self.buffer += line
            self.rows += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastFlush > 2 { self.flushLocked(now) } // Never lose more than ~2 s to a crash.
        }
    }

    // Blocks until everything is on disk.
    func close() {
        queue.sync {
            flushLocked(ProcessInfo.processInfo.systemUptime)
            try? handle.close()
        }
    }

    private func flushLocked(_ now: Double) {
        if let data = buffer.data(using: .utf8) { try? handle.write(contentsOf: data) }
        buffer = ""
        lastFlush = now
    }

    static func num(_ value: Double, _ digits: Int = 5) -> String { String(format: "%.\(digits)f", value) }
    private static func escape(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Video

// Writes camera frames to a .mov. append() runs on the camera queue; finish() from anywhere.
nonisolated final class VideoWriter: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var size: CGSize?
    private var failed = false
    private(set) var startTime: Double? // Presentation time of the first frame, on the shared clock.
    private(set) var frames = 0
    private(set) var dropped = 0
    private(set) var error: String?

    private let bitRate: Int

    init(url: URL, bitRate: Int = 3_000_000) { self.url = url; self.bitRate = bitRate }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil { // First frame decides the video size (so rotate the phone before recording).
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: Int(frameSize.width),
                    AVVideoHeightKey: Int(frameSize.height),
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate], // 3 Mbps: about 450 MB per 20 min.
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't add video input."]) }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Recorder", code: 2) }
                writer.startSession(atSourceTime: time)
                self.writer = writer; self.input = input; size = frameSize
                startTime = CMTimeGetSeconds(time)
            } catch { failed = true; self.error = error.localizedDescription; return }
        }
        guard let writer, let input, frameSize == size, writer.status == .writing, input.isReadyForMoreMediaData else {
            dropped += 1 // Encoder behind, or the phone was rotated mid-recording.
            if writer?.status == .failed { failed = true; error = writer?.error?.localizedDescription }
            return
        }
        if input.append(sampleBuffer) { frames += 1 } else { dropped += 1 }
    }

    // Locking must happen in a plain (non-async) function.
    private func closeForNewFrames() -> (AVAssetWriter?, AVAssetWriterInput?) {
        lock.lock(); defer { lock.unlock() }
        failed = true // Ignore frames still arriving.
        return (writer, input)
    }

    func finish() async {
        let (writer, input) = closeForNewFrames()
        guard let writer, writer.status == .writing else { return }
        input?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { error = writer.error?.localizedDescription }
    }
}

// MARK: - Recorder used by the UI

struct RecordedDrive {
    let folder: URL
    let csv: URL
    let video: URL
    let duration: TimeInterval
    let rows: Int
    let frames: Int
    let dropped: Int
    var shareItems: [URL] { [csv, video, folder.appendingPathComponent("meta.json")] }
}

@MainActor
final class DriveRecorder: ObservableObject {
    // Labels a passenger taps during a drive, to learn which readings go with which behavior. The tap comes a second or
    // two after the event, so when analyzing, look at the few seconds before each mark.
    static let presetMarks = ["Full stop", "Rolling stop", "Easy brake", "Medium brake", "Hard brake", "Pedestrian", "Other"]

    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var markCount = 0
    @Published private(set) var lastMark: String?
    @Published private(set) var status = "Not recording"
    @Published private(set) var last: RecordedDrive?

    private var log: CSVLog?
    private var video: VideoWriter?
    private var folder: URL?
    private var startUptime = 0.0
    private var startDate = Date()
    private var ticker: Task<Void, Never>?

    // Starts the back camera + detector, motion/GPS, the CSV and the video together.
    func start(detector: DetectorDashboard, motion: MotionService) {
        guard !recording else { return }
        do {
            let name = Self.folderName.string(from: Date())
            let folder = try Self.drivesDirectory().appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let log = try CSVLog(url: folder.appendingPathComponent("sensors.csv"))
            let video = VideoWriter(url: folder.appendingPathComponent("video.mov"))
            self.folder = folder; self.log = log; self.video = video
        } catch { status = "Could not start: \(error.localizedDescription)"; return }
        guard let log, let video else { return }

        startUptime = ProcessInfo.processInfo.systemUptime
        startDate = Date()
        log.write(t: startUptime, kind: "start", ["note": "model=\(detector.model.rawValue)"])

        motion.log = log
        motion.start()
        detector.engine.setRecording(video: video) { [weak log] frameTime, ms, camera, objects in
            guard let log else { return }
            let thermal = String(ProcessInfo.processInfo.thermalState.rawValue)
            var frame = ["ms": CSVLog.num(ms, 1), "thermal": thermal]
            if let camera {
                frame["iso"] = CSVLog.num(Double(camera.iso), 0)
                frame["exp_s"] = CSVLog.num(camera.exposureSeconds, 5)
                frame["night"] = camera.night ? "1" : "0"
            }
            log.write(t: frameTime, kind: "frame", frame)
            for object in objects {
                var fields = [
                    "label": object.label, "conf": CSVLog.num(Double(object.confidence), 3),
                    "bx": CSVLog.num(object.box.minX, 4), "by": CSVLog.num(object.box.minY, 4),
                    "bw": CSVLog.num(object.box.width, 4), "bh": CSVLog.num(object.box.height, 4),
                ]
                if let tint = object.redTint { fields["red"] = CSVLog.num(tint, 3) }
                log.write(t: frameTime, kind: "det", fields)
            }
        }
        if !detector.running { detector.start() }

        UIApplication.shared.isIdleTimerDisabled = true
        recording = true; elapsed = 0; markCount = 0; lastMark = nil; status = "Recording"
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - self.startUptime
            }
        }
    }

    var folderURL: URL? { folder } // The drive being recorded.

    // Front camera, testing: one analyzed frame's head yaw, and where a saved front-camera clip starts on the clock.
    func face(yaw: Double?, at t: Double) {
        guard recording, let log else { return }
        log.write(t: t, kind: "face", yaw.map { ["head_yaw": CSVLog.num($0, 2)] } ?? [:])
    }
    func frontClip(file: String, startT: Double, frames: Int, note: String = "") {
        guard recording, let log else { return }
        log.write(t: startT, kind: "front_clip", ["note": "file=\(file) frames=\(frames)" + (note.isEmpty ? "" : " \(note)")])
    }

    // A passenger taps this to label what just happened; the time is the tap time.
    func mark(_ text: String) {
        guard recording, let log else { return }
        log.write(t: ProcessInfo.processInfo.systemUptime, kind: "mark", ["note": text])
        markCount += 1
        lastMark = text
    }

    // What the live coach did (phase changes, speech, results), so a drive can be compared with the replay tool.
    func note(_ text: String) {
        guard recording, let log else { return }
        log.write(t: ProcessInfo.processInfo.systemUptime, kind: "coach", ["note": text])
    }

    func stop(detector: DetectorDashboard, motion: MotionService) async {
        guard recording, let log, let video, let folder else { return }
        recording = false
        ticker?.cancel()
        status = "Saving…"
        let endUptime = ProcessInfo.processInfo.systemUptime
        detector.engine.setRecording(video: nil, nil) // Stop feeding frames and detections.
        detector.stop()
        motion.stop()
        motion.log = nil
        log.write(t: endUptime, kind: "end")
        await video.finish()
        log.close()
        UIApplication.shared.isIdleTimerDisabled = false

        writeMeta(folder: folder, video: video, detector: detector, endUptime: endUptime)
        let drive = RecordedDrive(folder: folder, csv: folder.appendingPathComponent("sensors.csv"),
                                  video: video.url, duration: endUptime - startUptime,
                                  rows: log.rows, frames: video.frames, dropped: video.dropped)
        last = drive
        status = video.error.map { "Saved, but video problem: \($0)" } ?? "Saved"
        self.log = nil; self.video = nil; self.folder = nil
    }

    private func writeMeta(folder: URL, video: VideoWriter, detector: DetectorDashboard, endUptime: Double) {
        var system = utsname(); uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let meta: [String: Any] = [
            "start_unix": startDate.timeIntervalSince1970,
            "start_t": startUptime,
            "end_t": endUptime,
            "video_file": "video.mov",
            "video_start_t": video.startTime as Any, // video seconds = t - video_start_t. Null if no frame arrived.
            "video_frames": video.frames,
            "video_dropped_frames": video.dropped,
            "device": machine,
            "ios": UIDevice.current.systemVersion,
            "detector_model": detector.model.rawValue,
            "detector_threshold": detector.threshold,
            "fwd_convention": "positive = speeding up (recordings without this key have the sign inverted)",
            "fwd_method": "fixed phone-frame axis: camera guess, then learned from GPS speed changes (see axis rows). Recordings without this key projected onto GPS course.",
            "camera_settings": detector.engine.cameraSettingsNote,
            "clock": "t = ProcessInfo.systemUptime seconds (Core Motion, camera and app share it)",
            "tuning": [
                "sample_rate": MotionTuning.sampleRate, "max_plausible_g": MotionTuning.maxPlausibleG,
                "median_size": MotionTuning.medianSize, "smoothing": MotionTuning.smoothing,
                "hard_brake_g": MotionTuning.hardBrakeG, "hard_accel_g": MotionTuning.hardAccelG,
                "sustain_seconds": MotionTuning.sustainSeconds, "min_course_speed": MotionTuning.minCourseSpeed,
                "learn_min_g": MotionTuning.learnMinG, "learn_max_turn_degrees": MotionTuning.learnMaxTurnDegrees,
                "lock_samples": MotionTuning.lockSamples, "lock_coherence": MotionTuning.lockCoherence,
                "recheck_samples": MotionTuning.recheckSamples, "relock_degrees": MotionTuning.relockDegrees,
                "mount_moved_degrees": MotionTuning.mountMovedDegrees,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
    }

    private static let folderName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func drivesDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return documents.appendingPathComponent("Drives")
    }
}
