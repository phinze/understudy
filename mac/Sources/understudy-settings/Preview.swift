import AVFoundation
import SwiftUI
import UnderstudyShared

/// CameraPreview watches the Understudy virtual camera, effects and all, the
/// way a meeting would. It's a viewer like any other, so while the window is
/// open the agent keeps the real camera open too.
@Observable
final class CameraPreview {
    private(set) var running = false
    private(set) var problem: String?
    /// The last second of the stream, for the status bar.
    private(set) var stats = StreamStats.Snapshot()
    /// The agent's 'stat' while running; nil if it couldn't be read.
    private(set) var agentStatus: String?

    let session = AVCaptureSession()
    let layer: AVCaptureVideoPreviewLayer
    private let queue = DispatchQueue(label: "understudy.settings.preview")
    private let statsQueue = DispatchQueue(label: "understudy.settings.stats")
    private let collector = StreamStats()
    private var ticker: Timer?

    init() {
        layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .black
    }

    func start() {
        guard !running else { return }
        running = true
        problem = nil
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard self.running else { return }
                guard granted else {
                    self.fail("Camera access is off for Understudy Settings. Allow it in System Settings → Privacy & Security → Camera.")
                    return
                }
                self.attach()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        ticker?.invalidate()
        ticker = nil
        stats = StreamStats.Snapshot()
        agentStatus = nil
        queue.async { [session] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }

    private func attach() {
        guard let device = AVCaptureDevice(uniqueID: virtualCameraUID) else {
            fail("The Understudy camera isn't installed.")
            return
        }
        queue.async { [self] in
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                if session.canAddInput(input) { session.addInput(input) }
                if session.outputs.isEmpty {
                    // A second output beside the preview layer, only to
                    // count and measure frames. Empty settings keep the
                    // stream's own format rather than converting it.
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [:]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(collector, queue: statsQueue)
                    if session.canAddOutput(output) { session.addOutput(output) }
                }
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async {
                    self.unmirror()
                    self.startTicker()
                }
            } catch {
                DispatchQueue.main.async { self.fail("Can't open the Understudy camera: \(error.localizedDescription)") }
            }
        }
    }

    /// This is what the other people in the meeting see, so labels should
    /// read the right way round. The connection only exists once the session
    /// has an input.
    private func unmirror() {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    private func startTicker() {
        ticker?.invalidate()
        _ = collector.take()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            stats = collector.take()
            queue.async {
                let status = AgentStatus.read()
                DispatchQueue.main.async { if self.running { self.agentStatus = status } }
            }
        }
    }

    private func fail(_ message: String) {
        problem = message
        stop()
    }
}

/// The preview on black, with the reason when there's nothing to show,
/// and a status bar underneath.
struct PreviewPane: View {
    let preview: CameraPreview

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PreviewView(preview: preview)
                if let problem = preview.problem {
                    Text(problem)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(32)
                }
            }
            Divider()
            StatusBar(preview: preview)
        }
    }
}

/// One line about the stream: live or the card (and why), then its size,
/// format, frame rate, worst gap between frames, and Understudy's relay
/// delay.
struct StatusBar: View {
    let preview: CameraPreview

    var body: some View {
        HStack(spacing: 14) {
            state
            if preview.running, preview.stats.fps > 0 {
                let s = preview.stats
                // verbatim, or SwiftUI localizes 1920 into "1,920".
                Text(verbatim: "\(s.width)×\(s.height) \(s.format)")
                Text(String(format: "%.1f fps", s.fps))
                if let gap = s.maxGapMs {
                    Text(String(format: "max gap %.0f ms", gap))
                        .foregroundStyle(gap > 100 ? .orange : .secondary)
                }
                if isLive, let latency = s.latencyMs {
                    Text(String(format: "relay %.0f ms", latency))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    private var isLive: Bool { preview.agentStatus.map { $0.isEmpty } ?? false }

    @ViewBuilder private var state: some View {
        if !preview.running {
            label("STOPPED", .gray)
        } else if preview.stats.fps == 0 {
            label("WAITING FOR FRAMES", .gray)
        } else if let status = preview.agentStatus, let reason = AgentStatus.describe(status) {
            label("CARD · \(reason)", .orange)
        } else {
            label("LIVE", .green)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.primary)
        }
    }
}

/// Hosts the preview's layer.
struct PreviewView: NSViewRepresentable {
    let preview: CameraPreview

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = preview.layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
