import Foundation

// The stop-sign coach as a state machine. Pure logic: numbers in, events out. No camera, GPS, or audio here,
// so it can be tested with fake numbers and replayed on recorded drives.
//
// IDLE -> SIGN_CANDIDATE -> APPROACHING -> STOPPING -> STOPPED -> DEPARTING -> EVALUATE -> IDLE
// Not built yet: the look-both-ways check (it belongs in STOPPED/DEPARTING) and grading smooth vs hard braking.

// Starting values; tune them on recorded drives.
enum CoachTuning {
    static let candidateFrames = 5 // "More than 4 frames in a row" before we believe a sign is real.
    static let minApproachSpeed = 1.5 // m/s. A sign seen while (nearly) parked is not an approach, so no alert.
    static let stoppingSpeed = 2.5 // m/s. Below this while approaching, we call it the start of a stop.
    static let lostSeconds = 1.5 // No sign for this long counts as "the sign left the frame" (not just a missed frame).
    static let lostSignStopSpeed = 3.58 // m/s (8 mph). Sign gone and slower than this: we're stopping at it.
    static let lostWaitSeconds = 6.0 // Sign gone but still fast: keep waiting this long for the car to slow before calling it a pass-through.
    static let minReachedBoxHeight = 0.04 // A sign never seen taller than this was never reached: the car turned off before it
    // (Oct 23, 07:45 drive: slowed to ~7 mph for a turn ~20 ft before a sign that peaked at 0.025, graded rolling). Such a
    // stop is filed as passed through, silently, unless the car really stopped. Real stops in 13 drives peaked at 0.054-0.24.
    static let nearBoxHeight = 0.15 // Only used with no GPS: a sign this big (box height / frame height) vanishing means we reached it. Your sign left at ~0.18.

    static let stoppedSpeed = 1.0 // m/s. Under this, held for stoppedSeconds, counts as a full stop. Not 0.5: a stopped car's
    // GPS speed often reads 0.3-0.9 (12 real full stops in 4 recordings), so 0.5 called real stops "rolling".
    static let stoppedSeconds = 1.0
    static let almostStoppedSpeed = 1.3 // m/s (2.9 mph). Never "stopped", but GPS got this low: graded "almost", no voice nag.
    // GPS (1 Hz, smoothed) can't see a 1-2 s stop: real stops the parent called full read 0.94-1.03 m/s, and so did a
    // real roll (0.97). Between full and rolling there is a gray zone it can't split, so it gets its own grade. The one
    // clear rolling stop on record (Oct 19, a hill) bottomed out at 1.37: just above this. Thin margin; retune with data.
    static let leaveStoppedSpeed = 1.5 // m/s. Above the entry value on purpose, so GPS jitter can't flip STOPPED on and off.
    static let hintMaxPriorSpeed = 2.5 // m/s. A "GPS says nothing useful" moment only counts as stopping if the last real speed was this low.
    static let stillMaxSpeed = 1.3 // m/s (2.9 mph). "Phone is still" counts as a stop only if GPS agrees the car is this slow (or has
    // no speed at all) within stillConfirmSeconds. The accelerometer feels changes in speed, not speed: in the Oct 23 lot test
    // two smooth rolls at a steady 4-5.5 mph read "still" for 2-5 s and were graded full stops, and one street drive read
    // "still" at 24 mph. Real full stops in the lot read 0-1.1 mph.
    static let stillConfirmSeconds = 2.0 // GPS lags ~1 s, so it may agree one reading late: Oct 19 drive at 132 s, the phone
    // was still while GPS read 2.05 m/s, and the next reading was 1.2.
    static let departSpeed = 3.0 // m/s. Speeding back up past this (and past the lowest speed + riseMargin) ends a stop that never got to zero.
    static let riseMargin = 1.0 // m/s.
    static let stoppingTimeout = 8.0 // s. STOPPING that never stops or speeds up is closed out as a rolling stop.
    static let clearSpeed = 4.0 // m/s. DEPARTING ends once the car is this fast: it has cleared the sign.
    static let departingTimeout = 5.0 // s. ...or after this long, if it never gets there (GPS gone, crawling, stopped again).
    static let cooldownSeconds = 8.0 // The sign we just handled is often still in view; ignore signs this long afterwards...
    // ...unless it has been out of view for lostSeconds: then any sign is a new one. Oct 23 night drive: a stop was graded at
    // 263.8 s, its sign gone since 257.5, and the next sign (266.8-272 s, 31 clear frames) fell inside the cooldown: no alert.
}

