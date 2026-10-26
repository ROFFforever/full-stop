import Foundation

// Small, pure signal-cleaning tools. No iOS frameworks, so they can be replayed on recorded data.

// Keeps the last `size` samples and returns the middle one. Kills one-off spikes, keeps real edges.
struct MedianFilter {
    let size: Int
    private var window: [Double] = []

    init(size: Int = 5) { self.size = size }

    mutating func add(_ value: Double) -> Double {
        window.append(value)
        if window.count > size { window.removeFirst() } // Forget the oldest sample.
        return window.sorted()[window.count / 2] // Middle of the sorted window.
    }

    mutating func reset() { window.removeAll() }
}

// Exponential moving average: each new sample pulls the output `alpha` of the way toward it.
struct ExponentialSmoother {
    let alpha: Double // Small = smoother but slower; large = faster but noisier.
    private(set) var value: Double?

    init(alpha: Double = 0.25) { self.alpha = alpha }

    mutating func add(_ sample: Double) -> Double {
        let next = value.map { $0 + alpha * (sample - $0) } ?? sample // First sample starts the average.
        value = next
        return next
    }

    mutating func reset() { value = nil }
}

// Fires once when a signal stays past a threshold for `duration` seconds. One bump can't trigger it.
struct SustainDetector {
    enum Direction { case below, above }

    let threshold: Double
    let direction: Direction
    let duration: TimeInterval
    private var startedAt: TimeInterval? // When the signal first crossed the threshold.
    private var fired = false // Stays true until the signal recovers, so one brake = one event.

    init(threshold: Double, direction: Direction, duration: TimeInterval) {
        self.threshold = threshold
        self.direction = direction
        self.duration = duration
    }

    // Returns true on the single update where the condition has held long enough.
    mutating func add(_ value: Double, at time: TimeInterval) -> Bool {
        let beyond = direction == .below ? value < threshold : value > threshold
        guard beyond else { // Signal recovered: re-arm.
            startedAt = nil
            fired = false
            return false
        }
        if startedAt == nil { startedAt = time }
        if !fired, let start = startedAt, time - start >= duration {
            fired = true
            return true
        }
        return false
    }

    mutating func reset() { startedAt = nil; fired = false }
}

// 3D vector helpers (phone-frame acceleration and gravity).
extension SIMD3 where Scalar == Double {
    func dot(_ other: Self) -> Double { (self * other).sum() }
    var length: Double { dot(self).squareRoot() }
    var normalized: Self? { length > 1e-9 ? self / length : nil }
    func degrees(to other: Self) -> Double { // Angle between two unit vectors.
        acos(Swift.min(Swift.max(dot(other), -1), 1)) * 180 / .pi
    }
}

// Learns which direction, in the phone's own axes, is "car forward". Feed it moments when GPS saw the speed change
// while driving straight: each adds (GPS accel × average horizontal phone accel). Sideways and bump noise point
// every which way and cancel; the forward direction keeps adding up. The sign comes for free: the result points
// where speeding up reads positive.
struct AxisLearner {
    private var sum = SIMD3<Double>.zero
    private var weight = 0.0 // Sum of |GPS accel| × |phone accel|. Equals |sum| only if every sample agreed.
    private(set) var samples = 0

    var coherence: Double { weight > 0 ? sum.length / weight : 0 } // 1 = all samples pointed the same way.
    var axis: SIMD3<Double>? { sum.normalized }

    mutating func add(gpsAccel: Double, phoneAccel: SIMD3<Double>) {
        sum += gpsAccel * phoneAccel
        weight += abs(gpsAccel) * phoneAccel.length
        samples += 1
    }

    mutating func reset() { sum = .zero; weight = 0; samples = 0 }
}

// Says when the phone (and so the car) has been still for a full window: no bumps, no swaying, no turning.
// A stopped car only shakes from the idling engine. Feed it every motion sample: user acceleration (g, gravity
// removed) and rotation rate (rad/s), any axes. Works without GPS and without knowing which way is forward.
// Limits come from 4 recordings: over 1 s, moving never got below 62 mg / 56 mrad/s (1,227 samples), while
// real stops sat at 20-50 mg / 20-35 mrad/s.
struct StillnessMeter {
    static let window = 1.0 // s.
    static let maxAccelRMS = 0.06 // g.
    static let maxRotationRMS = 0.06 // rad/s.

    private var samples: [(t: Double, accel2: Double, rotation2: Double)] = [] // Squared magnitudes, oldest first.

    mutating func add(t: Double, accel: SIMD3<Double>, rotation: SIMD3<Double>) {
        samples.append((t, accel.dot(accel), rotation.dot(rotation)))
        while let first = samples.first, t - first.t > Self.window { samples.removeFirst() }
    }

    // True once a whole window of samples is quiet on both sensors.
    var isStill: Bool {
        guard let first = samples.first, let last = samples.last, last.t - first.t >= Self.window * 0.9, samples.count >= 10 else { return false }
        let n = Double(samples.count)
        let accelRMS = (samples.reduce(0) { $0 + $1.accel2 } / n).squareRoot()
        let rotationRMS = (samples.reduce(0) { $0 + $1.rotation2 } / n).squareRoot()
        return accelRMS < Self.maxAccelRMS && rotationRMS < Self.maxRotationRMS
    }

    mutating func reset() { samples.removeAll() }
}
