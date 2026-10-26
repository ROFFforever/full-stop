import AVFoundation // Front camera capture and speech.
import Vision // Face landmarks and head yaw.
import CoreImage // Camera frame -> CGImage for the visualizer.
import Combine // ObservableObject/@Published.

// MARK: - Pure logic (no frameworks, replayable on recorded yaw)

// Baselines from the parked "look straight / left / right" step. Yaw is in degrees.
struct LookCalibration {
    static let minDeflection = 15.0 // Looking to a side must move yaw at least this far from straight.
    static let thresholdRange = 10.0...25.0 // A look counts after yaw moves this far from straight.

    let straight: Double
    let leftOffset: Double // left - straight (signed; the camera's sign convention is learned, not assumed).
    let rightOffset: Double // right - straight.

    var leftSign: Double { leftOffset >= 0 ? 1 : -1 } // Which way yaw moves when looking left.
    var leftThreshold: Double { min(max(abs(leftOffset) / 2, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound) }
    var rightThreshold: Double { min(max(abs(rightOffset) / 2, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound) }

    // Nil when the camera can't tell the sides apart (face too hard to see, or mount too off-axis).
    init?(straight: Double, left: Double, right: Double) {
        let l = left - straight, r = right - straight
        guard abs(l) >= Self.minDeflection, abs(r) >= Self.minDeflection, (l > 0) != (r > 0) else { return nil }
        self.straight = straight
        leftOffset = l
        rightOffset = r
    }
}

// Watches yaw samples during one stop and records which sides the driver looked at.
struct LookDetector {
    static let dwell = 0.3 // Seconds yaw must stay past the threshold.
    static let lostFraction = 0.6 // Face lost after reaching this much of the threshold, heading outward, counts.

    let calibration: LookCalibration
    private(set) var leftSeen = false
    private(set) var rightSeen = false
    private(set) var deviation: Double? // Smoothed yaw from straight; positive = toward the driver's left.
    var passed: Bool { leftSeen && rightSeen }

    private var smoother = ExponentialSmoother(alpha: 0.4)
    private var leftHold: SustainDetector
    private var rightHold: SustainDetector
    private var trend = 0.0 // Last frame-to-frame change in deviation.

    init(calibration: LookCalibration) {
        self.calibration = calibration
        leftHold = SustainDetector(threshold: calibration.leftThreshold, direction: .above, duration: Self.dwell)
        rightHold = SustainDetector(threshold: calibration.rightThreshold, direction: .above, duration: Self.dwell)
    }

    // yaw is nil when no face was found in the frame.
    mutating func add(_ yaw: Double?, at time: TimeInterval) {
        guard let yaw else { faceLost(); return }
        let dev = smoother.add(yaw - calibration.straight) * calibration.leftSign // Flip so + always means left.
        trend = dev - (deviation ?? dev)
        deviation = dev
        if leftHold.add(dev, at: time) { leftSeen = true }
        if rightHold.add(-dev, at: time) { rightSeen = true }
    }

    // Big head turns hide the face. If it vanished while heading toward a side, count that side.
    private mutating func faceLost() {
        if let dev = deviation {
            if dev > Self.lostFraction * calibration.leftThreshold, trend > 0 { leftSeen = true }
            if -dev > Self.lostFraction * calibration.rightThreshold, trend < 0 { rightSeen = true }
        }
        smoother.reset(); leftHold.reset(); rightHold.reset()
        deviation = nil; trend = 0
    }
}

// MARK: - Front camera -> head yaw

// One face as Vision saw it. Points are normalized to the frame with the origin at the bottom-left.
nonisolated struct FaceOverlay: Sendable {
    let box: CGRect
    let yaw: Double? // Degrees.
    let pitch: Double?
    let roll: Double?
    let confidence: Float
    let isPrimary: Bool // The largest face, the one the look check uses.
    let outlines: [[CGPoint]] // Open polylines (contour, brows, nose).
    let loops: [[CGPoint]] // Closed shapes (eyes, lips).
    let pupils: [CGPoint]
}

// One analyzed camera frame plus what was found in it, for the debug visualizer.
nonisolated struct FaceFrame: @unchecked Sendable {
    let image: CGImage?
    let faces: [FaceOverlay]
    let bufferMirrored: Bool // True if the image is already a mirror (selfie) view.
}

// Runs Vision face landmarks on the front camera at a low rate and reports the yaw of the largest face.
nonisolated final class HeadYawTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var report: (@Sendable (_ yawDegrees: Double?, _ time: TimeInterval, _ error: String?) -> Void)?
    var onFrame: (@Sendable (FaceFrame) -> Void)? // Set only while the visualizer is open; building images costs time.
    var onCameraInfo: (@Sendable (String) -> Void)? // What view the front camera actually gives (format, field of view, zoom).
    private let queue = DispatchQueue(label: "lookCheck.tracker")
    private let imageContext = CIContext()
    private let request = VNDetectFaceLandmarksRequest()
    private var rotation: CameraRotation? // Follows how the phone is physically held.
    private var connection: AVCaptureConnection?
    private var configured = false
    private var enabled = false
    private var lastRun = 0.0
    private var clip: VideoWriter? // Front-camera recording, every frame (testing: kept for later analysis).

    // Pass a writer to save the front camera's frames to a .mov; nil stops feeding it (call finish() on it after).
    func setClip(_ writer: VideoWriter?) { queue.async { self.clip = writer } }

    func start() {
        queue.async {
            self.enabled = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async {
                    guard self.enabled else { return }
                    guard granted else { self.report?(nil, 0, "Camera permission denied. Enable it in Settings."); return }
                    do {
                        if !self.configured { try self.configure() }
                        self.lastRun = 0
                        self.session.startRunning()
                    } catch { self.report?(nil, 0, error.localizedDescription) }
                }
            }
        }
    }

