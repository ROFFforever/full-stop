// Runs the real StopSignCoach over a recorded drive and writes what it did to a JSON file.
// drive_viewer.py draws that file next to the video. Run via Scripts/run_coach_replay.sh.
//
// The "glue" below (which numbers feed each coach.update call) is what the app will have to do live:
// one call per analyzed camera frame, using the tallest stop sign FRONT and the latest sensor values.
import Foundation
import AVFoundation
import CoreVideo

let speedStaleSeconds = 2.0 // A GPS speed older than this is treated as "no fix" (nil), not held forever.

struct SignDet {
    let t: Double // Video seconds.
    let box: CGRect // Vision coordinates, 0...1, origin bottom-left.
    var tint: Double? // Red-pixel share (SignColor); nil = too small to judge.
    var isFront: Bool { SignColor.looksLikeFront(tint: tint) }
    var isOnYourSide: Bool { SignPosition.isOnYourSide(box: box) } // False for signs on the left: they are for other traffic.
}

// Newer recordings log each stop sign's red tint in the "red" column. Older ones don't, so measure it from the video
// with the same SignColor code the app uses: for every stop-sign box, take the video frame closest in time.
func measureTints(video: URL, dets: inout [SignDet]) async throws {
    let asset = AVURLAsset(url: video)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "replay", code: 1) }

    let order = dets.indices.sorted { dets[$0].t < dets[$1].t }
    var next = 0 // Next unmeasured detection, in time order.

    // COACH_DUMP_CORES=<file>: also save the exact pixels each box is judged on, so SignColor can be tuned offline.
    var dump: FileHandle?
    if let path = ProcessInfo.processInfo.environment["COACH_DUMP_CORES"] {
        FileManager.default.createFile(atPath: path, contents: nil)
        dump = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    defer { try? dump?.close() }

    func measure(_ frame: CMSampleBuffer, until limit: Double) {
        guard let pixels = CMSampleBufferGetImageBuffer(frame) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        var frameMean: [Double]?
        if dump != nil { // Average colour of the whole frame (every 8th pixel), to judge boxes relative to the lighting.
            var sum = [0.0, 0.0, 0.0], n = 0.0
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in stride(from: 0, to: CVPixelBufferGetHeight(pixels), by: 8) { for x in stride(from: 0, to: CVPixelBufferGetWidth(pixels), by: 8) {
                let p = base + y * rowBytes + x * 4; sum[0] += Double(p[0]); sum[1] += Double(p[1]); sum[2] += Double(p[2]); n += 1 } }
            frameMean = sum.map { $0 / max(n, 1) }
        }
        while next < order.count, dets[order[next]].t < limit {
            let i = order[next]
            if let dump, let r = SignColor.region(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), box: dets[i].box) {
                let cast = frameMean ?? [0, 0, 0] // Whole-frame average B, G, R: the scene's lighting.
                var header = [dets[i].t, Double(dets[i].box.minX), Double(r.x1 - r.x0), Double(r.y1 - r.y0), cast[0], cast[1], cast[2]]
                var bytes = Data(bytes: &header, count: 56)
                for y in r.y0..<r.y1 { for x in r.x0..<r.x1 {
                    let p = base + y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                    bytes.append(contentsOf: [p[0], p[1], p[2]])
                } }
                dump.write(bytes)
            }
            dets[i].tint = SignColor.redTintFraction(base: base, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                                     rowBytes: CVPixelBufferGetBytesPerRow(pixels), box: dets[i].box)
            next += 1
        }
    }

    var previous: (frame: CMSampleBuffer, time: Double)?
    while next < order.count, let frame = output.copyNextSampleBuffer() {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(frame))
        if let previous { measure(previous.frame, until: (previous.time + time) / 2) } // Each detection belongs to its nearest frame.
        previous = (frame, time)
    }
    if let previous { measure(previous.frame, until: .infinity) }
}

@main struct CoachReplay {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else { print("Usage: coach_replay <drive folder> <output.json> [sensors file, default sensors.csv]"); exit(1) }
        let folder = URL(fileURLWithPath: args[1])

        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
        let t0 = meta["video_start_t"] as? Double ?? 0 // Sensor-clock time of video second 0; we work in video seconds like the viewer.
        let fwdSign = meta["fwd_convention"] == nil ? -1.0 : 1.0 // Older recordings logged forward accel with the sign inverted.

