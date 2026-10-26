import SwiftUI

// Debug only: full-screen front camera with Vision's face box, landmarks, and head yaw drawn on top.
struct FaceVisualizer: View {
    @ObservedObject var look: LookCheckService
    var close: () -> Void
    @State private var selfieView = true // Mirror the picture so left on screen is your left.
    @State private var showLandmarks = true
    @State private var startedHere = false

    var body: some View {
        VStack(spacing: 0) {
            FacePreview(look: look, selfieView: selfieView, showLandmarks: showLandmarks)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.largeTitle) }
                    .padding().foregroundStyle(.white.opacity(0.8))
            }
            controls
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            if !look.running { look.start(); startedHere = true }
        }
        .onDisappear {
            if startedHere { look.stop() }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            gauge
            HStack {
                Text(look.calibrationStep?.rawValue ?? look.status).font(.subheadline.bold())
                if !look.cameraInfo.isEmpty { Text("Front camera: \(look.cameraInfo)").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                Spacer()
                if let detector = look.detector {
                    Label("L", systemImage: detector.leftSeen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(detector.leftSeen ? .green : .secondary)
                    Label("R", systemImage: detector.rightSeen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(detector.rightSeen ? .green : .secondary)
                    if detector.passed { Text("PASSED").bold().foregroundStyle(.green) }
                }
            }
            HStack(spacing: 8) {
                Button("Calibrate", systemImage: "scope") { look.calibrate() }
                    .disabled(!look.running || look.calibrationStep != nil)
                Button("New stop", systemImage: "arrow.counterclockwise") { look.resetCheck() }
                    .disabled(look.detector == nil)
                Toggle("Mirror", isOn: $selfieView).toggleStyle(.button)
                Toggle("Points", isOn: $showLandmarks).toggleStyle(.button)
            }
            .buttonStyle(.bordered).labelStyle(.titleOnly).font(.footnote)
        }
        .padding()
        .background(.black)
    }

    // Head turn from straight, with the calibrated thresholds as ticks. Left is on the left.
    private var gauge: some View {
        let limit = 60.0
        let value = look.detector?.deviation // + = driver's left.
        return VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = { (deviation: Double) -> CGFloat in width * (0.5 - CGFloat(max(-limit, min(limit, deviation)) / (2 * limit))) } // + = left side.
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15)).frame(height: 10).frame(maxHeight: .infinity)
                    if let calibration = look.calibration {
                        Rectangle().fill(.green).frame(width: 2, height: 22).position(x: x(calibration.leftThreshold), y: geometry.size.height / 2)
                        Rectangle().fill(.green).frame(width: 2, height: 22).position(x: x(-calibration.rightThreshold), y: geometry.size.height / 2)
                    }
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 2, height: 22).position(x: width / 2, y: geometry.size.height / 2)
                    if let value {
                        Circle().fill(.orange).frame(width: 18, height: 18).position(x: x(value), y: geometry.size.height / 2)
                    }
                }
            }
            .frame(height: 24)
            HStack {
                Text("LEFT"); Spacer()
                Text(value.map { String(format: "%+.0f° from straight", $0) } ?? "Calibrate to see the gauge").monospacedDigit()
                Spacer(); Text("RIGHT")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// The front camera picture with Vision's face box, landmarks, yaw and head-turn pointer drawn on top. Used by the Debug
// face screen and, while the front camera runs, by the Driving screen (to see if the face is clipping off the edge).
// Does not start the camera; it only shows frames while it is on screen.
struct FacePreview: View {
    @ObservedObject var look: LookCheckService
    var selfieView = true // Mirror the picture so left on screen is your left.
    var showLandmarks = true
    @State private var frame: FaceFrame?

    var body: some View {
        ZStack {
            Color.black
            if let frame, let image = frame.image {
                let flip = selfieView != frame.bufferMirrored
                let aspect = CGFloat(image.width) / CGFloat(image.height)
                ZStack {
                    Image(decorative: image, scale: 1).resizable().scaleEffect(x: flip ? -1 : 1, y: 1)
                    Canvas { context, size in draw(frame, flip: flip, in: &context, size: size) }
                }
                .aspectRatio(aspect, contentMode: .fit)
            } else {
                Text(look.status).foregroundStyle(.white.opacity(0.6))
            }
        }
        .onAppear { look.observeFrames { frame = $0 } }
        .onDisappear { look.observeFrames(nil) }
    }

    // Vision points are 0...1 with the origin at the bottom-left.
    private func place(_ p: CGPoint, flip: Bool, _ size: CGSize) -> CGPoint {
        CGPoint(x: (flip ? 1 - p.x : p.x) * size.width, y: (1 - p.y) * size.height)
    }

    private func draw(_ frame: FaceFrame, flip: Bool, in context: inout GraphicsContext, size: CGSize) {
        for face in frame.faces {
            let color: Color = face.isPrimary ? .green : .gray
            let corners = [CGPoint(x: face.box.minX, y: face.box.minY), CGPoint(x: face.box.maxX, y: face.box.maxY)].map { place($0, flip: flip, size) }
            let rect = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                              width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color), lineWidth: face.isPrimary ? 3 : 2)

            let label = [
                face.isPrimary ? "DRIVER" : "ignored",
                face.yaw.map { String(format: "yaw %+.0f°", $0) } ?? "yaw –",
                face.pitch.map { String(format: "pitch %+.0f°", $0) } ?? "pitch –",
                face.roll.map { String(format: "roll %+.0f°", $0) } ?? "roll –",
                String(format: "conf %.0f%%", face.confidence * 100),
            ].joined(separator: "  ")
            context.draw(Text(label).font(.caption.monospacedDigit().bold()).foregroundStyle(color), at: CGPoint(x: rect.minX, y: max(rect.minY - 10, 10)), anchor: .leading)

            guard showLandmarks else { continue }
            for outline in face.outlines where outline.count > 1 {
                var path = Path()
                path.addLines(outline.map { place($0, flip: flip, size) })
                context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
            }
            for loop in face.loops where loop.count > 1 {
                var path = Path()
                path.addLines(loop.map { place($0, flip: flip, size) })
                path.closeSubpath()
                context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
            }
            for pupil in face.pupils {
                let p = place(pupil, flip: flip, size)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.red))
            }
            drawHeadPointer(face, rect: rect, flip: flip, in: &context, size: size)
        }
    }

    // A line out of the nose toward where the head is turned. Needs calibration to know which yaw sign is left.
    private func drawHeadPointer(_ face: FaceOverlay, rect: CGRect, flip: Bool, in context: inout GraphicsContext, size: CGSize) {
        guard face.isPrimary, let yaw = face.yaw, let calibration = look.calibration,
              let nose = face.outlines.dropFirst(3).first(where: { !$0.isEmpty }) else { return }
        let deviation = (yaw - calibration.straight) * calibration.leftSign // + = driver's left.
        let selfieShown = selfieView // The shown picture is selfie-like when we mirrored it or it already was.
        let direction: CGFloat = selfieShown ? -1 : 1 // Driver's left is the screen's left only in a selfie view.
        let centre = nose.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / CGFloat(nose.count), y: $0.y + $1.y / CGFloat(nose.count)) }
        let start = place(centre, flip: flip, size)
        let length = rect.width * 1.2 * CGFloat(sin(deviation * .pi / 180))
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x + direction * length, y: start.y))
        context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }
}
