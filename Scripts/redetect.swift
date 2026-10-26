// Re-runs object detection on a recorded drive's video with a different bundled model, so a drive recorded with one
// model can be replayed as if it had used another. Run via Scripts/run_redetect.sh.
//
// For every analyzed frame in sensors.csv (the "frame" rows), it takes the same video frame the app analyzed, runs the
// model through Vision exactly like CameraDetector (scaleFill, orientation .up, same logged labels, same red tint),
// and writes sensors_<model>.csv: the original file with its "det" rows replaced. GPS, motion and frame rows are untouched,
// so the coach replay and the viewer can use it in place of sensors.csv.
// Not identical to the phone: the Mac's Core ML can differ slightly in its numbers, and every frame is analyzed at the
// times the original model ran (a slower model on the phone would have analyzed fewer frames).
import Foundation
import AVFoundation
import CoreML
import Vision

let loggedLabels: Set<String> = ["stop sign", "person", "car", "truck", "bus", "motorcycle", "bicycle", "traffic light"] // As CameraDetector.

@main struct Redetect {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("Usage: redetect <drive folder> <model name, e.g. yolo11s_1280>"); exit(1) }
        let folder = URL(fileURLWithPath: args[1])
        let modelName = args[2]
        let package = URL(fileURLWithPath: "Congressional App Challenge/\(modelName).mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else { print("No model at \(package.path)"); exit(1) }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let compiled = try await MLModel.compileModel(at: package)
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration)))
        request.imageCropAndScaleOption = .scaleFill // Same as the app.

        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
        guard let t0 = meta["video_start_t"] as? Double else { print("meta.json has no video_start_t"); exit(1) }

        let text = try String(contentsOf: folder.appendingPathComponent("sensors.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var column: [String: Int] = [:]
        for (i, name) in header.enumerated() { column[name] = i }
        guard let tCol = column["t"], let kindCol = column["kind"] else { print("sensors.csv has no t/kind columns"); exit(1) }
        func field(_ line: String, _ i: Int) -> String {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            return i < parts.count ? String(parts[i]) : ""
        }
        let frameTimes = lines.dropFirst().filter { field($0, kindCol) == "frame" }.compactMap { Double(field($0, tCol)) }.sorted()

        // Detect on the video frame nearest each analyzed frame's time. Rows are keyed by the frame row's own time
        // string so the coach replay pairs them with their frame exactly.
        var dets: [String: [String]] = [:] // Frame time (as written) -> det rows.
        let asset = AVURLAsset(url: folder.appendingPathComponent("video.mov"))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("No video track"); exit(1) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "redetect", code: 1) }

        var next = 0, signs = 0, worstGap = 0.0
        let started = Date()
        func detect(_ frame: CMSampleBuffer, frameTime: Double, gap: Double) throws {
            guard let pixels = CMSampleBufferGetImageBuffer(frame) else { return }
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
            worstGap = max(worstGap, gap)
            var rows: [String] = []
            for object in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                guard let label = object.labels.first, loggedLabels.contains(label.identifier) else { continue }
                let box = object.boundingBox
                var tint: Double?
                if label.identifier == "stop sign" {
                    signs += 1
                    CVPixelBufferLockBaseAddress(pixels, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(pixels) {
                        tint = SignColor.redTintFraction(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(pixels),
                                                         height: CVPixelBufferGetHeight(pixels), rowBytes: CVPixelBufferGetBytesPerRow(pixels), box: box)
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
                }
                var parts = Array(repeating: "", count: header.count)
                parts[tCol] = String(format: "%.4f", frameTime)
                parts[kindCol] = "det"
                let values: [String: String] = ["label": label.identifier, "conf": String(format: "%.3f", label.confidence),
                                                "bx": String(format: "%.4f", box.minX), "by": String(format: "%.4f", box.minY),
                                                "bw": String(format: "%.4f", box.width), "bh": String(format: "%.4f", box.height),
                                                "red": tint.map { String(format: "%.3f", $0) } ?? ""]
                for (name, value) in values { if let i = column[name] { parts[i] = value } }
                rows.append(parts.joined(separator: ","))
            }
            dets[String(format: "%.4f", frameTime), default: []] = rows
        }

        // Walk the video once; each analyzed frame time takes whichever decoded frame is closest.
        var previous: (frame: CMSampleBuffer, time: Double)?
        while next < frameTimes.count, let frame = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(frame)) // Video seconds.
            if let previous {
                while next < frameTimes.count, frameTimes[next] - t0 < (previous.time + time) / 2 {
                    try detect(previous.frame, frameTime: frameTimes[next], gap: abs(frameTimes[next] - t0 - previous.time))
                    next += 1
                    if next % 500 == 0 { print("  \(next)/\(frameTimes.count) frames, \(Int(Date().timeIntervalSince(started))) s") }
                }
            }
            previous = (frame, time)
        }
        if let previous { while next < frameTimes.count { try detect(previous.frame, frameTime: frameTimes[next], gap: abs(frameTimes[next] - t0 - previous.time)); next += 1 } }

        // Same file, det rows swapped: each frame row is followed by its new detections.
        var out = [lines[0]]
        for line in lines.dropFirst() {
            let kind = field(line, kindCol)
            if kind == "det" { continue }
            out.append(line)
            if kind == "frame", let t = Double(field(line, tCol)) { out += dets[String(format: "%.4f", t)] ?? [] }
        }
        let path = folder.appendingPathComponent("sensors_\(modelName).csv")
        try (out.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        print("\(frameTimes.count) frames re-detected with \(modelName) in \(Int(Date().timeIntervalSince(started))) s, \(signs) stop-sign boxes, worst frame-time mismatch \(String(format: "%.3f", worstGap)) s -> \(path.path)")
    }
}
