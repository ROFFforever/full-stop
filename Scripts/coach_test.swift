// Command-line tests for the stop-sign state machine, using fake numbers (no camera or phone needed).
// Usage: Scripts/run_coach_test.sh
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print(condition ? "PASS  \(name)" : "FAIL  \(name)")
    if !condition { failures += 1 }
}

let dt = 0.15 // One detector frame, about 6.7 fps.

// One fake frame: sign box height (nil = no sign), GPS speed (nil = no fix), forward accel.
struct Frame {
    var height: Double?
    var speed: Double?
    var accel = 0.0
    var stopHint = false
    var isStill = false
}

// Feeds frames to a coach one dt apart and remembers everything it said.
struct Sim {
    var coach = StopSignCoach()
    var t = 0.0
    var outputs: [CoachOutput] = []

    mutating func feed(_ frames: [Frame]) {
        for f in frames {
            outputs += coach.update(CoachInput(t: t, signBoxHeight: f.height, speed: f.speed, forwardAccel: f.accel, stopHint: f.stopHint, isStill: f.isStill))
            t += dt
        }
    }
    mutating func wait(_ seconds: Double, speed: Double? = 10) { feed(noSign(Int(seconds / dt), speed: speed)) }

    var phase: CoachPhase { coach.phase }
    var spoken: [String] { outputs.compactMap { if case .speak(let s) = $0 { s } else { nil } } }
    var results: [StopSignResult] { outputs.compactMap { if case .result(let r) = $0 { r } else { nil } } }
}

func sign(_ n: Int, height: Double = 0.05, speed: Double? = 10, accel: Double = 0) -> [Frame] {
    Array(repeating: Frame(height: height, speed: speed, accel: accel), count: n)
}
func noSign(_ n: Int, speed: Double? = 10, accel: Double = 0) -> [Frame] {
    Array(repeating: Frame(height: nil, speed: speed, accel: accel), count: n)
}
// Speeds ramping linearly from `from` to `to` over n frames, sign in view growing.
func ramp(from: Double, to: Double, _ n: Int, height: Double? = 0.2, accel: Double = -0.1) -> [Frame] {
    (0..<n).map { Frame(height: height, speed: from + (to - from) * Double($0 + 1) / Double(n), accel: accel) }
}
// Gets a sim to APPROACHING at 10 m/s.
func approaching() -> Sim {
    var sim = Sim()
    sim.feed(sign(6))
    return sim
}
let stopSpoken = "Stop sign ahead, start slowing"

// Builds a width x height BGRA image (the camera's pixel order) filled with one color.
func image(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
    (0..<width * height).flatMap { _ in [b, g, r, 255] }
}

