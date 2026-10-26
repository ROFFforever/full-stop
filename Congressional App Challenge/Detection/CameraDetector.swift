import AVFoundation // Camera capture.
import Vision // Runs the model on images.
import CoreML // Loads the ML model.
import Combine // Gives us ObservableObject/@Published.
import UIKit // UIImage and image rendering.

// A small value passed from the background detector to the screen.
struct SignDetection: Identifiable { // One detected stop sign.
    let id = UUID() // Unique ID so SwiftUI can list it.
    let box: CGRect // Vision coordinates: 0...1, origin at bottom-left.
    let confidence: Float // Model's confidence, 0...1.
    var isPrimary = false // The one sign the coach should react to (the largest = closest front).
    var redTint: Double? // Share of red pixels inside the box; nil if the box was too small to judge (see SignColor).
    var isFront: Bool { SignColor.looksLikeFront(tint: redTint) } // False for the gray/white back of a sign.
    var area: CGFloat { box.width * box.height }
}

// Bundled models the debug screen can switch between. Raw value = .mlpackage name.
enum DetectorModel: String, CaseIterable, Identifiable {
    case nano640 = "yolo11n"
    case nano960 = "yolo11n_960"
    case nano1280 = "yolo11n_1280"
    case small640 = "yolo11s_640"
    case small960 = "yolo11s_960"
    case small1280 = "yolo11s_1280"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nano640: return "11n · 640"
        case .nano960: return "11n · 960"
        case .nano1280: return "11n · 1280"
        case .small640: return "11s · 640"
        case .small960: return "11s · 960"
        case .small1280: return "11s · 1280"
        }
    }
}

// Running totals for one model, so models can be compared on the same footage.
struct ModelStats {
    var frames = 0
    var hits = 0 // Frames with at least one stop sign.
    var totalMs = 0.0
    var maxMs = 0.0
    var confidenceSum = 0.0 // Sum of the best box's confidence on hit frames.
    var worstThermal = 0 // Highest ProcessInfo.ThermalState rawValue seen (0 nominal ... 3 critical).
    var avgMs: Double { frames > 0 ? totalMs / Double(frames) : 0 }
    var hitRate: Double { frames > 0 ? Double(hits) / Double(frames) : 0 }
    var avgConfidence: Double { hits > 0 ? confidenceSum / Double(hits) : 0 }
}

@MainActor // All of this runs on the UI thread.
final class DetectorDashboard: ObservableObject { // State the UI watches.
    @Published var boxes: [SignDetection] = [] // Current detected signs.
    @Published var status = "Ready to test" // Status text shown on screen.
    @Published var milliseconds = 0.0 // Last inference time.
    @Published var analyzed = 0 // Frames analyzed so far.
    @Published var hits = 0 // Frames with a sign found.
    @Published var running = false // True while camera is on.
    @Published var photo: UIImage? // Photo being tested, if any.
    @Published var threshold = 0.4 // Minimum confidence to count.
    @Published var model = AppSettings.model // Which model the engine uses (chosen in Settings; default Balanced = 11s · 960).
    @Published var stats: [DetectorModel: ModelStats] = [:] // Per-model totals; cleared by resetStats().
    @Published var thermal = ProcessInfo.processInfo.thermalState // Heat level reported by iOS.
    @Published var fps = 0.0 // Smoothed live detection rate.
    @Published var nightCamera = false // Night camera settings in use (switches by itself from the light level).
    @Published var liveFrameSize = CGSize(width: 720, height: 1280) // Upright live frame size; the preview uses its aspect.
    @Published var benchmarkStatus: String? // Non-nil while a benchmark runs.
    private var analyzedTotal = 0 // Never reset; lets the benchmark wait for a result.
    var onLiveFrame: (([SignDetection]) -> Void)? // Called once per analyzed live camera frame (the drive session feeds the coach).
    private var lastReport = 0.0
    let engine = DetectionEngine() // Background camera + model worker.

