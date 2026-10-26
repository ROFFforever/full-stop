import AVFoundation // Reads frames out of a video file.
import Combine // ObservableObject/@Published.
import CoreTransferable // Lets PhotosPicker hand us a movie file.
import UniformTypeIdentifiers // .movie content type.

// A movie picked from Photos, copied to a temp file we own.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            PickedMovie(url: try VideoInspector.copyToTemp(received.file))
        }
    }
}

// Steps through a video one frame at a time and hands each frame to the detector.
@MainActor
final class VideoInspector: ObservableObject {
    @Published var hasVideo = false
    @Published var name = ""
    @Published var time = 0.0 // Current position, seconds.
    @Published var duration = 0.0
    @Published var playing = false
    @Published var sourceSize = CGSize.zero // Size in the file (after rotation).
    @Published var frameSize = CGSize.zero // Size after downscaling.
    @Published var error: String?
    var onFrame: ((CGImage) -> Void)? // Receives each decoded, downscaled frame.
    private(set) var fps = 30.0
    private var generator: AVAssetImageGenerator?
    private var playTask: Task<Void, Never>?
    private var latestRequest = 0 // Lets us drop results from superseded seeks.
    static let maxDimension: CGFloat = 1280 // Longest side we decode to; Vision then fits the model's 640x640.

    var frameIndex: Int { Int((time * fps).rounded()) }

    nonisolated static func copyToTemp(_ source: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // Open a file chosen with the Files picker (needs security-scoped access).
    func loadFromFiles(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { await load(try Self.copyToTemp(url)) }
        catch { self.error = "Could not open video: \(error.localizedDescription)" }
    }

    func load(_ url: URL) async {
        pause()
        error = nil
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                error = "No video track. AVFoundation can't read .avi; convert to .mp4 or .mov first."
                return
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rate = try await track.load(.nominalFrameRate)
            duration = try await asset.load(.duration).seconds
            fps = rate > 0 ? Double(rate) : 30
            let oriented = natural.applying(transform)
            sourceSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true // Upright phone footage.
            generator.requestedTimeToleranceBefore = .zero // Exact frames, not nearest keyframe.
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: Self.maxDimension, height: Self.maxDimension) // Aspect preserved.
            self.generator = generator
            name = url.lastPathComponent
            hasVideo = true
            await seek(to: 0)
        } catch {
            self.error = "Could not open video: \(error.localizedDescription)"
        }
    }

    func seek(to seconds: Double) async {
        guard let generator else { return }
        let target = min(max(0, seconds), max(0, duration - 1 / fps)) // Stay on a real frame.
        latestRequest += 1
        let request = latestRequest
        generator.cancelAllCGImageGeneration()
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: target, preferredTimescale: 600))
            guard request == latestRequest else { return }
            time = target
            frameSize = CGSize(width: image.width, height: image.height)
            onFrame?(image)
        } catch {
            if request == latestRequest { self.error = "Could not read frame: \(error.localizedDescription)" }
        }
    }

    func step(_ frames: Int) async {
        pause()
        await seek(to: time + Double(frames) / fps)
    }

    func togglePlay() {
        if playing { pause(); return }
        guard hasVideo else { return }
        if time >= duration - 2 / fps { time = 0 } // Restart from the end.
        playing = true
        let base = time
        let started = ProcessInfo.processInfo.systemUptime
        playTask = Task {
            while !Task.isCancelled {
                let t = base + ProcessInfo.processInfo.systemUptime - started // Real-time pace; slow frames get skipped.
                await seek(to: t)
                if t >= duration - 1 / fps { break }
            }
            playing = false
        }
    }

    func pause() {
        playTask?.cancel()
        playTask = nil
        playing = false
    }
}