@main struct CoachTests {
    static func main() {
        // --- First half: candidate and approach ---
        var sim = Sim()
        sim.feed(sign(4))
        check(sim.phase == .signCandidate && sim.spoken.isEmpty, "4 frames: still a candidate, silent")
        sim = Sim(); sim.feed(sign(5))
        check(sim.phase == .approaching && sim.spoken == [stopSpoken], "5 frames: approaching, one alert")

        sim = Sim(); sim.feed(sign(3) + noSign(1) + sign(3))
        check(sim.phase == .signCandidate && sim.spoken.isEmpty, "dropout resets the candidate count")

        sim = Sim(); sim.feed(sign(8, speed: 0))
        check(sim.phase == .signCandidate && sim.spoken.isEmpty, "parked: no alert")
        sim.feed(sign(2, speed: 8))
        check(sim.phase == .approaching && sim.spoken.count == 1, "starts moving: alert fires")

        sim = Sim(); sim.feed(sign(5, speed: nil))
        check(sim.phase == .approaching, "nil speed: still alerts")

        sim = Sim(); sim.feed((0..<40).map { Frame(height: 0.05 + Double($0) * 0.006, speed: 10) })
        check(sim.spoken.count == 1 && sim.phase == .approaching, "growing approach: exactly one alert")
        check((sim.coach.approachScore ?? 0) > 0.9, "growing approach: high approach score")

        sim = Sim(); sim.feed((0..<40).map { Frame(height: $0 % 2 == 0 ? 0.06 : 0.04, speed: 10) })
        check((sim.coach.approachScore ?? 1) < 0.6, "jittery box: low approach score")

        // Sign leaves the frame while the car is still fast: wait, don't give up (it never goes back to idle by itself).
        sim = Sim(); sim.feed(sign(6) + noSign(30))
        check(sim.phase == .approaching && sim.results.isEmpty, "sign lost at speed: still approaching after 4.5 s")
        sim.feed(noSign(15))
        check(sim.phase == .idle && sim.results.first?.outcome == .passedThrough && sim.spoken == [stopSpoken],
              "never slowed for 6+ s: quiet pass-through result")

        // Sign leaves the frame while the car is at or under 8 mph: that's the stop.
        sim = Sim(); sim.feed(sign(6) + noSign(12, speed: 3.4))
        check(sim.phase == .stopping, "sign lost at 3.4 m/s (7.6 mph) -> stopping")

        // Your drive: sign gone at 4.3 m/s (9.6 mph) and still slowing. Keep waiting, then it's the stop.
        sim = Sim(); sim.feed(sign(6) + ramp(from: 6, to: 4.3, 12, height: nil))
        check(sim.phase == .approaching, "sign lost at 4.3 m/s: keeps waiting")
        sim.feed(ramp(from: 4.3, to: 3.0, 8, height: nil))
        check(sim.phase == .stopping, "...then slows under 8 mph -> stopping")

        // No GPS: fall back to how big the sign was when it vanished.
        sim = Sim(); sim.feed(sign(6, height: 0.4, speed: nil) + noSign(15, speed: nil))
        check(sim.phase == .stopping, "no GPS, big sign lost -> stopping")
        sim = Sim(); sim.feed(sign(6, height: 0.05, speed: nil) + noSign(100, speed: nil))
        check(sim.phase == .idle && sim.results.first?.outcome == .unknown && sim.spoken == [stopSpoken],
              "no GPS, small sign lost -> unknown result after waiting")

        sim = approaching(); sim.feed(sign(3, height: 0.2, speed: 2))
        check(sim.phase == .stopping, "speed drops -> stopping")

        // --- Second half: stopping, stopped, departing, result ---

        // Clean stop: slow to 2, hold at 0 for 1.2 s, then pull away.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(9, speed: 0))
        check(sim.phase == .stopped, "held at 0 for 1 s -> stopped")
        sim.feed(sign(2, speed: 0.8))
        check(sim.phase == .stopped, "0.8 m/s is under the leave-stopped speed: still stopped")
        sim.feed(noSign(1, speed: 2))
        check(sim.phase == .departing && sim.results.isEmpty, "starts moving -> departing, no result yet")
        sim.feed(noSign(2, speed: 3.5))
        check(sim.phase == .departing && sim.results.isEmpty, "3.5 m/s hasn't cleared the sign yet")
        sim.feed(noSign(1, speed: 4.5))
        check(sim.phase == .idle && sim.results.count == 1, "reaches 4 m/s -> result, back to idle")
        check(sim.results.first?.outcome == .fullStop && sim.results.first?.minSpeed == 0, "result: full stop, min speed 0")
        check(sim.spoken == [stopSpoken], "full stop: no 'come to a full stop' nag")

        // Stopped for less than a second doesn't count.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(5, speed: 0.2) + sign(3, speed: 4.5))
        check(sim.results.first?.outcome == .almostStopped, "0.75 s near zero is not a full stop: almost")
        check(sim.spoken == [stopSpoken], "almost stopped: no 'come to a full stop' nag")

        // Rolling stop: slow to 1.8, then speed back up.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 1.8, 10) + sign(3, speed: 2.5) + sign(3, speed: 4.2))
        check(sim.results.first?.outcome == .rolling, "slow, never stopped, speeds up -> rolling")
        check(sim.results.first.map { abs(($0.minSpeed ?? 99) - 1.8) < 0.01 } == true, "rolling: min speed recorded")
        check(sim.spoken == [stopSpoken, "Come to a full stop"], "rolling stop: spoken reminder")

        // Crawling past the sign forever times out as rolling.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(100, speed: 2))
        check(sim.results.first?.outcome == .rolling, "creeping at 2 m/s -> rolling after stopping and departing timeouts")

        // Rolling stop is called out the moment the car speeds up, before it has cleared the sign.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 1.8, 10) + sign(2, speed: 3.5))
        check(sim.phase == .departing && sim.spoken.last == "Come to a full stop" && sim.results.isEmpty,
              "rolling: reminder spoken right away, result waits for clearing")

        // DEPARTING ends on a timeout if the car never gets to clearing speed, even with no GPS.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(9, speed: 0) + noSign(1, speed: 2))
        sim.feed(noSign(30, speed: 2))
        check(sim.phase == .departing && sim.results.isEmpty, "departing: 4.5 s of crawling, still waiting")
        sim.feed(noSign(5, speed: 2))
        check(sim.phase == .idle && sim.results.first?.outcome == .fullStop, "departing: timeout closes it out, still a full stop")
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(9, speed: 0) + noSign(1, speed: 2) + noSign(40, speed: nil))
        check(sim.phase == .idle && sim.results.count == 1, "departing: no GPS, timeout closes it out")

