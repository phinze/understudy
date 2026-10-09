import CoreGraphics
import CoreVideo
import Foundation
import UnderstudyShared

/// One frame an effect can read and draw on: a locked BGRA buffer plus a
/// Core Graphics context over the same memory. The context is CG's usual
/// bottom-left origin; `pixels` rows run top down.
struct EffectFrame {
    let pixels: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let context: CGContext
}

protocol Effect: AnyObject {
    /// Called with every new effects.json, and whenever the effect is first
    /// switched on.
    func configure(_ settings: EffectSettings)
    /// Draws onto `frame` in place.
    func render(_ frame: EffectFrame)
}

/// EffectChain runs live frames through whichever effects are on, between
/// the hold detector and the virtual camera. With everything off it hands
/// the camera's buffer straight back; otherwise it copies the frame into a
/// buffer of its own first, since the capture output reuses its buffers.
final class EffectChain {
    private let lock = NSLock()
    private var pending: EffectSettings?

    // Only touched by apply(), which runs on one queue at a time.
    private var settings = EffectSettings()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private let blobs = BlobTracker()

    init(_ settings: EffectSettings = EffectSettings()) {
        pending = settings
    }

    /// Swaps in new settings, from any thread. They take effect on the next
    /// frame.
    func update(_ settings: EffectSettings) {
        lock.withLock { pending = settings }
    }

    /// Returns `source` with the effects drawn on, or `source` itself when
    /// none are on (or when something goes wrong: a frame without effects
    /// beats no frame).
    func apply(_ source: CVPixelBuffer) -> CVPixelBuffer {
        if let next = lock.withLock({ () -> EffectSettings? in defer { pending = nil }; return pending }) {
            settings = next
            blobs.configure(next)
        }
        guard settings.anyEnabled,
            CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
            let out = copy(source)
        else { return source }

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return source }
        let width = CVPixelBufferGetWidth(out)
        let height = CVPixelBufferGetHeight(out)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(out)
        guard
            let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return source }

        let frame = EffectFrame(
            pixels: base.assumingMemoryBound(to: UInt8.self), width: width, height: height,
            bytesPerRow: bytesPerRow, context: context)
        if settings.blobs.enabled { blobs.render(frame) }
        context.flush()
        return out
    }

    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if pool == nil || poolSize != (width, height) {
            // IOSurface-backed, or the buffer can't cross into the camera
            // extension's process.
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(out) else {
            return nil
        }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(out)
        if srcStride == dstStride {
            dst.copyMemory(from: src, byteCount: srcStride * height)
        } else {
            for row in 0..<height {
                (dst + row * dstStride).copyMemory(from: src + row * srcStride, byteCount: width * 4)
            }
        }
        CVBufferPropagateAttachments(source, out)
        return out
    }
}

/// EffectsWatcher keeps an EffectChain in step with effects.json. It watches
/// the directory rather than the file because the control app writes
/// atomically: each save is a new file, and a watch on the old one would go
/// quiet after the first.
final class EffectsWatcher {
    private let url: URL
    private let onChange: (EffectSettings) -> Void
    private let queue = DispatchQueue(label: "understudy.effects")
    private var source: DispatchSourceFileSystemObject?
    private var current: EffectSettings?
    private var reloadScheduled = false

    init(url: URL = EffectSettings.defaultURL, onChange: @escaping (EffectSettings) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else {
                log.error("effects: can't watch \(dir.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
            reload()
        }
    }

    /// Saves tend to arrive as a burst of directory events; read once the
    /// burst is over.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            reloadScheduled = false
            reload()
        }
    }

    private func reload() {
        let settings: EffectSettings
        do {
            settings = try EffectSettings.load(from: url)
        } catch {
            log.error("effects: ignoring unreadable \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard settings != current else { return }
        current = settings
        log.info("effects: \(settings.summary, privacy: .public)")
        onChange(settings)
    }
}

extension EffectSettings {
    /// One line for the log.
    var summary: String {
        guard blobs.enabled else { return "all off" }
        let b = blobs
        return "blobs on (count=\(b.boxCount) reselect=\(b.reselectFrames) threshold=\(b.threshold) invert=\(b.invert) "
            + "lines=\(b.lineProbability) color=\(b.color) labels=\(b.labels.rawValue) seed=\(b.seed))"
    }
}