enum CoachPhase: Equatable {
    case idle, signCandidate, approaching, stopping, stopped, departing, evaluate
}

// One tick of data, built from whatever the detector and motion service last reported.
struct CoachInput {
    let t: TimeInterval // Seconds on any steady clock.
    let signBoxHeight: Double? // Biggest stop sign's height as a fraction of the frame (0...1). nil = no sign this frame.
    let speed: Double? // GPS speed, m/s. nil = no usable fix.
    let forwardAccel: Double // Cleaned forward acceleration, g (+ = speeding up, braking is negative).
    var stopHint = false // The latest GPS fix had no usable speed in a way that typically means "standing still" (see GPSSpeed).
    var isStill = false // The phone has been still for a full second (StillnessMeter): stopped, even if GPS missed it.
}

// Turns one raw GPS fix into what the coach uses. At the moment a car stops, iOS often reports no speed at all (-1)
// or a near-zero speed with poor accuracy. Throwing those away hid 6 of 12 real full stops, so they become a hint.
enum GPSSpeed {
    static let maxAccuracy = 3.0 // m/s. Same as MotionTuning.maxSpeedAccuracy: worse readings aren't trusted as a speed.
    static let hintSpeed = 1.0 // m/s. A poor-accuracy reading this low still says "about stopped".

    static func read(speed: Double, accuracy: Double) -> (speed: Double?, stopHint: Bool) {
        if speed < 0 || accuracy < 0 { return (nil, true) } // iOS: "no valid speed". Typical of standing still.
        if accuracy > maxAccuracy { return (nil, speed <= hintSpeed) }
        return (speed, false)
    }
}

// What happened at one stop sign. Becomes a line on the report card.
struct StopSignResult: Equatable {
    enum Outcome: Equatable {
        case fullStop
        case almostStopped // Never clearly stopped, but slowed to almostStoppedSpeed or less (about a 1-3 mph creep).
        case rolling // Slowed down, but never below almostStoppedSpeed.
        case unknown // GPS was missing too long to tell whether the car stopped. Better than guessing.
        case passedThrough // Sign left the frame and the car never slowed (almost always a sign for another road), or the sign
        // stayed tiny the whole time and the car never stopped (it turned off before reaching it; see minReachedBoxHeight).
        // The report card leaves these out.
    }
    let outcome: Outcome
    let minSpeed: Double? // Lowest GPS speed while stopping, m/s.
    let peakBrakeG: Double // Hardest braking seen (most negative forward accel), g. 0 if never braked.
    let boxHeightAtPeakBrake: Double? // Sign size when the hardest braking happened: how close the sign was. Raw data for grading later.
}

enum CoachOutput: Equatable {
    case speak(String)
    case phaseChanged(from: CoachPhase, to: CoachPhase) // For the CSV log and the replay tool.
    case result(StopSignResult)
}

struct StopSignCoach {
    private(set) var phase = CoachPhase.idle

    // Soft false-positive filter: a real approach makes the sign grow, so most frame-to-frame changes are increases.
    // 0...1; nil until there are a few samples. Reported only, not used to block anything yet.
    var approachScore: Double? {
        guard heights.count >= 4 else { return nil }
        let growing = zip(heights, heights.dropFirst()).filter { $1 >= $0 }.count
        return Double(growing) / Double(heights.count - 1)
    }

    private var signFrames = 0 // Consecutive frames with a sign (SIGN_CANDIDATE).
    private var heights: [Double] = [] // Box heights seen during this approach, oldest first.
    private var lastSignTime: TimeInterval = 0 // When the sign was last seen.
    private var lastTime: TimeInterval = 0 // Time of the previous update, for measuring gaps.

    // Per-stop bookkeeping, cleared when a new approach starts.
    private var stoppingSince: TimeInterval = 0
    private var minSpeed: Double?
    private var reachedStop = false
    private var pendingOutcome = StopSignResult.Outcome.unknown // Decided on entering DEPARTING, reported when it ends.
    private var departingSince: TimeInterval = 0
    private var unknownSeconds = 0.0 // Time spent stopping with no valid GPS speed.
    private var peakBrake = 0.0
    private var heightAtPeakBrake: Double?
    private var stoppedDetector = SustainDetector(threshold: CoachTuning.stoppedSpeed, direction: .below,
                                                  duration: CoachTuning.stoppedSeconds)
    private var ignoreSignsUntil: TimeInterval = -.infinity
    private var anySignTime: TimeInterval = -.infinity // When a sign was last in view (any phase).
    private var lastRealSpeed: Double? // Most recent usable GPS speed, for judging stopHint.
    private var lastStillTime: TimeInterval = -.infinity // When the phone last reported "still".