    func stop() { queue.async { self.enabled = false; self.session.stopRunning() } }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "LookCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "No front camera (simulator?)."])
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "LookCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Front camera configuration failed."])
        }
        session.addInput(input)
        let info = useWidestView(camera) // A plain preset gave a cropped, zoomed-in view: the head left the frame.
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        connection = output.connection(with: .video)
        if let connection, connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off } // Stabilizing crops.
        onCameraInfo?(info)
        rotation = CameraRotation(device: camera)
        configured = true
    }

    // The driver's head must stay in view while turning, so take the widest picture the front camera offers (like the
    // Camera app's zoom-out), not whatever a size preset picks. Ties go to the taller picture, then the smallest one that is
    // still at least minWidth wide (the iPhone 17 offers 192x144 at full width: far too blurry for a face in a car).
    private func useWidestView(_ camera: AVCaptureDevice) -> String {
        // Center Stage crops in to follow a face; we want the whole view, fixed.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        func size(_ format: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(format.formatDescription) }
        let usable = camera.formats.filter { format in
            [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] // Plain 8-bit formats.
                .contains(CMFormatDescriptionGetMediaSubType(format.formatDescription))
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 15 }
        }
        let widest = usable.max { a, b in
            let fa = a.videoFieldOfView.rounded(), fb = b.videoFieldOfView.rounded()
            if fa != fb { return fa < fb }
            let ta = Double(size(a).height) / Double(size(a).width), tb = Double(size(b).height) / Double(size(b).width)
            if abs(ta - tb) > 0.01 { return ta < tb }
            let wa = Int(size(a).width), wb = Int(size(b).width), minWidth = 640
            if (wa >= minWidth) != (wb >= minWidth) { return wa < minWidth } // Big enough beats too small.
            return wa >= minWidth ? wa > wb : wa < wb // Among big enough: smaller (faster). Among too small: bigger.
        }
        var notes: [String] = []
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let widest {
                session.sessionPreset = .inputPriority // We choose the format ourselves.
                camera.activeFormat = widest
            } else {
                session.sessionPreset = .vga640x480
                notes.append("no format list; using VGA preset")
            }
            camera.videoZoomFactor = camera.minAvailableVideoZoomFactor // Fully zoomed out.
        } catch { notes.append("could not set format: \(error.localizedDescription)") }
        let d = size(camera.activeFormat)
        let maxFOV = camera.formats.map(\.videoFieldOfView).max() ?? 0
        return String(format: "%dx%d, field of view %.0f° (widest offered %.0f°), zoom %.2f (min %.2f), Center Stage %@",
                      d.width, d.height, camera.activeFormat.videoFieldOfView, maxFOV, camera.videoZoomFactor,
                      camera.minAvailableVideoZoomFactor, AVCaptureDevice.isCenterStageEnabled ? "ON" : "off")
            + (notes.isEmpty ? "" : "; " + notes.joined(separator: "; "))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard enabled else { return }
        // Rotate frames so the face is upright however the phone is held (portrait or either landscape).
        rotation?.apply(to: connection)
        clip?.append(sampleBuffer)
        let now = ProcessInfo.processInfo.systemUptime
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        guard now - lastRun >= (hot ? 0.25 : 0.1), // About 10 fps, 4 fps when hot.
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRun = now
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            // Several faces (a supervisor): track only the largest = closest.
            let faces = request.results ?? []
            let face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            report?(face?.yaw.map { $0.doubleValue * 180 / .pi }, now, nil)
            if let onFrame {
                let image = imageContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
                onFrame(FaceFrame(image: image, faces: faces.map { Self.overlay($0, isPrimary: $0 === face) }, bufferMirrored: connection.isVideoMirrored))
            }
        } catch { report?(nil, now, error.localizedDescription) }
    }

    // Convert landmark points (relative to the face box) into frame-normalized points.
    private static func overlay(_ face: VNFaceObservation, isPrimary: Bool) -> FaceOverlay {
        let box = face.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.normalizedPoints.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) } ?? []
        }
        let marks = face.landmarks
        func degrees(_ radians: NSNumber?) -> Double? { radians.map { $0.doubleValue * 180 / .pi } }
        return FaceOverlay(
            box: box, yaw: degrees(face.yaw), pitch: degrees(face.pitch), roll: degrees(face.roll),
            confidence: face.confidence, isPrimary: isPrimary,
            outlines: [points(marks?.faceContour), points(marks?.leftEyebrow), points(marks?.rightEyebrow),
                       points(marks?.noseCrest), points(marks?.nose), points(marks?.medianLine)],
            loops: [points(marks?.leftEye), points(marks?.rightEye), points(marks?.outerLips), points(marks?.innerLips)],
            pupils: points(marks?.leftPupil) + points(marks?.rightPupil))
    }
}