    init() {
        engine.setModel(model.rawValue)
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.thermal = ProcessInfo.processInfo.thermalState }
        } // Hook up the engine's results.
        engine.report = { [weak self] boxes, elapsed, error in // Called from background queue.
            Task { @MainActor [weak self] in // Hop to UI thread.
                guard let self, self.running || self.photo != nil else { return } // Ignore stale results.
                if let error { self.status = error; self.running = false; self.boxes = []; return } // Show error and stop.
                self.boxes = boxes // Save new detections.
                if self.photo == nil { self.nightCamera = self.engine.night; self.onLiveFrame?(boxes) }
                if self.photo == nil { self.liveFrameSize = self.engine.frameSize } // Keep the preview aspect in step with the camera.
                self.milliseconds = elapsed // Save inference time.
                self.analyzed += 1 // Count this frame.
                self.analyzedTotal += 1
                if !boxes.isEmpty { self.hits += 1 } // Count a hit.
                var entry = self.stats[self.model, default: ModelStats()] // Per-model comparison totals.
                entry.frames += 1
                entry.totalMs += elapsed
                entry.maxMs = max(entry.maxMs, elapsed)
                entry.worstThermal = max(entry.worstThermal, ProcessInfo.processInfo.thermalState.rawValue)
                if let best = boxes.map(\.confidence).max() { entry.hits += 1; entry.confidenceSum += Double(best) }
                self.stats[self.model] = entry
                let now = ProcessInfo.processInfo.systemUptime
                if self.lastReport > 0, now - self.lastReport < 2 { self.fps = 0.8 * self.fps + 0.2 / (now - self.lastReport) }
                self.lastReport = now
                self.status = boxes.isEmpty ? "No stop sign detected" : "Stop sign detected" // Update label.
            }
        }
    }

    func start() { // Begin live camera detection.
        photo = nil // Clear any test photo.
        reset() // Zero the counters.
        status = "Starting camera…" // Show progress.
        running = true // Mark as running.
        engine.start(threshold: Float(threshold)) // Start the camera.
    }

    func stop() { // Stop live detection.
        engine.stop() // Stop the camera.
        running = false // Mark as stopped.
        boxes = [] // Clear boxes.
        status = "Camera stopped" // Update label.
    }

    func show(frame: CGImage) { // Detect on one video frame without clearing stats.
        if running { engine.stop(); running = false } // Video replaces the live camera.
        photo = UIImage(cgImage: frame) // Display the frame.
        engine.analyze(frame, threshold: Float(threshold)) // Run the model.
    }

    func select(_ newModel: DetectorModel) { // Switch models; re-test the current photo/frame.
        guard newModel != model, !running, benchmarkStatus == nil else { return }
        model = newModel
        engine.setModel(newModel.rawValue)
        UserDefaults.standard.set(newModel.rawValue, forKey: AppSettings.modelKey) // Remembered between launches.
        if let image = photo?.cgImage { engine.analyze(image, threshold: Float(threshold)) }
    }

    func resetStats() { stats = [:]; fps = 0 }

    // Runs the loaded video through every model at the same timestamps and records each model's stats.
    func benchmark(_ inspector: VideoInspector, step: Double = 0.25) async {
        guard inspector.hasVideo, !running, benchmarkStatus == nil else { return }
        inspector.pause()
        let original = model
        let times = Array(stride(from: 0.0, to: max(inspector.duration - 0.05, 0.01), by: step))
        stats = [:]
        for candidate in DetectorModel.allCases {
            model = candidate
            engine.setModel(candidate.rawValue)
            benchmarkStatus = "\(candidate.label): warming up"
            await seekAndWait(inspector, to: 0) // First run includes Core ML load/compile; don't count it.
            stats[candidate] = nil
            for (index, time) in times.enumerated() {
                benchmarkStatus = "\(candidate.label): frame \(index + 1)/\(times.count)"
                await seekAndWait(inspector, to: time)
            }
        }
        model = original
        engine.setModel(original.rawValue)
        benchmarkStatus = nil
        status = "Benchmark finished (\(times.count) frames per model)"
    }

    private func seekAndWait(_ inspector: VideoInspector, to time: Double) async {
        let before = analyzedTotal
        await inspector.seek(to: time)
        var polls = 0
        while analyzedTotal == before, polls < 100 { // Give up after 5 s.
            try? await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
    }

    func reset() { boxes = []; analyzed = 0; hits = 0; milliseconds = 0 } // Clear all stats.

    func analyze(_ data: Data) { // Run detection on one photo.
        stop() // Turn off the camera.
        reset() // Clear stats.
        guard let original = UIImage(data: data) else { status = "Could not read photo"; return } // Decode the photo.
        // Draw once to apply EXIF rotation, so Vision and the preview see identical pixels.
        let scale = min(1, 1600 / max(original.size.width, original.size.height)) // Shrink to max 1600px.
        let size = CGSize(width: original.size.width * scale, height: original.size.height * scale) // Scaled size.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1 // 1 point = 1 pixel.
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in // Redraw upright.
            original.draw(in: CGRect(origin: .zero, size: size)) // Draw into the new size.
        }
        photo = upright // Show the photo.
        status = "Analyzing photo…" // Show progress.
        if let image = upright.cgImage { engine.analyze(image, threshold: Float(threshold)) } // Run the model.
    }
}