    mutating func update(_ input: CoachInput) -> [CoachOutput] {
        var out: [CoachOutput] = []
        if let speed = input.speed { lastRealSpeed = speed }
        if input.isStill { lastStillTime = input.t }
        if input.signBoxHeight != nil { anySignTime = input.t }
        switch phase {
        case .idle: idle(input, &out)
        case .signCandidate: candidate(input, &out)
        case .approaching: approaching(input, &out)
        case .stopping: stopping(input, &out)
        case .stopped: stopped(input, &out)
        case .departing: departing(input, &out)
        case .evaluate: break // Passed through inside departing(); never rests here.
        }
        lastTime = input.t
        return out
    }

    mutating func reset() {
        phase = .idle
        signFrames = 0
        heights.removeAll()
        ignoreSignsUntil = -.infinity
        anySignTime = -.infinity
    }

    // MARK: Phases

    private mutating func idle(_ input: CoachInput, _ out: inout [CoachOutput]) {
        if input.t < ignoreSignsUntil, input.t - anySignTime >= CoachTuning.lostSeconds {
            ignoreSignsUntil = -.infinity // The handled sign is out of view: end the cooldown early.
        }
        guard input.signBoxHeight != nil, input.t >= ignoreSignsUntil else { return }
        signFrames = 1
        move(to: .signCandidate, &out)
    }

    private mutating func candidate(_ input: CoachInput, _ out: inout [CoachOutput]) {
        guard let height = input.signBoxHeight else { // One missed frame and we start over.
            signFrames = 0
            move(to: .idle, &out)
            return
        }
        signFrames += 1
        heights.append(height)
        lastSignTime = input.t
        guard signFrames >= CoachTuning.candidateFrames else { return }
        if let speed = input.speed, speed < CoachTuning.minApproachSpeed { return } // Seen while parked: wait until we move.
        out.append(.speak("Stop sign ahead, start slowing"))
        resetStop()
        move(to: .approaching, &out)
    }

    private mutating func approaching(_ input: CoachInput, _ out: inout [CoachOutput]) {
        if let height = input.signBoxHeight {
            heights.append(height)
            lastSignTime = input.t
        }
        trackBrake(input)
        if let speed = input.speed, speed < CoachTuning.stoppingSpeed {
            beginStopping(input, &out)
            return
        }
        guard input.signBoxHeight == nil, input.t - lastSignTime > CoachTuning.lostSeconds else { return }
        // The sign has left the frame (it slides out of view before we reach it). A confirmed sign is treated as real, so
        // we never drop back to idle from here: what the car does next decides how this stop is reported.
        let waited = input.t - lastSignTime > CoachTuning.lostWaitSeconds
        if let speed = input.speed {
            if speed <= CoachTuning.lostSignStopSpeed {
                beginStopping(input, &out) // Slow with a sign just behind us: this is the stop.
            } else if waited {
                minSpeed = speed // Never slowed down: a pass-through, not a stop (and too late to speak anyway).
                beginDeparting(input, &out, passedThrough: true)
            } // else: still moving fast, maybe still braking. Keep waiting.
        } else if (heights.last ?? 0) >= CoachTuning.nearBoxHeight {
            beginStopping(input, &out) // No GPS: a big sign vanishing means we reached it.
        } else if waited {
            beginDeparting(input, &out) // No GPS and no clue: minSpeed is nil, so it is logged as unknown.
        }
    }

    private mutating func beginStopping(_ input: CoachInput, _ out: inout [CoachOutput]) {
        stoppingSince = input.t
        stoppedDetector.reset()
        move(to: .stopping, &out)
        stopping(input, &out) // The frame that triggered the stop counts too (its speed is the first lowest-speed sample).
    }

