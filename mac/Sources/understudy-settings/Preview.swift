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

    let session = AVCaptureSession()
    let layer: AVCaptureVideoPreviewLayer
    private let queue = DispatchQueue(label: "understudy.settings.preview")

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
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async { self.unmirror() }
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

    private func fail(_ message: String) {
        problem = message
        stop()
    }
}

/// The preview on black, with the reason when there's nothing to show.
struct PreviewPane: View {
    let preview: CameraPreview

    var body: some View {
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
