import AVFoundation

// Tracks how the phone is physically held and rotates a capture connection so frames come out upright.
// Wraps AVCaptureDevice.RotationCoordinator, which is created on the main thread and observed with KVO,
// so the angle keeps updating when the phone is turned even though frames arrive on a background queue.
nonisolated final class CameraRotation: @unchecked Sendable {
    private let lock = NSLock()
    private var angle: CGFloat = 90 // Portrait until the coordinator reports.
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    init(device: AVCaptureDevice) {
        DispatchQueue.main.async {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            self.observation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                self?.set(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
            self.coordinator = coordinator
        }
    }

    private func set(_ value: CGFloat) { lock.lock(); angle = value; lock.unlock() }

    // Degrees: 90 = portrait, 0/180 = landscape.
    func current() -> CGFloat { lock.lock(); defer { lock.unlock() }; return angle }

    // Call per frame; only touches the connection when the angle changed.
    func apply(to connection: AVCaptureConnection) {
        let target = current()
        if connection.videoRotationAngle != target, connection.isVideoRotationAngleSupported(target) {
            connection.videoRotationAngle = target
        }
    }
}