    private mutating func stopping(_ input: CoachInput, _ out: inout [CoachOutput]) {
        trackBrake(input)
        if let speed = input.speed { minSpeed = Swift.min(minSpeed ?? speed, speed) }
        let gpsAgreesStill = input.speed.map { $0 <= CoachTuning.stillMaxSpeed }
            ?? (lastRealSpeed.map { $0 <= CoachTuning.hintMaxPriorSpeed } ?? false)
        if input.t - lastStillTime <= CoachTuning.stillConfirmSeconds, gpsAgreesStill {
            // A full second with no bumps and no turning, and GPS reads slow or nothing (now or one reading later):
            // the car stood still, even if GPS never saw it reach zero. Stillness alone isn't enough: a smooth, steady
            // creep feels exactly like standing still to the phone.
            reachedStop = true
            move(to: .stopped, &out)
            return
        }
        if input.speed == nil, input.stopHint, let last = lastRealSpeed, last <= CoachTuning.hintMaxPriorSpeed {
            // GPS went quiet in the middle of a slowdown: almost always because we stopped. Count it as standing still.
            if stoppedDetector.add(0, at: input.t) {
                reachedStop = true
                move(to: .stopped, &out)
            } else if input.t - stoppingSince > CoachTuning.stoppingTimeout {
                beginDeparting(input, &out)
            }
            return
        }
        guard let speed = input.speed else { // No GPS: we can't tell, so remember how long and break any "stopped" streak.
            unknownSeconds += input.t - lastTime
            stoppedDetector.reset()
            if input.t - stoppingSince > CoachTuning.stoppingTimeout { beginDeparting(input, &out) }
            return
        }
        if stoppedDetector.add(speed, at: input.t) {
            reachedStop = true
            move(to: .stopped, &out)
        } else if speed > CoachTuning.departSpeed, speed > (minSpeed ?? speed) + CoachTuning.riseMargin {
            beginDeparting(input, &out) // Speeding back up without ever stopping.
        } else if input.t - stoppingSince > CoachTuning.stoppingTimeout {
            beginDeparting(input, &out) // Crawling or cruising past the sign.
        }
    }

    private mutating func stopped(_ input: CoachInput, _ out: inout [CoachOutput]) {
        // The look-both-ways window will live here. For now we just wait for the car to move.
        if let speed = input.speed { minSpeed = Swift.min(minSpeed ?? speed, speed) } // Report the true slowest, not the slowest before we decided.
        guard let speed = input.speed, speed > CoachTuning.leaveStoppedSpeed else { return }
        beginDeparting(input, &out)
    }

    // The car is moving again. Decide the outcome now (so a rolling stop is called out right away), then wait in
    // DEPARTING until the car has cleared the sign. The look-both-ways reminder will hook in here.
    private mutating func beginDeparting(_ input: CoachInput, _ out: inout [CoachOutput], passedThrough: Bool = false) {
        if passedThrough {
            pendingOutcome = .passedThrough
        } else if !reachedStop, (heights.max() ?? 0) < CoachTuning.minReachedBoxHeight {
            pendingOutcome = .passedThrough // Slowed (a turn?) but never got near the sign: not a stop at it, so no nag.
        } else if reachedStop {
            pendingOutcome = .fullStop
        } else if minSpeed == nil || unknownSeconds >= CoachTuning.stoppedSeconds {
            pendingOutcome = .unknown // We were blind long enough that a stop could have been hiding in the gap.
        } else if let slowest = minSpeed, slowest <= CoachTuning.almostStoppedSpeed {
            pendingOutcome = .almostStopped // Gray zone: shown on the report card, but not worth nagging about.
        } else {
            pendingOutcome = .rolling
            out.append(.speak("Come to a full stop"))
        }
        departingSince = input.t
        move(to: .departing, &out)
    }

    private mutating func departing(_ input: CoachInput, _ out: inout [CoachOutput]) {
        let cleared = input.speed.map { $0 >= CoachTuning.clearSpeed } ?? false
        guard cleared || input.t - departingSince > CoachTuning.departingTimeout else { return }
        move(to: .evaluate, &out)
        out.append(.result(StopSignResult(outcome: pendingOutcome, minSpeed: minSpeed, peakBrakeG: peakBrake,
                                          boxHeightAtPeakBrake: heightAtPeakBrake)))
        ignoreSignsUntil = input.t + CoachTuning.cooldownSeconds
        move(to: .idle, &out) // EVALUATE only lasts this one step.
    }

    // MARK: Helpers

    private mutating func trackBrake(_ input: CoachInput) {
        guard input.forwardAccel < peakBrake else { return }
        peakBrake = input.forwardAccel
        heightAtPeakBrake = input.signBoxHeight ?? heights.last
    }

    private mutating func resetStop() {
        minSpeed = nil
        reachedStop = false
        unknownSeconds = 0
        peakBrake = 0
        heightAtPeakBrake = nil
    }

    private mutating func move(to next: CoachPhase, _ out: inout [CoachOutput]) {
        out.append(.phaseChanged(from: phase, to: next))
        phase = next
        if next == .idle {
            signFrames = 0
            heights.removeAll()
        }
    }
}
