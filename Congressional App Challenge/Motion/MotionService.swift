import CoreMotion // Sensor-fused device motion (gravity removed, orientation known).
import CoreLocation // GPS speed and direction of travel.
import Combine // ObservableObject/@Published.

// A braking or acceleration event worth logging on the report card.
struct DriveEvent: Identifiable {
    enum Kind { case hardBrake, hardAccel }
    let id = UUID()
    let kind: Kind
    let accel: Double // Filtered forward acceleration when it fired, in g.
    let speed: Double? // GPS speed at that moment, m/s.
    let date: Date
}

// Starting values from the plan; tune them on recorded drives.
enum MotionTuning {
    static let sampleRate = 50.0 // Hz.
    static let maxPlausibleG = 1.2 // A car can't do more, so anything bigger is a bump or a jostle.
    static let medianSize = 5 // 0.1 s of samples.
    static let smoothing = 0.25 // EMA alpha.
    static let hardBrakeG = -0.3
    static let hardAccelG = 0.3
    static let sustainSeconds = 0.3 // Must hold past the threshold this long.
    static let minCourseSpeed = 2.0 // m/s. Below this GPS course is unreliable, so we can't tell if we're driving straight.
    static let maxSpeedAccuracy = 3.0 // m/s. Worse GPS speed readings are discarded. (1.5 rejected about half of real fixes under trees.)
    static let disagreeG = 0.15 // GPS and accelerometer differing by more than this is suspicious.

    // Learning the forward axis (checked on three recorded drives: locks in 15-60 s, within 1-5° of the camera guess).
    static let learnMinG = 0.04 // GPS speed change needed for a one-second interval to teach anything.
    static let learnMaxTurnDegrees = 3.0 // Course change allowed between fixes to count as driving straight.
    static let lockSamples = 8 // Straight speed-change intervals before the learned axis replaces the camera guess.
    static let lockCoherence = 0.7 // 1 = every interval pointed the same way.
    static let recheckSamples = 30 // After locking, a fresh estimate is compared every this many intervals...
    static let relockDegrees = 20.0 // ...and replaces the axis if it is this far off (phone twisted in the mount). 20/15 relocked falsely on a real drive.
    static let mountMovedDegrees = 10.0 // Gravity moving this far in phone axes = the mount tilted: learn again.
}