        // Blowing through at speed: sign vanishes close, car never slows.
        sim = Sim(); sim.feed(sign(6, height: 0.4) + noSign(15) + noSign(60, speed: 9))
        check(sim.results.first?.outcome == .passedThrough && sim.spoken == [stopSpoken], "drove past at 9 m/s -> passed through, no late nag")

        // GPS dies mid-stop: don't guess.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + noSign(12, speed: nil) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .unknown, "GPS gone 1.8 s while stopping -> unknown")

        // A short GPS blip doesn't ruin a normal result.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + noSign(2, speed: nil) + sign(9, speed: 0) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .fullStop, "short GPS blip then a real stop -> full stop")

        // Hardest braking and how big the sign was then.
        sim = approaching()
        var braking = ramp(from: 10, to: 2, 10, height: 0.1, accel: -0.1)
        braking[7].accel = -0.45
        braking[7].height = 0.33
        sim.feed(braking + sign(9, speed: 0) + noSign(3, speed: 5))
        check(sim.results.first?.peakBrakeG == -0.45 && sim.results.first?.boxHeightAtPeakBrake == 0.33,
              "result: peak brake and sign size at that moment")

        // The sign we just handled is still in view: don't alert again, until the cooldown ends.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(9, speed: 0) + sign(3, speed: 5))
        sim.feed(sign(8, height: 0.3, speed: 4))
        check(sim.phase == .idle && sim.spoken.count == 1, "cooldown: same sign doesn't re-alert")
        sim.wait(8, speed: 10)
        sim.feed(sign(6))
        check(sim.phase == .approaching && sim.spoken.count == 2, "after cooldown: next sign alerts again")
        // The handled sign is out of view: a new sign 3 s later alerts, cooldown or not (Oct 23 night drive, 266.8 s).
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + noSign(9, speed: 0) + noSign(3, speed: 5))
        sim.feed(noSign(20, speed: 9))
        sim.feed(sign(6))
        check(sim.phase == .approaching && sim.spoken.count == 2, "cooldown: ends early once the old sign is gone")

        // Phase changes are reported for the log.
        sim = Sim(); sim.feed(sign(5))
        check(sim.outputs.contains(.phaseChanged(from: .idle, to: .signCandidate))
              && sim.outputs.contains(.phaseChanged(from: .signCandidate, to: .approaching)), "phase changes are emitted")

        // --- Sign color: the front of a stop sign is red, the back is gray/white ---
        let w = 40, h = 40
        let red = image(width: w, height: h, r: 170, g: 30, b: 35)
        let darkRed = image(width: w, height: h, r: 90, g: 25, b: 30) // A sign in shadow.
        let white = image(width: w, height: h, r: 235, g: 235, b: 235)
        let gray = image(width: w, height: h, r: 130, g: 135, b: 132)
        let box = CGRect(x: 0, y: 0, width: 1, height: 1) // Whole image, Vision coordinates.
        func tint(_ pixels: [UInt8]) -> Double? { SignColor.redTintFraction(bgra: pixels, width: w, height: h, rowBytes: w * 4, box: box) }
        check((tint(red) ?? 0) > 0.9, "color: red sign is red-tinted")
        check((tint(darkRed) ?? 0) > 0.9, "color: shadowed red sign is still red-tinted")
        check(tint(white) == 0 && tint(gray) == 0, "color: white and gray backs have no red tint")
        // Half red, half white (a sign with white lettering, say): about half.
        var mixed = white
        for i in 0..<(w * h / 2) { mixed[i * 4] = 35; mixed[i * 4 + 1] = 30; mixed[i * 4 + 2] = 170 }
        check(abs((tint(mixed) ?? 0) - 0.5) < 0.1, "color: half red image reads about 0.5")
        // The outer 20% of the box (the sign's edge and background) is ignored.
        var framed = image(width: w, height: h, r: 235, g: 235, b: 235)
        for y in 0..<h { for x in 0..<w where x < 6 || x >= w - 6 || y < 6 || y >= h - 6 {
            let i = (y * w + x) * 4; framed[i] = 35; framed[i + 1] = 30; framed[i + 2] = 170 } }
        check(tint(framed) == 0, "color: red only at the edge is ignored")
        // Orange and yellow signs (warning signs) and sunlit white are warm but not red.
        check(tint(image(width: w, height: h, r: 240, g: 160, b: 50)) == 0, "color: an orange sign is not red")
        check(tint(image(width: w, height: h, r: 225, g: 190, b: 20)) == 0, "color: a yellow sign is not red")
        check(tint(image(width: w, height: h, r: 203, g: 185, b: 173)) == 0, "color: sunlit white is not red")
        check((tint(image(width: w, height: h, r: 150, g: 90, b: 95)) ?? 0) > 0.9, "color: a hazy pinkish-red front is still red")
        check((tint(image(width: w, height: h, r: 100, g: 66, b: 88)) ?? 0) > 0.9, "color: a purplish red front (blue above green) is still red")
        check(tint(image(width: w, height: h, r: 170, g: 60, b: 200)) == 0, "color: purple is not red")
        // The orange-brown post down the middle of a sign's back is ignored; red on the sides still counts.
        var withPost = white
        for y in 0..<h { for x in (w * 3 / 8)..<(w * 5 / 8) { let i = (y * w + x) * 4; withPost[i] = 50; withPost[i + 1] = 100; withPost[i + 2] = 190 } }
        check(tint(withPost) == 0, "color: a post down the middle of a white back is ignored")
        var redWithLetters = red
        for y in 0..<h { for x in (w * 3 / 8)..<(w * 5 / 8) { let i = (y * w + x) * 4; redWithLetters[i] = 235; redWithLetters[i + 1] = 235; redWithLetters[i + 2] = 235 } }
        check((tint(redWithLetters) ?? 0) > 0.9, "color: red sides with white lettering in the middle still read red")
        // Boxes under the size limit aren't judged at all.
        check(SignColor.redTintFraction(bgra: white, width: w, height: h, rowBytes: w * 4, box: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)) == nil,
              "color: a box under 25 px tall is not judged (nil)")
        check(SignColor.looksLikeFront(tint: nil) && SignColor.looksLikeFront(tint: 0.4) && !SignColor.looksLikeFront(tint: 0.02),
              "color: unjudged boxes are kept; low tint is rejected")

        // --- Stopped cars and GPS: iOS often reports no speed, or a poor-accuracy near-zero one, exactly when stopped ---
        check(GPSSpeed.read(speed: -1, accuracy: -1) == (nil, true), "gps: 'no valid speed' is a stop hint")
        check(GPSSpeed.read(speed: 0.4, accuracy: 4.5) == (nil, true), "gps: poor-accuracy near-zero reading is a stop hint")
        check(GPSSpeed.read(speed: 6.0, accuracy: 4.5) == (nil, false), "gps: poor-accuracy fast reading is just unusable")
        check(GPSSpeed.read(speed: 2.0, accuracy: 1.2) == (2.0, false), "gps: a good reading is a speed")

        // A real stop where GPS never reads under 0.5: 0.8 held for 1 s now counts.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(8, speed: 0.8) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .fullStop, "stop where GPS bottoms out at 0.8 m/s -> full stop")
        // ...but 1.2 m/s is still creeping.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(8, speed: 1.2) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .almostStopped, "lowest 1.2 m/s -> almost stopped")
        // The Oct 19 hill roll bottomed out at 1.37 m/s: still a rolling stop, with the reminder.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + sign(8, speed: 1.37) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .rolling && sim.spoken.last == "Come to a full stop", "lowest 1.37 m/s -> rolling, reminder spoken")

        // Turned off ~20 ft before a far sign (Oct 23, 07:45): it never grew past 0.025, the car slowed to ~3 m/s for the
        // turn and the sign slid out of view. Not a stop at that sign: passed through, no nag.
        var turnedOff = Sim()
        turnedOff.feed(sign(6, height: 0.025) + noSign(11, speed: 7) + noSign(10, speed: 3.4) + noSign(60, speed: 6))
        check(turnedOff.results.first?.outcome == .passedThrough && turnedOff.spoken == [stopSpoken],
              "tiny sign, slowed for a turn, never stopped -> passed through, no 'come to a full stop'")
        // Same tiny sign but the car really stopped: a full stop still counts.
        var tinyStop = Sim()
        tinyStop.feed(sign(6, height: 0.025) + ramp(from: 10, to: 0.3, 10, height: 0.03) + sign(10, height: 0.03, speed: 0.3) + noSign(4, speed: 5))
        check(tinyStop.results.first?.outcome == .fullStop, "tiny sign but a real stop -> still a full stop")

        // GPS gives no speed right as the car stops (your 205233 drive at 62.7 s): count it as standing still.
        func hinted(_ n: Int) -> [Frame] { Array(repeating: Frame(height: nil, speed: nil, stopHint: true), count: n) }
        sim = approaching()
        sim.feed(ramp(from: 10, to: 1.7, 10) + hinted(8) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .fullStop, "slowing, then GPS goes invalid for 1 s -> full stop")
        // Plain missing GPS (no hint) still means "can't tell".
        sim = approaching()
        sim.feed(ramp(from: 10, to: 1.7, 10) + noSign(12, speed: nil) + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .unknown, "slowing, then GPS just missing -> unknown")
        // A hint while the last real speed was high (GPS lost at speed, e.g. under trees) is not a stop.
        sim = Sim(); sim.feed(sign(6, height: 0.4, speed: 9) + noSign(10, speed: 9) + hinted(20) + noSign(40, speed: 9))
        check(sim.results.first?.outcome != .fullStop, "GPS invalid while still fast -> not a full stop")

        // --- Stillness: the phone goes quiet when the car stands still, even if GPS misses the stop ---
        var meter = StillnessMeter()
        for i in 0..<60 { meter.add(t: Double(i) * 0.02, accel: SIMD3(0.02, -0.01, 0.015), rotation: SIMD3(0.01, 0.02, -0.01)) } // Idling.
        check(meter.isStill, "stillness: 1.2 s of idling vibration is still")
        meter.reset()
        for i in 0..<30 { meter.add(t: Double(i) * 0.02, accel: SIMD3(0.02, 0, 0), rotation: .zero) }
        check(!meter.isStill, "stillness: needs a full second first")
        meter.reset()
        for i in 0..<60 { meter.add(t: Double(i) * 0.02, accel: SIMD3(i % 2 == 0 ? 0.12 : -0.12, 0.05, 0), rotation: SIMD3(0, 0, 0.02)) } // Road bumps.
        check(!meter.isStill, "stillness: driving bumps are not still")
        meter.reset()
        for i in 0..<60 { meter.add(t: Double(i) * 0.02, accel: SIMD3(0.02, 0, 0), rotation: SIMD3(0, 0, 0.15)) } // Smooth but turning.
        check(!meter.isStill, "stillness: a smooth turn is not still")

        // GPS bottoms out at 1.2 m/s (stop between readings, your 205233 drive at 131.9 s), but the phone was still.
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + [Frame(height: nil, speed: 1.2, isStill: true)] + noSign(3, speed: 5))
        check(sim.results.first?.outcome == .fullStop, "GPS misses a short stop, phone was still -> full stop")
        // Stillness while still fast (last real speed high) doesn't count.
        sim = Sim(); sim.feed(sign(6, height: 0.4, speed: 9) + noSign(10, speed: 9) + [Frame(height: nil, speed: nil, isStill: true)] + noSign(60, speed: 9))
        check(sim.results.first?.outcome != .fullStop, "still while GPS last said fast -> not a full stop")
        // A smooth, steady creep feels still to the phone (Oct 23 lot test: 4-5.5 mph rolls read "still" for 2-5 s).
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2, 10) + Array(repeating: Frame(height: nil, speed: 2.0, isStill: true), count: 20) + noSign(10, speed: 5))
        check(sim.results.first?.outcome == .rolling, "still while creeping at 4.5 mph -> rolling, not a full stop")
        // GPS lags: still while GPS still reads 2.05, the next reading says 1.2 (Oct 19 drive, 132 s).
        sim = approaching()
        sim.feed(ramp(from: 10, to: 2.05, 10) + Array(repeating: Frame(height: nil, speed: 2.05, isStill: true), count: 3)
                 + Array(repeating: Frame(height: nil, speed: 1.2), count: 6) + ramp(from: 1.6, to: 6, 10))
        check(sim.results.first?.outcome == .fullStop, "still, then GPS catches up a reading later -> full stop")

        // --- Sign position: signs on the left are for other traffic ---
        check(SignPosition.isOnYourSide(box: CGRect(x: 0.6, y: 0.4, width: 0.04, height: 0.04)), "position: sign right of centre is yours")
        check(SignPosition.isOnYourSide(box: CGRect(x: 0.45, y: 0.4, width: 0.04, height: 0.04)), "position: sign straight ahead (T-intersection) is yours")
        check(!SignPosition.isOnYourSide(box: CGRect(x: 0.1, y: 0.4, width: 0.04, height: 0.04)), "position: sign on the left is not")
        check(!SignPosition.isOnYourSide(box: CGRect(x: 0.0, y: 0.3, width: 0.1, height: 0.2)), "position: big sign at the left edge is not")

        print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
