import AVFoundation
import CoreVideo
import Foundation

/// What the capture session tells the agent about the Cam Link.
enum CaptureEvent {
    /// Frames are flowing: the first one after a start, or the first one
    /// after a stall.
    case healthy
    /// The session is open but the device isn't delivering. This is the
    /// wedge signal: we're the Cam Link's only client, so no frames here is
    /// exactly what the meeting app would have seen.
    case unhealthy(String)
    /// The device left the bus.
    case disconnected
    /// The device (re)appeared on the bus.
    case connected
}

/// CamLinkCapture holds the one and only session on the real Cam Link. It
/// runs only while some app wants the virtual camera, scales frames to the
/// virtual camera's 1080p BGRA format, and hands them to `onFrame`. It judges
/// health only from its own frames; deciding what to do about it is the
/// agent's job.
final class CamLinkCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let deviceName: String
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onEvent: ((CaptureEvent) -> Void)?

    private let queue = DispatchQueue(label: "camlink-host.capture", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var sessionObservers: [NSObjectProtocol] = []
    private var deviceObservers: [NSObjectProtocol] = []

    // Only touched on `queue`.
    private var startedAt: UInt64 = 0
    private var lastFrame: UInt64 = 0
    private var lastSent: UInt64 = 0
    private var frames = 0
    private var unhealthy = false
    private var watchdog: DispatchSourceTimer?

    // Cam Link with a 1080p60 source delivers ~60fps; the virtual camera
    // advertises 30, so send every other frame-ish. Slightly under 1/30s so
    // jitter doesn't knock us down to 20.
    private static let minSendInterval: UInt64 = 30_000_000
    // A healthy Cam Link delivers its first frame in ~100-250ms and then
    // never pauses, so these are generous. Tune once real wedges are logged.
    private static let firstFrameDeadline: UInt64 = 4_000_000_000
    private static let stallAfter: UInt64 = 2_000_000_000

    init(deviceName: String) {
        self.deviceName = deviceName
        super.init()
        watchBus()
    }

    var isRunning: Bool { session != nil }

    var isDevicePresent: Bool { findDevice() != nil }

    func start() {
        guard session == nil else { return }
        guard let device = findDevice() else {
            log.error("capture: \(self.deviceName, privacy: .public) not found")
            onEvent?(.disconnected)
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                log.error("capture: can't add input for \(device.localizedName, privacy: .public)")
                onEvent?(.unhealthy("can't add input"))
                return
            }
            session.addInput(input)
        } catch {
            log.error("capture: opening \(device.localizedName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            onEvent?(.unhealthy("open failed: \(error.localizedDescription)"))
            return
        }

        let output = AVCaptureVideoDataOutput()
        // AVFoundation scales and converts for us on macOS. BGRA keeps the
        // extension simple for now; NV12 end to end would be cheaper.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            log.error("capture: can't add video output")
            onEvent?(.unhealthy("can't add output"))
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        observe(session)
        self.session = session
        log.info("capture: starting \(device.localizedName, privacy: .public) (\(device.activeFormat.description, privacy: .public))")
        queue.async { [self] in
            startedAt = nowNanos()
            lastFrame = 0
            frames = 0
            unhealthy = false
            startWatchdog()
            // startRunning blocks until the device is streaming, so it stays
            // on the capture queue rather than the caller's.
            session.startRunning()
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        queue.async { [self] in
            watchdog?.cancel()
            watchdog = nil
            session.stopRunning()
            log.info("capture: stopped after \(self.frames) frames")
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = nowNanos()
        if frames == 0 {
            log.info("capture: first frame after \((now - self.startedAt) / 1_000_000)ms")
            onEvent?(.healthy)
        } else if unhealthy {
            log.info("capture: frames resumed after \((now - self.lastFrame) / 1_000_000)ms gap")
            onEvent?(.healthy)
        }
        unhealthy = false
        frames += 1
        lastFrame = now

        guard now - lastSent >= Self.minSendInterval,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastSent = now
        onFrame?(pixelBuffer)
    }

    // MARK: health

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkHealth() }
        t.resume()
        watchdog = t
    }

    private func checkHealth() {
        guard !unhealthy else { return }
        let now = nowNanos()
        let reason: String
        if lastFrame == 0 {
            guard now - startedAt > Self.firstFrameDeadline else { return }
            reason = "no first frame \((now - startedAt) / 1_000_000)ms after start"
        } else {
            guard now - lastFrame > Self.stallAfter else { return }
            reason = "no frames for \((now - lastFrame) / 1_000_000)ms after \(frames) frames"
        }
        unhealthy = true
        log.error("capture: STALL \(reason, privacy: .public)")
        onEvent?(.unhealthy(reason))
    }

    private func observe(_ session: AVCaptureSession) {
        let nc = NotificationCenter.default
        sessionObservers = [
            nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let desc = "\(err?.localizedDescription ?? "?") (\(err?.domain ?? "?") \(err?.code ?? 0))"
                log.error("capture: session runtime error: \(desc, privacy: .public)")
                self?.onEvent?(.unhealthy("session error: \(desc)"))
            },
            nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
                log.error("capture: session interrupted")
            },
            nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                log.info("capture: session interruption ended")
            },
        ]
    }

    /// Bus arrivals and departures matter whether or not we're capturing:
    /// a replug while the card is up should bring video straight back.
    private func watchBus() {
        let nc = NotificationCenter.default
        deviceObservers = [
            nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, (note.object as? AVCaptureDevice)?.localizedName == self.deviceName else { return }
                log.info("capture: \(self.deviceName, privacy: .public) disconnected")
                self.onEvent?(.disconnected)
            },
            nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, (note.object as? AVCaptureDevice)?.localizedName == self.deviceName else { return }
                log.info("capture: \(self.deviceName, privacy: .public) connected")
                self.onEvent?(.connected)
            },
        ]
    }

    private func findDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first { $0.localizedName == deviceName }
    }
}
