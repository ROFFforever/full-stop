import SwiftUI
import AVFoundation // AVPlayer, the video asset.
import Combine // ObservableObject/@Published.

// Drive review: plays a saved drive's video from a report-card moment (a stop sign, a hard brake), so the driver can
// see what happened. Works in portrait (video on top, moments below) and landscape (video left, moments right).
// Optionally draws the model's stop sign boxes on the video (a testing feature: see ReviewOverlay at the bottom).

// One report-card item the video can jump to.
struct ReviewMoment: Identifiable, Equatable {
    let id: Int
    let title: String
    let icon: String
    let color: Color
    let driveSeconds: Double // When the report card says it happened (seconds into the drive).
    let kind: Kind
    enum Kind { case stopSign, brake }

    // Every moment on a report card, in drive order.
    static func all(in drive: DriveSummary) -> [ReviewMoment] {
        var moments: [ReviewMoment] = []
        for sign in drive.stopSigns {
            moments.append(.init(id: moments.count, title: ReportCardView.label(sign), icon: ReportCardView.icon(sign.outcome),
                                 color: ReportCardView.color(sign.outcome), driveSeconds: sign.secondsIntoDrive, kind: .stopSign))
        }
        for brake in drive.hardBrakes {
            moments.append(.init(id: moments.count, title: String(format: "Hard brake (%.2f g)", abs(brake.g)),
                                 icon: "exclamationmark.triangle.fill", color: .orange, driveSeconds: brake.secondsIntoDrive, kind: .brake))
        }
        return moments.sorted { $0.driveSeconds < $1.driveSeconds }
    }
}

// What the screen needs from a recording folder: the video, how report-card times map onto it, and the logged stop
// sign boxes. Read off the main thread (sensors.csv is tens of MB).
nonisolated struct DriveRecording: Sendable {
    struct SignBox: Sendable {
        let box: CGRect // Vision coordinates: 0...1, origin bottom-left, in the upright video frame.
        let confidence: Double
        let counted: Bool // Passed the color and position filters (the coach would use it).
    }

    let video: URL
    let driveToVideo: Double // video seconds = drive seconds + this.
    let frameTimes: [Double] // Video seconds of every analyzed frame, sorted.
    let signs: [Int: [SignBox]] // Index into frameTimes -> stop sign boxes on that frame.
    let approachStarts: [Double] // Video seconds where the coach first saw a sign ("-> signCandidate").

    // Folder of a saved drive: Documents/Drives/<name>. An absolute path is used as is (simulator testing).
    static func folder(for drive: DriveSummary) -> URL? {
        guard let name = drive.recordingFolder else { return nil }
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Drives").appendingPathComponent(name)
    }

    static func hasVideo(_ drive: DriveSummary) -> Bool {
        guard let folder = folder(for: drive) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mov").path)
    }

    static func load(_ drive: DriveSummary) throws -> DriveRecording {
        guard let folder = folder(for: drive) else { throw ReviewError("This drive has no saved video.") }
        let video = folder.appendingPathComponent("video.mov")
        guard FileManager.default.fileExists(atPath: video.path) else { throw ReviewError("This drive's video was not saved.") }
        let metaData = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let startT = meta["start_t"] as? Double, let startUnix = meta["start_unix"] as? Double,
              let videoStartT = meta["video_start_t"] as? Double else { throw ReviewError("This drive's video has no timing info.") }

        // Report-card times count from Start drive; recording starts after the head-turn setup (~10-15 s later).
        // Both clocks tick together, so the wall-clock gap between the two starts is that delay.
        var delay = startUnix - drive.start.timeIntervalSince1970
        if delay < 0 || delay > 120 { delay = 0 } // Not a plausible setup time (e.g. a made-up test drive).
        let uptimeToVideo = -videoStartT // video seconds = uptime - video_start_t.
        let driveToVideo = startT - delay - videoStartT // drive seconds -> uptime -> video seconds.

        var frameTimes: [Double] = []
        var signs: [Int: [SignBox]] = [:]
        var approachStarts: [Double] = []
        let text = try String(contentsOf: folder.appendingPathComponent("sensors.csv"), encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let header = lines.next() else { return .init(video: video, driveToVideo: driveToVideo, frameTimes: [], signs: [:], approachStarts: []) }
        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }
        let label = column("label"), conf = column("conf"), red = column("red")
        let bx = column("bx"), by = column("by"), bw = column("bw"), bh = column("bh")

        while let line = lines.next() {
            // Cheap kind check before splitting: the kind is the second field.
            guard let comma = line.firstIndex(of: ",") else { continue }
            let rest = line[line.index(after: comma)...]
            if rest.hasPrefix("frame,") {
                guard let t = Double(line[..<comma]) else { continue }
                frameTimes.append(t + uptimeToVideo)
            } else if rest.hasPrefix("det,") && line.contains(",stop sign,") {
                let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                func value(_ i: Int?) -> Double? { i.flatMap { $0 < cells.count ? Double(cells[$0]) : nil } }
                guard let label, label < cells.count, cells[label] == "stop sign", let t = Double(cells[0]),
                      let x = value(bx), let y = value(by), let w = value(bw), let h = value(bh) else { continue }
                let box = CGRect(x: x, y: y, width: w, height: h)
                let tint = value(red)
                let counted = (tint.map { $0 >= SignColor.minRedTint } ?? true) && SignPosition.isOnYourSide(box: box)
                // Detections share their frame row's time; frame rows are written first, so it's the last one.
                let videoT = t + uptimeToVideo
                if frameTimes.last.map({ abs($0 - videoT) > 0.0001 }) ?? true { frameTimes.append(videoT) } // Older files.
                signs[frameTimes.count - 1, default: []].append(.init(box: box, confidence: value(conf) ?? 0, counted: counted))
            } else if rest.hasPrefix("coach,"), line.hasSuffix("-> signCandidate"), let t = Double(line[..<comma]) {
                approachStarts.append(t + uptimeToVideo)
            }
        }
        return .init(video: video, driveToVideo: driveToVideo, frameTimes: frameTimes, signs: signs, approachStarts: approachStarts)
    }

    // Where to start playing for a moment: a stop sign from when the coach first saw it (a little before),
    // a hard brake a few seconds early so the lead-up is visible.
    func startTime(for moment: ReviewMoment) -> Double {
        let at = moment.driveSeconds + driveToVideo
        switch moment.kind {
        case .brake:
            return max(0, at - 5)
        case .stopSign: // The report-card time is when the stop was graded, a few seconds after leaving it.
            if let seen = approachStarts.last(where: { $0 < at && $0 > at - 60 }) { return max(0, seen - 2) }
            return max(0, at - 15)
        }
    }

    // Stop sign boxes on the analyzed frame showing at `time`, or nil if no frame was analyzed recently
    // (the back camera is off while the front camera watches the driver's head at a stop).
    func boxes(at time: Double) -> [SignBox]? {
        var low = 0, high = frameTimes.count // First frame after `time`.
        while low < high { let mid = (low + high) / 2; if frameTimes[mid] <= time { low = mid + 1 } else { high = mid } }
        let index = low - 1
        guard index >= 0, time - frameTimes[index] < 0.5 else { return nil }
        return signs[index] ?? []
    }
}