        let text = try String(contentsOf: folder.appendingPathComponent(args.count == 4 ? args[3] : "sensors.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var column: [String: Int] = [:]
        for (i, name) in lines[0].split(separator: ",", omittingEmptySubsequences: false).enumerated() { column[String(name)] = i }
        let rows = lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }

        func number(_ row: [Substring], _ name: String) -> Double? {
            guard let i = column[name], i < row.count else { return nil }
            return Double(row[i])
        }
        func kind(_ row: [Substring]) -> String { column["kind"].map { String(row[$0]) } ?? "" }
        func key(_ t: Double) -> Int { Int((t * 10000).rounded()) } // det rows share their frame's exact timestamp.

        var gps: [(t: Double, speed: Double?, stopHint: Bool)] = [] // Every fix, read the way the coach reads them (GPSSpeed).
        var motion: [(t: Double, fwd: Double)] = []
        var shake: [(t: Double, accel: SIMD3<Double>, rotation: SIMD3<Double>)] = [] // Every motion sample, for StillnessMeter.
        var frameTimes: [Double] = []
        var signs: [SignDet] = []
        let hasRedColumn = column["red"] != nil
        for row in rows {
            guard let t = number(row, "t") else { continue }
            switch kind(row) {
            case "gps":
                if let speed = number(row, "speed"), let acc = number(row, "speed_acc") {
                    let reading = GPSSpeed.read(speed: speed, accuracy: acc)
                    gps.append((t, reading.speed, reading.stopHint))
                }
            case "motion":
                if let fwd = number(row, "fwd") { motion.append((t, fwd * fwdSign)) }
                if let ax = number(row, "ax"), let ay = number(row, "ay"), let az = number(row, "az"),
                   let rx = number(row, "rx"), let ry = number(row, "ry"), let rz = number(row, "rz") {
                    shake.append((t, SIMD3(ax, ay, az), SIMD3(rx, ry, rz)))
                }
            case "frame":
                frameTimes.append(t)
            case "det":
                if row[column["label"] ?? 0] == "stop sign", let x = number(row, "bx"), let y = number(row, "by"),
                   let w = number(row, "bw"), let h = number(row, "bh") {
                    signs.append(SignDet(t: t - t0, box: CGRect(x: x, y: y, width: w, height: h), tint: number(row, "red")))
                }
            default: break
            }
        }
        gps.sort { $0.t < $1.t }
        motion.sort { $0.t < $1.t }
        shake.sort { $0.t < $1.t }
        frameTimes.sort()
        // While the front camera watches the driver's head at a stop, the back camera is off (no frame rows) and the
        // app steps the coach from a 0.15 s timer instead (DriveSession.startHeadCheck). Do the same here, or the coach
        // never sees the car stop and grades every head-check stop as rolling.
        var filled: [Double] = []
        for ft in frameTimes {
            if let last = filled.last, ft - last > 0.3 { var x = last + 0.15; while x < ft - 0.075 { filled.append(x); x += 0.15 } }
            filled.append(ft)
        }
        frameTimes = filled

        if !hasRedColumn, !signs.isEmpty {
            print("Recording has no sign colors; measuring them from the video...")
            try await measureTints(video: folder.appendingPathComponent("video.mov"), dets: &signs)
        }
        var tallestFront: [Int: Double] = [:] // What the coach is told: the tallest sign front on your side in each frame.
        for sign in signs where sign.isFront && sign.isOnYourSide {
            tallestFront[key(sign.t), default: 0] = max(tallestFront[key(sign.t)] ?? 0, Double(sign.box.height))
        }

        var coach = StopSignCoach()
        var frames: [[String: Any]] = []
        var events: [[String: Any]] = []
        var g = 0, m = 0, s = 0 // Walk through the sensor lists as time moves forward, like live data arriving.
        var stillness = StillnessMeter()
        for ft in frameTimes {
            while g + 1 < gps.count, gps[g + 1].t <= ft { g += 1 }
            while m + 1 < motion.count, motion[m + 1].t <= ft { m += 1 }
            while s < shake.count, shake[s].t <= ft { stillness.add(t: shake[s].t, accel: shake[s].accel, rotation: shake[s].rotation); s += 1 }
            let haveGPS = g < gps.count && gps[g].t <= ft && ft - gps[g].t <= speedStaleSeconds
            let speed: Double? = haveGPS ? gps[g].speed : nil // The newest fix wins, even when it has no usable speed.
            let stopHint = haveGPS && gps[g].stopHint
            let accel = (m < motion.count && motion[m].t <= ft) ? motion[m].fwd : 0
            let t = ft - t0
            let height = tallestFront[key(t)]

            let outputs = coach.update(CoachInput(t: t, signBoxHeight: height, speed: speed, forwardAccel: accel, stopHint: stopHint,
                                                  isStill: stillness.isStill))
            frames.append(["t": t, "phase": "\(coach.phase)", "height": height as Any? ?? NSNull(),
                           "speed": speed as Any? ?? NSNull(), "accel": accel, "stopHint": stopHint, "still": stillness.isStill])
            for output in outputs {
                switch output {
                case .speak(let words):
                    events.append(["t": t, "kind": "speak", "text": words])
                case .phaseChanged(let from, let to):
                    events.append(["t": t, "kind": "phase", "from": "\(from)", "to": "\(to)"])
                case .result(let r):
                    events.append(["t": t, "kind": "result", "outcome": "\(r.outcome)", "minSpeed": r.minSpeed as Any? ?? NSNull(),
                                   "peakBrakeG": r.peakBrakeG, "boxHeightAtPeakBrake": r.boxHeightAtPeakBrake as Any? ?? NSNull()])
                }
            }
        }

        // Every stop-sign box with its color verdict, so the viewer can show which ones were rejected as backs.
        let signRecords = signs.map { ["t": $0.t, "bx": $0.box.minX, "red": $0.tint as Any? ?? NSNull(), "front": $0.isFront, "yourSide": $0.isOnYourSide] as [String: Any] }
        let json = try JSONSerialization.data(withJSONObject: ["frames": frames, "events": events, "signs": signRecords], options: [.sortedKeys])
        try json.write(to: URL(fileURLWithPath: args[2]))
        let spoken = events.filter { $0["kind"] as? String == "speak" }.count
        let results = events.filter { $0["kind"] as? String == "result" }.count
        let backs = signs.filter { !$0.isFront }.count
        let leftFronts = signs.filter { $0.isFront && !$0.isOnYourSide }.count
        print("\(frames.count) frames replayed, \(spoken) spoken alerts, \(results) results, \(backs) of \(signs.count) stop-sign boxes rejected as backs, \(leftFronts) more as left-side fronts -> \(args[2])")
    }
}