// Back-camera settings for a windshield mount. Change these between test drives; they're saved in meta.json.
nonisolated enum CameraTuning {
    // false = continuous autofocus restricted to far range (so it can't focus on the windshield), aimed at the road ahead.
    // Do NOT lock at lens position 1.0: on the iPhone 17 that is past infinity. Oct 21 drives with the lock measured
    // 5-9x blurrier (edge sharpness ~10 vs 47-81 with autofocus), day and night alike.
    static let lockFocusFar = false
    static let focusLensPosition: Float = 1.0 // 0 = nearest, 1 = farthest.
    static let maxExposureSeconds = 1.0 / 250 // Shorter shutter = less motion blur; the phone raises ISO instead.
    static let exposureBias: Float = -0.7 // EV. Negative keeps a bright sky from blowing out signs.
    static let meteringPoint = CGPoint(x: 0.5, y: 0.4) // Upright frame, 0...1 from top-left: the road ahead, above the dash.
    static let videoHDR = true // Wider dynamic range: signs stay readable against a bright sky or in glare.
    static let settingsCheckSeconds = 2.0 // How often to check that iOS hasn't changed the settings back.

    // Night mode. The day settings above nearly black out the picture at night (a 10/20 night drive averaged 2-3 of 255
    // brightness and saw each stop sign in one frame). The camera's own light reading decides, not the clock: dusk,
    // tunnels and garages are dark at any hour. "Light need" = shutter time x ISO, the exposure the camera wants.
    static let nightMaxExposureSeconds = 1.0 / 30 // About 8x more light than day. Some motion blur; signs are reflective.
    static let nightExposureBias: Float = 0
    static let enterNightFraction = 0.8 // Day settings using >= 80% of their light capacity (shutter capped, ISO maxed)...
    static let exitNightFraction = 0.4 // ...back to day once day settings would need <= 40% of it. The gap stops flapping.
    static let switchSeconds = 3.0 // A condition must hold this long: a streetlight or oncoming headlights don't count.
}

// What the camera is doing on one analyzed frame, for the drive recording.
nonisolated struct CameraReading: Sendable {
    let iso: Float
    let exposureSeconds: Double
    let night: Bool
}

// One object the model saw, for the drive recorder (all classes we care about, at a low confidence).
struct RawObject: Sendable {
    let label: String
    let confidence: Float
    let box: CGRect // Vision coordinates: 0...1, origin at bottom-left.
    let redTint: Double? // Stop signs only: see SignColor.
}