// Publishes the car's forward acceleration (g, + = speeding up) and GPS speed (m/s), and flags hard events.
//
// How "forward" is found: the phone is fixed to the car, so the car's forward direction is one constant vector in the
// phone's own axes. Until it is learned, we guess it from the back camera (it faces the road), levelled with gravity.
// Meanwhile, every GPS interval of straight-line speeding up or braking teaches the true direction (AxisLearner);
// once there is enough evidence the learned axis is locked in. Each sample is then one dot product: no compass,
// no GPS course, and it works at any speed, including the last few m/s of a stop.
@MainActor
final class MotionService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var forwardAccel = 0.0 // Cleaned, in g.
    @Published private(set) var speed: Double? // m/s from GPS, nil when invalid.
    @Published private(set) var events: [DriveEvent] = []
    @Published private(set) var sensorsAgree = true // Diagnostic: GPS vs accelerometer cross-check.
    @Published private(set) var status = "Stopped"
    @Published private(set) var running = false

    var log: CSVLog? // Set by the drive recorder to capture every sample.

    // For the stop-sign coach (not @Published: read once per camera frame, no need to redraw the screen 50x a second).
    private(set) var stopHint = false // Latest GPS fix had no usable speed in the "standing still" way (see GPSSpeed).
    private var lastFixUptime: Double? // When the latest GPS fix arrived.
    private var stillness = StillnessMeter() // Fed every motion sample.
    var isStill: Bool { stillness.isStill }
    // GPS speed, or nil if the latest fix is older than this (GPS dropped out under a bridge, say). Same rule as the replay tool.
    static let speedStaleSeconds = 2.0
    // For the hour log.
    private(set) var distance = 0.0 // Meters driven this session (GPS).
    private(set) var firstCoordinate: CLLocationCoordinate2D? // Where the drive started (for sunset/sunrise).
    private var lastPosition: CLLocation? // Last fix good enough to measure distance from.
    static let maxPositionError = 25.0 // m. Worse fixes don't count toward distance.
    static let minMovingSpeed = 1.0 // m/s. Below this, position jitter would add fake distance at a standstill.

    func freshGPS(now: Double) -> (speed: Double?, stopHint: Bool) {
        guard let lastFixUptime, now - lastFixUptime <= Self.speedStaleSeconds else { return (nil, false) }
        return (speed, stopHint)
    }
    private let motion = CMMotionManager()
    private let location = CLLocationManager()

    private var median = MedianFilter(size: MotionTuning.medianSize)
    private var smoother = ExponentialSmoother(alpha: MotionTuning.smoothing)
    private var brake = SustainDetector(threshold: MotionTuning.hardBrakeG, direction: .below, duration: MotionTuning.sustainSeconds)
    private var accelerate = SustainDetector(threshold: MotionTuning.hardAccelG, direction: .above, duration: MotionTuning.sustainSeconds)
    private var lastGoodSample = 0.0 // Substituted when a sample fails the clamp.

    // Forward axis, all in phone coordinates.
    private var learner = AxisLearner() // Everything seen since the mount last moved.
    private var recheck = AxisLearner() // Fresh evidence since the last check, to catch the phone twisting in the mount.
    private var lockedAxis: SIMD3<Double>? // nil = still using the camera guess.
    private var down: SIMD3<Double>? // Smoothed gravity direction (about 1 s).
    private var downAtLock: SIMD3<Double>? // Gravity when the axis was locked; a big change means the mount moved.

    // Between two GPS fixes: average accel for the cross-check, and average horizontal accel for learning.
    private var accelSum = 0.0
    private var accelCount = 0
    private var horizontalSum = SIMD3<Double>.zero
    private var horizontalCount = 0
    private var previousFix: (speed: Double, time: Date, course: Double?)?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !running else { return }
        guard motion.isDeviceMotionAvailable else { status = "No motion sensors (simulator?)"; return }
        resetFilters()
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        motion.deviceMotionUpdateInterval = 1 / MotionTuning.sampleRate
        // Arbitrary heading: we only need gravity and phone-frame acceleration, so no compass (cars confuse it anyway).
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated { self?.handle(data) } // Delivered on the main queue.
        }
        running = true
        status = "Starting"
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        running = false
        status = "Stopped"
    }

    private func resetFilters() {
        median.reset(); smoother.reset(); brake.reset(); accelerate.reset()
        lastGoodSample = 0; accelSum = 0; accelCount = 0; horizontalSum = .zero; horizontalCount = 0; previousFix = nil
        learner.reset(); recheck.reset(); lockedAxis = nil; down = nil; downAtLock = nil
        forwardAccel = 0; speed = nil; events = []; sensorsAgree = true
        stopHint = false; lastFixUptime = nil; stillness.reset()
        distance = 0; firstCoordinate = nil; lastPosition = nil
    }

    // MARK: Motion (50 Hz)

    private func handle(_ data: CMDeviceMotion) {
        var forwardRaw: Double? // Projected onto the forward axis, before any cleaning.
        var forwardClean: Double? // After clamp, median and EMA.
        defer { logMotion(data, forwardRaw, forwardClean) } // Every sample is logged, tracking or not.
        stillness.add(t: data.timestamp, accel: SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z),
                      rotation: SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z))

        // 1. Gravity says which way is down in phone axes. Smooth it so one jolt doesn't move it.
        let a = SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z)
        guard let gravity = SIMD3(data.gravity.x, data.gravity.y, data.gravity.z).normalized else { return }
        let smoothed = down.map { $0 + 0.02 * (gravity - $0) } ?? gravity
        guard let down = smoothed.normalized else { return }
        self.down = down
        checkMount(down)

        // 2. The level (horizontal) part of the acceleration, for learning the axis. Bumps are vertical and drop out.
        horizontalSum += a - a.dot(down) * down
        horizontalCount += 1

        // 3. Forward = acceleration along the forward axis. Core Motion's userAcceleration points opposite to the car's
        //    true acceleration (checked against GPS speed on real drives), and the camera looks along -Z, so the guess
        //    is +Z. The learned axis needs no such reasoning: it already points where speeding up reads positive.
        guard let axis = lockedAxis ?? cameraGuess(down) else {
            status = "Phone is lying flat: can't tell forward"
            median.reset(); smoother.reset(); brake.reset(); accelerate.reset()
            forwardAccel = 0
            return
        }
        status = lockedAxis == nil ? "Tracking (camera guess, learning \(learner.samples)/\(MotionTuning.lockSamples))" : "Tracking"
        var forward = a.dot(axis)
        forwardRaw = forward

        // 4. Clean it up: clamp -> median -> EMA -> sustain.
        if abs(forward) > MotionTuning.maxPlausibleG { forward = lastGoodSample } // Impossible: reject.
        lastGoodSample = forward
        let cleaned = smoother.add(median.add(forward))
        forwardAccel = cleaned
        forwardClean = cleaned
        accelSum += cleaned; accelCount += 1

        let t = data.timestamp
        if brake.add(cleaned, at: t) { record(.hardBrake, cleaned) }
        if accelerate.add(cleaned, at: t) { record(.hardAccel, cleaned) }
    }

    // The phone's +Z axis, levelled. nil when the phone lies flat (camera facing the floor or sky).
    private func cameraGuess(_ down: SIMD3<Double>) -> SIMD3<Double>? {
        let z = SIMD3<Double>(0, 0, 1)
        let level = z - z.dot(down) * down
        return level.length > 0.3 ? level.normalized : nil
    }

    // Gravity moving in phone axes means the phone tilted in its mount, so the learned axis is stale.
    private func checkMount(_ down: SIMD3<Double>) {
        guard let downAtLock, down.degrees(to: downAtLock) > MotionTuning.mountMovedDegrees else { return }
        logAxis(nil, "mount moved \(Int(down.degrees(to: downAtLock)))°: back to camera guess")
        learner.reset(); recheck.reset(); lockedAxis = nil; self.downAtLock = nil
    }

    // One GPS interval of evidence. Only straight-line speed changes are useful: in a turn, sideways force pollutes it.
    private func learn(gpsAccel: Double, horizontal: SIMD3<Double>, turned: Double?, slowest: Double) {
        guard let turned, turned <= MotionTuning.learnMaxTurnDegrees, slowest >= MotionTuning.minCourseSpeed,
              abs(gpsAccel) >= MotionTuning.learnMinG else { return }
        learner.add(gpsAccel: gpsAccel, phoneAccel: horizontal)

        guard let locked = lockedAxis else {
            if learner.samples >= MotionTuning.lockSamples, learner.coherence >= MotionTuning.lockCoherence, let axis = learner.axis {
                lock(axis, "locked")
            }
            return
        }
        // Locked: keep refining with all the evidence, and separately check recent evidence for a sudden twist.
        recheck.add(gpsAccel: gpsAccel, phoneAccel: horizontal)
        if recheck.samples >= MotionTuning.recheckSamples {
            if recheck.coherence >= MotionTuning.lockCoherence, let fresh = recheck.axis, fresh.degrees(to: locked) > MotionTuning.relockDegrees {
                learner = recheck // The old evidence describes the old mount position.
                lock(fresh, "relocked: phone twisted \(Int(fresh.degrees(to: locked)))° in mount")
            }
            recheck.reset()
        } else if learner.coherence >= MotionTuning.lockCoherence, let axis = learner.axis {
            lockedAxis = axis
        }
    }

    private func lock(_ axis: SIMD3<Double>, _ note: String) {
        lockedAxis = axis
        downAtLock = down
        let guess = down.flatMap(cameraGuess).map { String(format: ", %.1f° from camera guess", axis.degrees(to: $0)) } ?? ""
        logAxis(axis, "\(note) after \(learner.samples) samples" + String(format: ", coherence %.2f", learner.coherence) + guess)
    }

    private func logAxis(_ axis: SIMD3<Double>?, _ note: String) {
        var fields = ["note": note]
        if let axis { fields["fx"] = CSVLog.num(axis.x); fields["fy"] = CSVLog.num(axis.y); fields["fz"] = CSVLog.num(axis.z) }
        log?.write(t: ProcessInfo.processInfo.systemUptime, kind: "axis", fields)
    }

    private func logMotion(_ data: CMDeviceMotion, _ forwardRaw: Double?, _ forwardClean: Double?) {
        guard let log else { return }
        let a = data.userAcceleration, g = data.gravity, r = data.rotationRate, att = data.attitude, m = att.rotationMatrix
        func n(_ v: Double) -> String { CSVLog.num(v) }
        var fields = [
            "ax": n(a.x), "ay": n(a.y), "az": n(a.z), "gx": n(g.x), "gy": n(g.y), "gz": n(g.z),
            "rx": n(r.x), "ry": n(r.y), "rz": n(r.z), "roll": n(att.roll), "pitch": n(att.pitch), "yaw": n(att.yaw),
            "m11": n(m.m11), "m12": n(m.m12), "m13": n(m.m13), "m21": n(m.m21), "m22": n(m.m22), "m23": n(m.m23),
            "m31": n(m.m31), "m32": n(m.m32), "m33": n(m.m33),
        ]
        if let forwardRaw { fields["fwd_raw"] = n(forwardRaw) }
        if let forwardClean { fields["fwd"] = n(forwardClean) }
        log.write(t: data.timestamp, kind: "motion", fields)
    }

    private func record(_ kind: DriveEvent.Kind, _ accel: Double) {
        events.append(DriveEvent(kind: kind, accel: accel, speed: speed, date: Date()))
        log?.write(t: ProcessInfo.processInfo.systemUptime, kind: "event",
                   ["note": kind == .hardBrake ? "hardBrake" : "hardAccel", "fwd": CSVLog.num(accel), "speed": speed.map { CSVLog.num($0, 2) } ?? ""])
    }

    // MARK: GPS (about 1 Hz)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in self.handle(fix) }
    }

    private func addDistance(_ fix: CLLocation, speed: Double?) {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxPositionError else { return }
        if firstCoordinate == nil { firstCoordinate = fix.coordinate }
        defer { lastPosition = fix }
        guard let last = lastPosition, let speed, speed >= Self.minMovingSpeed else { return }
        let step = fix.distance(from: last), dt = fix.timestamp.timeIntervalSince(last.timestamp)
        if dt > 0, step / dt < 70 { distance += step } // 70 m/s = 157 mph: anything faster is a GPS jump.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = "GPS error: \(error.localizedDescription)" }
    }

    private func handle(_ fix: CLLocation) {
        let now = ProcessInfo.processInfo.systemUptime
        let age = Date().timeIntervalSince(fix.timestamp) // How old the fix already is; GPS lags.
        log?.write(t: now, kind: "gps", [
            "speed": CSVLog.num(fix.speed, 3), "speed_acc": CSVLog.num(fix.speedAccuracy, 3), "course": CSVLog.num(fix.course, 1),
            "lat": CSVLog.num(fix.coordinate.latitude, 6), "lon": CSVLog.num(fix.coordinate.longitude, 6),
            "h_acc": CSVLog.num(fix.horizontalAccuracy, 1), "gps_age": CSVLog.num(age, 2),
        ])
        // Negative speed or accuracy means "invalid" in Core Location. An unusable speed can still hint "stopped".
        let reading = GPSSpeed.read(speed: fix.speed, accuracy: fix.speedAccuracy)
        let valid = reading.speed != nil
        speed = reading.speed
        stopHint = reading.stopHint
        lastFixUptime = now
        addDistance(fix, speed: reading.speed)
        let course = (valid && fix.course >= 0) ? fix.course : nil
        guard valid else { previousFix = nil; return }

        if let previous = previousFix {
            let dt = fix.timestamp.timeIntervalSince(previous.time)
            if dt > 0 {
                let gpsAccel = (fix.speed - previous.speed) / dt / 9.81 // m/s^2 -> g.
                // Cross-check: speed change over the last interval should match the average accelerometer reading.
                if accelCount > 0 { sensorsAgree = abs(gpsAccel - accelSum / Double(accelCount)) <= MotionTuning.disagreeG }
                if horizontalCount > 0 {
                    // Course difference wrapped to -180...180, so 359° -> 1° counts as a 2° turn.
                    let turned = course.flatMap { current in previous.course.map { abs((current - $0 + 540).truncatingRemainder(dividingBy: 360) - 180) } }
                    learn(gpsAccel: gpsAccel, horizontal: horizontalSum / Double(horizontalCount), turned: turned, slowest: min(fix.speed, previous.speed))
                }
            }
        }
        previousFix = (fix.speed, fix.timestamp, course)
        accelSum = 0; accelCount = 0; horizontalSum = .zero; horizontalCount = 0
    }
}
