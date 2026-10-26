import SwiftUI
import PhotosUI
import AVFoundation

struct DebugView: View {
    @ObservedObject var detector: DetectorDashboard
    @State private var selection: PhotosPickerItem?
    @State private var videoSelection: PhotosPickerItem?
    @State private var importingVideo = false
    @State private var videoExpanded = true // Collapse to free room for the stats below.
    @StateObject private var inspector = VideoInspector()
    @StateObject private var motion = MotionService()
    @StateObject private var look = LookCheckService()
    @StateObject private var recorder = DriveRecorder()
    @State private var showingFaceVisualizer = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            // Landscape has little height: put the preview beside the options so both can scroll.
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                // Pinned in portrait: preview, readout, and video controls stay visible while scrubbing.
                if landscape {
                    ScrollView { pinnedPanel }.frame(width: geometry.size.width * 0.45)
                } else {
                    pinnedPanel
                }
                Divider()
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Model", selection: Binding(get: { detector.model }, set: { detector.select($0) })) {
                        ForEach(DetectorModel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).disabled(detector.running || detector.benchmarkStatus != nil)
                    VStack(alignment: .leading) {
                        Text("Confidence cutoff: \(Int(detector.threshold * 100))%")
                        Slider(value: $detector.threshold, in: 0.1...0.9, step: 0.05)
                            .disabled(detector.running)
                        Text("Set before testing. Confidence is a model score, not a measured accuracy rate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button(detector.running ? "Stop camera" : "Start camera", systemImage: detector.running ? "stop.fill" : "camera.fill") {
                            if detector.running { detector.stop() } else { inspector.pause(); detector.start() }
                        }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        PhotosPicker(selection: $selection, matching: .images) {
                            Label("Test photo", systemImage: "photo")
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 8) {
                        PhotosPicker(selection: $videoSelection, matching: .videos) {
                            Label("Test video", systemImage: "film")
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        Button("Video file…", systemImage: "folder") { importingVideo = true }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                    recordSection
                    performanceSection
                    motionSection
                    lookSection
                    if let error = inspector.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("Prototype only • Detects signs, not rolling stops or distance. Test as a passenger or while stationary.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                }
            }
            }
            .onAppear {
                #if DEBUG
                // Lets the simulator exercise the photo path without a physical camera.
                if let path = ProcessInfo.processInfo.environment["STOP_SIGN_TEST_PHOTO"],
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    detector.analyze(data)
                }
                #endif
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self) { detector.analyze(data) }
                    } catch { detector.status = "Could not load photo: \(error.localizedDescription)" }
                    selection = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                if recorder.recording { Task { await recorder.stop(detector: detector, motion: motion) } } // The camera can't run in the background.
                else { detector.stop() }
            }
            .interactiveDismissDisabled(recorder.recording) // No accidental swipe-away mid-drive.
            .onDisappear { inspector.pause(); if !recorder.recording { detector.stop() }; look.stop() }
            .fullScreenCover(isPresented: $showingFaceVisualizer) {
                FaceVisualizer(look: look) { showingFaceVisualizer = false }
            }
            .onAppear { inspector.onFrame = { detector.show(frame: $0) } }
            .onChange(of: videoSelection) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                            detector.stop(); detector.reset()
                            await inspector.load(movie.url)
                        }
                    } catch { inspector.error = "Could not load video: \(error.localizedDescription)" }
                    videoSelection = nil
                }
            }
            .fileImporter(isPresented: $importingVideo, allowedContentTypes: [.movie]) { result in
                guard case .success(let url) = result else { return }
                Task { detector.stop(); detector.reset(); await inspector.loadFromFiles(url) }
            }
        }
    }

    private var thermalLabel: (text: String, color: Color) {
        switch detector.thermal {
        case .nominal: return ("Nominal", .green)
        case .fair: return ("Fair", .yellow)
        case .serious: return ("Serious", .orange)
        case .critical: return ("Critical", .red)
        @unknown default: return ("Unknown", .secondary)
        }
    }

    private func thermalName(_ raw: Int) -> String { ["Nominal", "Fair", "Serious", "Critical"][min(max(raw, 0), 3)] }

    private var pinnedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            Label(detector.status, systemImage: detector.boxes.isEmpty ? "viewfinder" : "checkmark.circle.fill")
                .font(.headline).foregroundStyle(detector.boxes.isEmpty ? Color.primary : .green)
            HStack {
                metric("Inference", "\(Int(detector.milliseconds)) ms")
                Spacer()
                metric("Frames tested", "\(detector.analyzed)")
                Spacer()
                metric("With a sign", "\(detector.hits)")
            }
            if inspector.hasVideo { videoControls }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECORD TEST DRIVE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Button {
                if recorder.recording {
                    Task { await recorder.stop(detector: detector, motion: motion) }
                } else {
                    look.stop() // The front camera can't run alongside the back one here.
                    recorder.start(detector: detector, motion: motion)
                }
            } label: {
                Label(recorder.recording ? "Stop recording" : "Start recording", systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(recorder.recording ? .gray : .red)
            Text(recorder.recording ? "\(recorder.status) · \(timeString(recorder.elapsed)) · \(recorder.markCount) marks" : recorder.status)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if recorder.recording {
                // Big targets for the passenger: tap right after the thing happens.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(DriveRecorder.presetMarks, id: \.self) { name in
                        Button(name) { recorder.mark(name) }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 56)
                    }
                }
                if let mark = recorder.lastMark { Text("Last mark: \(mark)").font(.caption).foregroundStyle(.green) }
            }
            if let drive = recorder.last, !recorder.recording {
                Text("Saved \(timeString(drive.duration)) · \(drive.rows) rows · \(drive.frames) video frames\(drive.dropped > 0 ? " (\(drive.dropped) dropped)" : "")\nFiles app > On My iPhone > this app > Drives > \(drive.folder.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
                ShareLink(items: drive.shareItems) { Label("Share files", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            Text("Saves the back-camera video and a sensors CSV on one clock. Stays on this phone until you share it. Passenger operates the phone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOOK BOTH WAYS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(look.running ? "Stop front camera" : "Start front camera", systemImage: "person.crop.square") {
                    if look.running { look.stop() } else { detector.stop(); look.start() } // Back and front cameras can't both run here.
                }.buttonStyle(.bordered)
                Button("Calibrate", systemImage: "scope") { look.calibrate() }
                    .buttonStyle(.bordered).disabled(!look.running || look.calibrationStep != nil)
                Button("New stop", systemImage: "arrow.counterclockwise") { look.resetCheck() }
                    .buttonStyle(.bordered).disabled(look.detector == nil)
            }
            Button("Face visualizer", systemImage: "face.dashed") { detector.stop(); showingFaceVisualizer = true }
                .buttonStyle(.borderedProminent)
            Text(look.calibrationStep?.rawValue ?? look.status).font(.caption).foregroundStyle(.secondary)
            if !look.cameraInfo.isEmpty { Text("Front camera: \(look.cameraInfo)").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                metric("Yaw", look.yawDegrees.map { String(format: "%+.0f°", $0) } ?? "no face")
                Spacer()
                metric("From straight (+ = left)", look.detector?.deviation.map { String(format: "%+.0f°", $0) } ?? "–")
            }
            if let detector = look.detector {
                HStack(spacing: 16) {
                    Label("Left", systemImage: detector.leftSeen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(detector.leftSeen ? .green : .secondary)
                    Label("Right", systemImage: detector.rightSeen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(detector.rightSeen ? .green : .secondary)
                    if detector.passed { Text("PASSED").bold().foregroundStyle(.green) }
                }
            }
        }
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOTION").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Button(motion.running ? "Stop motion" : "Start motion", systemImage: "gauge.with.dots.needle.67percent") {
                if motion.running { motion.stop() } else { motion.start() }
            }.buttonStyle(.bordered)
            Text(motion.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                metric("Speed", motion.speed.map { String(format: "%.1f m/s", $0) } ?? "–")
                Spacer()
                metric("Forward", String(format: "%+.2f g", motion.forwardAccel))
                Spacer()
                metric("GPS agrees", motion.sensorsAgree ? "yes" : "no")
            }
            ForEach(motion.events.suffix(5).reversed()) { event in
                Text("\(event.kind == .hardBrake ? "Hard brake" : "Hard accel") \(String(format: "%+.2f g", event.accel))")
                    .font(.caption).monospacedDigit()
            }
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERFORMANCE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack {
                Text("Thermal state:")
                Text(thermalLabel.text).bold().foregroundStyle(thermalLabel.color)
                Spacer()
                if detector.running { Text(String(format: "%.1f fps", detector.fps)).monospacedDigit() }
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Text("Low Power Mode is on; iOS may slow the model.").font(.caption).foregroundStyle(.orange)
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Frames"); Text("Hit %"); Text("Conf"); Text("Avg ms"); Text("Max ms"); Text("Heat")
                }.font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                ForEach(DetectorModel.allCases) { model in
                    let entry = detector.stats[model] ?? ModelStats()
                    GridRow {
                        Text(model.label).gridColumnAlignment(.leading)
                        Text("\(entry.frames)")
                        Text(entry.frames > 0 ? "\(Int((entry.hitRate * 100).rounded()))" : "–")
                        Text(entry.hits > 0 ? "\(Int((entry.avgConfidence * 100).rounded()))" : "–")
                        Text(entry.frames > 0 ? "\(Int(entry.avgMs.rounded()))" : "–")
                        Text(entry.frames > 0 ? "\(Int(entry.maxMs.rounded()))" : "–")
                        Text(entry.frames > 0 ? String(thermalName(entry.worstThermal).prefix(4)) : "–")
                    }.font(.caption.monospacedDigit())
                }
            }
            if let progress = detector.benchmarkStatus {
                Text("Benchmarking… \(progress)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Benchmark video", systemImage: "speedometer") { Task { await detector.benchmark(inspector) } }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(!inspector.hasVideo || detector.running || detector.benchmarkStatus != nil)
                Button("Reset stats", systemImage: "arrow.counterclockwise") { detector.resetStats() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(detector.benchmarkStatus != nil)
            }
            Text("Hit % = frames with a stop sign, not accuracy: it needs ground truth, and extra boxes count as hits. Heat = worst iOS thermal state seen (iOS gives no temperature). Short runs won't heat the phone; use live camera for 10 min per model.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { videoExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(videoExpanded ? 90 : 0))
                    Text(inspector.name).font(.caption.weight(.bold)).lineLimit(1)
                    Spacer()
                    if !videoExpanded {
                        Text("\(timeString(inspector.time)) · frame \(inspector.frameIndex)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if videoExpanded { videoBody }
        }
    }

    @ViewBuilder private var videoBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source \(Int(inspector.sourceSize.width))×\(Int(inspector.sourceSize.height)) → decoded \(Int(inspector.frameSize.width))×\(Int(inspector.frameSize.height)) → model input \(detector.model.label.components(separatedBy: " · ").last ?? "")")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Slider(value: Binding(
                get: { inspector.time },
                set: { value in inspector.pause(); Task { await inspector.seek(to: value) } }
            ), in: 0...max(inspector.duration, 0.01))
            HStack {
                Text("\(timeString(inspector.time)) / \(timeString(inspector.duration))")
                Spacer()
                Text("frame \(inspector.frameIndex)")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { Task { await inspector.step(-10) } } label: { Image(systemName: "gobackward.10").frame(maxWidth: .infinity) }
                Button { Task { await inspector.step(-1) } } label: { Image(systemName: "backward.frame.fill").frame(maxWidth: .infinity) }
                Button { inspector.togglePlay() } label: { Image(systemName: inspector.playing ? "pause.fill" : "play.fill").frame(maxWidth: .infinity) }
                Button { Task { await inspector.step(1) } } label: { Image(systemName: "forward.frame.fill").frame(maxWidth: .infinity) }
                Button { Task { await inspector.step(10) } } label: { Image(systemName: "goforward.10").frame(maxWidth: .infinity) }
            }.font(.title3).buttonStyle(.bordered)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let source = detector.photo?.size ?? detector.liveFrameSize
            let scale = min(geometry.size.width / source.width, geometry.size.height / source.height)
            let fitted = CGSize(width: source.width * scale, height: source.height * scale)
            ZStack {
                Color.black
                ZStack {
                    if let photo = detector.photo {
                        Image(uiImage: photo).resizable().scaledToFit()
                    } else {
                        CameraPreview(session: detector.engine.session)
                        if !detector.running {
                            Label("Camera preview", systemImage: "camera.viewfinder").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    ForEach(detector.boxes) { detection in
                        let box = detection.box
                        Rectangle().stroke(detection.isPrimary ? .green : .orange, lineWidth: detection.isPrimary ? 3 : 2)
                            .overlay(alignment: .topLeading) {
                                Text("\(detection.isPrimary ? "STOP" : (detection.isFront ? "ignored" : "back?")) \(Int(detection.confidence * 100))%")
                                    .font(.caption2.bold()).padding(3).background(detection.isPrimary ? .green : .orange).foregroundStyle(.black)
                                    .fixedSize().offset(y: -22)
                            }
                            .frame(width: box.width * fitted.width, height: box.height * fitted.height)
                            .position(x: box.midX * fitted.width, y: (1 - box.midY) * fitted.height)
                    }
                }.frame(width: fitted.width, height: fitted.height)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }.frame(height: 260)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.updateRotation() }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var rotation: AVCaptureDevice.RotationCoordinator?
    override func layoutSubviews() { super.layoutSubviews(); updateRotation() }

    // Keeps the preview upright when the phone is turned. The camera only exists once the session is set up.
    func updateRotation() {
        if rotation == nil, let device = (layerView.session?.inputs.first as? AVCaptureDeviceInput)?.device {
            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layerView)
        }
        guard let rotation, let connection = layerView.connection else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}