// All camera and model work is serialized on one queue, away from the UI.
nonisolated final class DetectionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable { // Receives camera frames.
    let session = AVCaptureSession() // The camera session.
    var report: (@Sendable ([SignDetection], Double, String?) -> Void)? // Callback: boxes, ms, error.
    private let queue = DispatchQueue(label: "stopSign.detector") // Single background queue.
    private var request: VNCoreMLRequest? // The loaded model request.
    private var configured = false // True once camera is set up.
    private var rotation: CameraRotation? // Follows how the phone is physically held.
    private var videoWriter: VideoWriter? // Set while a test drive is recording; gets every camera frame.
    private var objectSink: (@Sendable (_ frameTime: Double, _ ms: Double, _ camera: CameraReading?, _ objects: [RawObject]) -> Void)?
    private var frameTime = 0.0 // Presentation time of the frame being analyzed, on the systemUptime clock.
    private static let loggedLabels: Set<String> = ["stop sign", "person", "car", "truck", "bus", "motorcycle", "bicycle", "traffic light"]
    private(set) var cameraSettingsNote = "not configured" // What applyDrivingSettings did, saved with recordings.
    var frameSize = CGSize(width: 720, height: 1280) // Size of the last upright live frame (portrait until a frame arrives).
    private var enabled = false // True while detection should run.
    private var lastRun = 0.0 // Time of last inference.
    private var threshold: Float = 0.4 // Minimum confidence.
    private var modelName = "yolo11n" // Bundle resource to load; DetectorDashboard sets it from Settings.
    private var camera: AVCaptureDevice? // Kept so the driving settings can be checked and re-applied.
    private var lastSettingsCheck = 0.0
    private var settingsRepairs = 0 // Times iOS had changed a setting and we put it back.
    private var sharpest: (frame: CMSampleBuffer, score: Double)? // Best frame since the last inference.
    private(set) var night = false // Night camera settings in use (see CameraTuning).
    private var lightConditionSince: Double? // When the condition for switching modes started to hold.

    private func loadModel() throws { // Load the YOLO model once.
        guard request == nil else { return } // Already loaded.
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else { // Find model in app bundle.
            throw NSError(domain: "Detector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(modelName) model. See TESTING.md for setup."]) // Model missing.
        }
        let configuration = MLModelConfiguration() // Model settings.
        configuration.computeUnits = .all // Allow CPU, GPU, Neural Engine.
        let model = try MLModel(contentsOf: url, configuration: configuration) // Load the model.
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model)) // Wrap it for Vision.
        request?.imageCropAndScaleOption = .scaleFill // Stretch frame to model input size.
    }

    func setModel(_ name: String) { // Takes effect for the next frame.
        queue.async { if name != self.modelName { self.modelName = name; self.request = nil } }
    }

    func start(threshold: Float) { // Start the camera and model.
        queue.async { // Run on the background queue.
            self.enabled = true // Allow processing.
            AVCaptureDevice.requestAccess(for: .video) { granted in // Ask for camera permission.
                self.queue.async { // Back to our queue.
                    guard self.enabled else { return } // Stopped while waiting.
                    guard granted else { self.fail("Camera permission denied. Enable it in Settings."); return } // User said no.
                    do {
                        self.threshold = threshold // Save confidence cutoff.
                        try self.loadModel() // Load model.
                        if !self.configured { try self.configureCamera() } // Set up camera once.
                        self.enabled = true // Make sure it's on.
                        self.lastRun = 0 // Run on the first frame.
                        self.sharpest = nil
                        self.night = false; self.lightConditionSince = nil // Each drive starts in day mode; it switches within seconds if dark.
                        self.session.startRunning() // Start streaming frames.
                        // Starting a session with a preset can reset focus and exposure, so apply them only now.
                        if let camera = self.camera { self.cameraSettingsNote = self.applyDrivingSettings(to: camera) }
                    } catch { self.fail(error.localizedDescription) } // Report any setup error.
                }
            }
        }
    }

    // Starts or stops feeding frames to a video writer and detections to the sink (both nil to stop).
    func setRecording(video: VideoWriter?, _ sink: (@Sendable (Double, Double, CameraReading?, [RawObject]) -> Void)?) {
        queue.async { self.videoWriter = video; self.objectSink = sink }
    }

    func stop() { // Stop the camera.
        queue.async { self.enabled = false; self.sharpest = nil; self.session.stopRunning() } // Disable and halt.
    }

    private func configureCamera() throws { // One-time camera setup.
        session.beginConfiguration() // Start batching changes.
        defer { session.commitConfiguration() } // Apply changes when done.
        session.sessionPreset = .hd1280x720 // 720p is enough for detection.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { // Get back camera.
            throw NSError(domain: "Detector", code: 2, userInfo: [NSLocalizedDescriptionKey: "No back camera. Use a photo in the simulator."]) // No camera (simulator).
        }
        let input = try AVCaptureDeviceInput(device: camera) // Camera as an input.
        let output = AVCaptureVideoDataOutput() // Output that delivers frames.
        guard session.canAddInput(input), session.canAddOutput(output) else { // Check they fit.
            throw NSError(domain: "Detector", code: 3, userInfo: [NSLocalizedDescriptionKey: "Camera configuration failed."]) // Setup failed.
        }
        session.addInput(input) // Attach the camera.
        output.alwaysDiscardsLateVideoFrames = true // Drop frames if we fall behind.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] // Use BGRA pixels.
        output.setSampleBufferDelegate(self, queue: queue) // Send frames to captureOutput.
        session.addOutput(output) // Attach the output.
        rotation = CameraRotation(device: camera) // Rotation is applied per frame.
        self.camera = camera // Driving settings are applied once the session is running.
        configured = true // Remember setup is done.
    }

    // Focus on the road (not the glass or dash), cap the shutter time, darken the exposure a little, meter on the
    // road ahead rather than the dark dashboard, and widen the dynamic range for glare.
    // Returns a short description of what was applied, for the recording's meta.json.
    private func applyDrivingSettings(to camera: AVCaptureDevice) -> String {
        var notes: [String] = []
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if CameraTuning.lockFocusFar, camera.isLockingFocusWithCustomLensPositionSupported {
                camera.setFocusModeLocked(lensPosition: CameraTuning.focusLensPosition)
                notes.append("focus locked at lens position \(CameraTuning.focusLensPosition)")
            } else {
                let farOnly = camera.isAutoFocusRangeRestrictionSupported
                if farOnly { camera.autoFocusRangeRestriction = .far } // Skips near distances: can't focus on the windshield.
                let aimed = camera.isFocusPointOfInterestSupported
                if aimed { camera.focusPointOfInterest = devicePoint(CameraTuning.meteringPoint) }
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                notes.append("continuous autofocus" + (farOnly ? ", far range only" : ", ANY range (far-only not supported)")
                             + (aimed ? ", on the road ahead" : ""))
            }

            // The limit must lie within what the current format supports.
            let limit = maxExposure(for: camera)
            camera.activeMaxExposureDuration = limit
            notes.append((night ? "NIGHT mode: " : "day mode: ") + String(format: "max exposure 1/%.0f s", 1 / CMTimeGetSeconds(limit)))

            let wantedBias = night ? CameraTuning.nightExposureBias : CameraTuning.exposureBias
            let bias = min(max(wantedBias, camera.minExposureTargetBias), camera.maxExposureTargetBias)
            camera.setExposureTargetBias(bias)
            notes.append(String(format: "exposure bias %+.1f EV", bias))

            // Without a point, exposure averages the whole frame, and a dark dashboard makes the road blow out.
            if camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposurePointOfInterest = devicePoint(CameraTuning.meteringPoint)
                camera.exposureMode = .continuousAutoExposure // Setting the point only takes effect with this.
                notes.append("exposure metered on the road ahead")
            }

            if CameraTuning.videoHDR, camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = true
                notes.append("video HDR on")
            } else {
                notes.append("video HDR not supported by this format")
            }
        } catch {
            notes.append("camera settings not applied: \(error.localizedDescription)")
        }
        return notes.joined(separator: "; ")
    }

    private func maxExposure(for camera: AVCaptureDevice, night: Bool? = nil) -> CMTime {
        let format = camera.activeFormat
        let seconds = (night ?? self.night) ? CameraTuning.nightMaxExposureSeconds : CameraTuning.maxExposureSeconds
        let wanted = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        return min(max(wanted, format.minExposureDuration), format.maxExposureDuration)
    }

    // Focus/exposure points use the sensor's own coordinates (landscape, home button on the right = rotation 0),
    // not the upright frame, so turn an upright point by the current rotation.
    private func devicePoint(_ upright: CGPoint) -> CGPoint {
        let (u, v) = (upright.x, upright.y)
        switch Int(rotation?.current() ?? 90) {
        case 90: return CGPoint(x: v, y: 1 - u) // Portrait.
        case 180: return CGPoint(x: 1 - u, y: 1 - v)
        case 270: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v) // 0: landscape, native.
        }
    }

    // Switches between day and night settings from how much light the camera needs (see CameraTuning).
    // Compares against what the DAY settings can deliver, so the same yardstick works in either mode.
    private func checkLight(_ camera: AVCaptureDevice, now: Double) {
        let iso = Double(camera.iso), shutter = CMTimeGetSeconds(camera.exposureDuration)
        guard iso > 0, shutter > 0 else { return }
        let currentBias = Double(night ? CameraTuning.nightExposureBias : CameraTuning.exposureBias)
        let needAtDayBias = iso * shutter * pow(2, Double(CameraTuning.exposureBias) - currentBias)
        let dayCapacity = Double(camera.activeFormat.maxISO) * CMTimeGetSeconds(maxExposure(for: camera, night: false))
        let used = needAtDayBias / dayCapacity // 1 = day settings flat out.
        let wantSwitch = night ? used <= CameraTuning.exitNightFraction : used >= CameraTuning.enterNightFraction
        guard wantSwitch else { lightConditionSince = nil; return }
        if lightConditionSince == nil { lightConditionSince = now }
        guard let since = lightConditionSince, now - since >= CameraTuning.switchSeconds else { return }
        night.toggle()
        lightConditionSince = nil
        cameraSettingsNote = applyDrivingSettings(to: camera) + String(format: "; switched at light use %.2f", used)
    }

    // iOS sometimes changes focus or exposure on its own (session restarts, format changes). Put them back.
    private func keepDrivingSettings(_ camera: AVCaptureDevice) {
        let point = devicePoint(CameraTuning.meteringPoint)
        let focusWrong = CameraTuning.lockFocusFar && camera.isLockingFocusWithCustomLensPositionSupported && !camera.isAdjustingFocus
            && (camera.focusMode != .locked || abs(camera.lensPosition - CameraTuning.focusLensPosition) > 0.02)
        let exposureWrong = camera.activeMaxExposureDuration > maxExposure(for: camera)
            || (camera.isExposurePointOfInterestSupported && hypot(camera.exposurePointOfInterest.x - point.x, camera.exposurePointOfInterest.y - point.y) > 0.01)
        guard focusWrong || exposureWrong else { return }
        settingsRepairs += 1
        cameraSettingsNote = applyDrivingSettings(to: camera) + "; re-applied \(settingsRepairs)x during the drive"
    }

    // How sharp a frame is: mean squared Laplacian of the green channel on a sparse grid over the middle of the
    // frame (the dash and sky have little detail). Blur smooths edges, so a blurry frame scores low. About 1 ms.
    private static func sharpness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        func green(_ x: Int, _ y: Int) -> Int { Int(pixels[y * row + x * 4 + 1]) } // BGRA.
        var total = 0, count = 0
        for y in stride(from: height / 5, to: height * 4 / 5, by: 4) {
            for x in stride(from: width / 5, to: width * 4 / 5, by: 4) {
                let laplacian = 4 * green(x, y) - green(x - 1, y) - green(x + 1, y) - green(x, y - 1) - green(x, y + 1)
                total += laplacian * laplacian
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    func analyze(_ image: CGImage, threshold: Float) { // Run the model on one still image.
        queue.async { // Background queue.
            self.threshold = threshold // Save confidence cutoff.
            do {
                try self.loadModel() // Make sure model is loaded.
                try self.perform(VNImageRequestHandler(cgImage: image, orientation: .up)) // Run detection.
            } catch { self.fail(error.localizedDescription) } // Report errors.
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { // Called per camera frame.
        guard enabled else { return } // Ignore if stopped.
        // Rotate frames so the scene is upright however the phone is held (portrait or either landscape).
        rotation?.apply(to: connection)
        videoWriter?.append(sampleBuffer) // Every frame, before the detection throttle below.
        let now = ProcessInfo.processInfo.systemUptime // Current time.
        if let camera, now - lastSettingsCheck >= CameraTuning.settingsCheckSeconds { lastSettingsCheck = now; keepDrivingSettings(camera) }
        if let camera { checkLight(camera, now: now) }
        // The camera delivers ~30 frames/s but we only analyze ~7. Of the frames in between, keep the sharpest,
        // so a bump that shakes one frame doesn't cost us the sign.
        guard let candidate = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let score = Self.sharpness(candidate)
        if score > sharpest?.score ?? -1 { sharpest = (sampleBuffer, score) } // Holds one buffer; the pool has spares.
        let hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical // Phone overheating?
        guard now - lastRun >= (hot ? 0.5 : 0.15), // Throttle: ~2 fps hot, ~7 fps normal.
              let chosen = sharpest?.frame, let buffer = CMSampleBufferGetImageBuffer(chosen) else { return } // Get the pixels.
        sharpest = nil
        lastRun = now // Record run time.
        frameTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(chosen)) // The chosen frame's own time, not now.
        frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) // Upright size, for drawing boxes.
        do { try perform(VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up), pixels: buffer) } // Run detection.
        catch { enabled = false; session.stopRunning(); fail(error.localizedDescription) } // On error, stop and report.
    }

    // Red-pixel share inside a box, read from the frame the model just saw. nil when there are no pixels (a photo or
    // test video frame) or the box is too small to judge.
    private static func redTint(in buffer: CVPixelBuffer?, box: CGRect) -> Double? {
        guard let buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return SignColor.redTintFraction(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(buffer),
                                         height: CVPixelBufferGetHeight(buffer), rowBytes: CVPixelBufferGetBytesPerRow(buffer), box: box)
    }

    private func perform(_ handler: VNImageRequestHandler, pixels: CVPixelBuffer? = nil) throws { // Run model and report results.
        guard let request else { return } // Need a loaded model.
        let start = ProcessInfo.processInfo.systemUptime // Start timer.
        try handler.perform([request]) // Run inference.
        guard let objects = request.results as? [VNRecognizedObjectObservation] else { // Expect object results.
            throw NSError(domain: "Detector", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected model output. Export with nms=True."]) // Wrong model export.
        }
        if let objectSink { // Test drive recording: log every relevant class, not just stop signs.
            let seen = objects.compactMap { object -> RawObject? in
                guard let label = object.labels.first, Self.loggedLabels.contains(label.identifier) else { return nil }
                let tint = label.identifier == "stop sign" ? Self.redTint(in: pixels, box: object.boundingBox) : nil
                return RawObject(label: label.identifier, confidence: label.confidence, box: object.boundingBox, redTint: tint)
            }
            let reading = camera.map { CameraReading(iso: $0.iso, exposureSeconds: CMTimeGetSeconds($0.exposureDuration), night: night) }
            objectSink(frameTime, (ProcessInfo.processInfo.systemUptime - start) * 1000, reading, seen)
        }
        let signs = objects.compactMap { object -> SignDetection? in // Keep only stop signs.
            guard let label = object.labels.first, label.identifier == "stop sign", label.confidence >= threshold else { return nil } // Must be a confident stop sign.
            return SignDetection(box: object.boundingBox, confidence: label.confidence,
                                 redTint: Self.redTint(in: pixels, box: object.boundingBox)) // Wrap the detection.
        }
        // The model fires on the backs of signs too (gray or white). Those, signs on the left (they are for other
        // traffic: see SignPosition), and the other signs at an all-way stop are ignored: only the closest (largest)
        // sign FRONT on your side counts.
        var ranked = signs
        let fronts = ranked.indices.filter { ranked[$0].isFront && SignPosition.isOnYourSide(box: ranked[$0].box) }
        if let closest = fronts.max(by: { ranked[$0].area < ranked[$1].area }) { ranked[closest].isPrimary = true }
        report?(ranked, (ProcessInfo.processInfo.systemUptime - start) * 1000, nil) // Send results + ms elapsed.
    }

    private func fail(_ message: String) { report?([], 0, message) } // Report an error to the UI.
}