nonisolated struct ReviewError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

// The player and its clock, for the SwiftUI controls.
@MainActor
final class ReviewPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var time = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published var rate: Float = 1 { didSet { if playing { player.rate = rate } } }
    private var observer: Any?

    func load(_ url: URL, at start: Double) async {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player.replaceCurrentItem(with: item)
        duration = (try? await item.asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = CMTimeGetSeconds(now)
                self.playing = self.player.rate != 0
            }
        }
        await seek(start, exact: true)
        play()
    }

    func play() {
        if duration > 0, time >= duration - 0.1 { Task { await seek(0, exact: true) } }
        player.rate = rate
        playing = true
    }
    func pause() { player.pause(); playing = false }
    func toggle() { playing ? pause() : play() }

    // exact = frame-accurate (slower); scrubbing uses loose seeks so it keeps up with the finger.
    func seek(_ seconds: Double, exact: Bool) async {
        let target = min(max(seconds, 0), max(duration, 0))
        time = target
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 4)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct DriveReviewView: View {
    let drive: DriveSummary
    let startMoment: ReviewMoment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = ReviewPlayer()
    @State private var recording: DriveRecording?
    @State private var error: String?
    @State private var current: ReviewMoment?
    private let showBoxes = false

    private var moments: [ReviewMoment] { ReviewMoment.all(in: drive) }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let error {
                    VStack {
                        topBar(landscape: landscape)
                        ContentUnavailableView("Can't play this drive", systemImage: "video.slash", description: Text(error))
                            .foregroundStyle(.white)
                    }
                } else if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 8) { topBar(landscape: true); video; controls }
                            .padding(.vertical, 8)
                        momentList.frame(width: min(300, geometry.size.width * 0.34))
                    }
                } else {
                    VStack(spacing: 10) {
                        topBar(landscape: false)
                        video
                        controls.padding(.horizontal)
                        momentList
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await open() }
        .onDisappear { player.stop() }
    }

    private func open() async {
        current = startMoment
        do {
            let drive = drive
            let loaded = try await Task.detached(priority: .userInitiated) { try DriveRecording.load(drive) }.value
            recording = loaded
            await player.load(loaded.video, at: loaded.startTime(for: startMoment))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func jump(to moment: ReviewMoment) {
        guard let recording else { return }
        current = moment
        Task { await player.seek(recording.startTime(for: moment), exact: true); player.play() }
    }

    // MARK: Pieces

    private func topBar(landscape: Bool) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            if let current {
                Label(current.title, systemImage: current.icon)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, landscape ? 0 : 4)
    }

    private var video: some View {
        PlayerLayerView(player: player.player)
            .overlay {
                if showBoxes, let recording, let size = player.player.currentItem?.presentationSize, size.width > 0 {
                    ReviewOverlay(boxes: recording.boxes(at: player.time), videoSize: size)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { player.toggle() }
            .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Scrubber(time: player.time, duration: player.duration,
                     ticks: recording.map { r in moments.map { ($0.driveSeconds + r.driveToVideo, $0.color) } } ?? [],
                     onScrub: { t in player.pause(); Task { await player.seek(t, exact: false) } },
                     onEnd: { t in Task { await player.seek(t, exact: true) } })
            HStack {
                Text(ReportCardView.clock(max(0, player.time - (recording?.driveToVideo ?? 0)))).monospacedDigit() // Drive time, like the list.
                Spacer()
                Button { Task { await player.seek(player.time - 5, exact: true) } } label: { Image(systemName: "gobackward.5") }
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title) }
                    .frame(width: 60)
                Button { Task { await player.seek(player.time + 5, exact: true) } } label: { Image(systemName: "goforward.5") }
                Spacer()
                Button(player.rate == 1 ? "1×" : "½×") { player.rate = player.rate == 1 ? 0.5 : 1 }
                    .monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
            .font(.title3)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
    }

    private var momentList: some View {
        List(moments) { moment in
            Button { jump(to: moment) } label: {
                HStack {
                    Image(systemName: moment.icon).foregroundStyle(moment.color)
                    Text(moment.title).foregroundStyle(.primary)
                    Spacer()
                    Text(ReportCardView.clock(moment.driveSeconds)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .listRowBackground(moment == current ? Color.white.opacity(0.15) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// A timeline with a colored tick at each report-card moment. Drag anywhere to scrub.
private struct Scrubber: View {
    let time: Double
    let duration: Double
    let ticks: [(Double, Color)]
    let onScrub: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(.white).frame(width: width * fraction, height: 4)
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    if duration > 0 {
                        Capsule().fill(tick.1).frame(width: 3, height: 14)
                            .offset(x: width * min(max(tick.0 / duration, 0), 1) - 1.5)
                    }
                }
                Circle().fill(.white).frame(width: 16, height: 16).offset(x: width * fraction - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onScrub(seconds(at: $0.location.x, width: width)) }
                .onEnded { onEnd(seconds(at: $0.location.x, width: width)) })
        }
        .frame(height: 28)
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}

// AVPlayerLayer in SwiftUI, fitted inside its frame (no cropping), with no built-in controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {}
}

// MARK: - Testing feature: stop sign boxes on the video
// To remove: delete this struct, the `.overlay` in DriveReviewView.video, the box button in topBar, and
// AppSettings.reviewBoxesKey (+ its Settings toggle).

// Draws the stop sign boxes the model found on that frame. Solid red = counted by the coach; dashed gray = rejected
// (back of a sign, or a sign on the left for cross traffic).
private struct ReviewOverlay: View {
    let boxes: [DriveRecording.SignBox]?
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let frame = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geometry.size))
            ForEach(Array((boxes ?? []).enumerated()), id: \.offset) { _, sign in
                let rect = CGRect(x: frame.minX + sign.box.minX * frame.width,
                                  y: frame.minY + (1 - sign.box.maxY) * frame.height, // Vision's origin is bottom-left.
                                  width: sign.box.width * frame.width, height: sign.box.height * frame.height)
                Rectangle()
                    .stroke(sign.counted ? Color.red : Color.gray,
                            style: StrokeStyle(lineWidth: 2, dash: sign.counted ? [] : [4, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%.0f%%", sign.confidence * 100))
                            .font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .padding(.horizontal, 3)
                            .background(sign.counted ? Color.red : Color.gray)
                            .foregroundStyle(.white)
                            .fixedSize()
                            .offset(y: -14)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
            if boxes == nil { // Back camera off here (front camera watching the head check): no detections.
                Text("No detections here (camera off for the head check)").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .position(x: frame.midX, y: frame.maxY - 12)
            }
        }
        .allowsHitTesting(false)
    }
}