// MARK: - Service used by the UI

@MainActor
final class LookCheckService: ObservableObject {
    enum Step: String, CaseIterable {
        case straight = "Look straight at the road"
        case left = "Look left"
        case right = "Look right"
    }

    @Published private(set) var yawDegrees: Double? // Raw yaw; nil = no face.
    @Published private(set) var running = false
    @Published private(set) var status = "Camera off"
    @Published private(set) var cameraInfo = "" // Front camera format, field of view and zoom (Debug screen).
    @Published private(set) var calibration: LookCalibration?
    @Published private(set) var calibrationStep: Step? // Non-nil while calibrating.
    @Published private(set) var detector: LookDetector? // Non-nil once calibrated.

    private let tracker = HeadYawTracker()
    private let speech = AVSpeechSynthesizer()
    private var samples: [Double] = []
    private var collecting = false
    private var calibrationTask: Task<Void, Never>?
    private var calibrationDone: ((Bool) -> Void)?
    // After each analyzed front-camera frame (yaw nil = no face, time on the systemUptime clock). The drive session
    // checks the look state here and logs the yaw.
    var onSample: ((_ yaw: Double?, _ time: TimeInterval) -> Void)?

    init() {
        tracker.report = { [weak self] yaw, time, error in
            Task { @MainActor [weak self] in self?.handle(yaw, time, error) }
        }
        tracker.onCameraInfo = { [weak self] info in Task { @MainActor [weak self] in self?.cameraInfo = info } }
    }

    var session: AVCaptureSession { tracker.session }
    func setClip(_ writer: VideoWriter?) { tracker.setClip(writer) }

    // The visualizer subscribes while it is on screen; pass nil to stop paying for frame images.
    func observeFrames(_ handler: (@MainActor @Sendable (FaceFrame) -> Void)?) {
        tracker.onFrame = handler.map { handler in { frame in Task { @MainActor in handler(frame) } } }
    }

    func start() { guard !running else { return }; running = true; status = "Looking for a face"; tracker.start() }

    func stop() {
        calibrationTask?.cancel(); calibrationStep = nil; collecting = false
        tracker.stop(); running = false; yawDegrees = nil; status = "Camera off"
    }

    // Starts a new stop: forget which sides were seen.
    func resetCheck() { if let calibration { detector = LookDetector(calibration: calibration) } }

    // Parked, three steps: record the median yaw while the driver holds each pose.
    func calibrate(done: ((Bool) -> Void)? = nil) {
        guard running, calibrationStep == nil else { return }
        calibrationDone = done
        calibrationTask = Task {
            var medians: [Step: Double] = [:]
            for step in Step.allCases {
                calibrationStep = step
                speak(step.rawValue)
                try? await Task.sleep(for: .seconds(2)) // Time to turn the head.
                samples = []; collecting = true
                try? await Task.sleep(for: .seconds(1.5))
                collecting = false
                guard !Task.isCancelled else { return }
                guard samples.count >= 8 else { finishCalibration(nil, "Face not found during \"\(step.rawValue)\"."); return }
                medians[step] = samples.sorted()[samples.count / 2]
            }
            guard let s = medians[.straight], let l = medians[.left], let r = medians[.right] else { return }
            finishCalibration(LookCalibration(straight: s, left: l, right: r), "Left and right look too similar. Turn further or move the phone.")
        }
    }

    private func finishCalibration(_ result: LookCalibration?, _ failure: String) {
        calibrationStep = nil
        calibration = result
        detector = result.map { LookDetector(calibration: $0) }
        status = result == nil ? failure : "Calibrated"
        speak(result == nil ? "Calibration failed" : "Calibrated")
        calibrationDone?(result != nil); calibrationDone = nil
    }

    private func handle(_ yaw: Double?, _ time: TimeInterval, _ error: String?) {
        guard running else { return }
        if let error { status = error; return }
        yawDegrees = yaw
        if collecting, let yaw { samples.append(yaw) }
        if calibrationStep == nil {
            detector?.add(yaw, at: time) // A mutating call on the published value publishes the change.
            if detector == nil { status = yaw == nil ? "No face found" : "Face found. Calibrate next." }
        }
        onSample?(yaw, time)
    }

    private func speak(_ text: String) { speech.speak(AVSpeechUtterance(string: text)) }
}
