import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// Backdrop is the blurred still the card sits on: a live frame shrunk to
/// 1/8 scale and blurred past recognition. Only this blurred thumbnail is
/// ever kept or written to disk, never a raw frame.
struct Backdrop {
    static let width = 240
    static let height = 135
    // A big kernel at 1/8 scale is a huge one at full size, for a fraction of
    // the cost. Repeated tent passes approximate a Gaussian; each loop below
    // is two, ping-ponging so the result lands back in the first buffer.
    private static let kernel: UInt32 = 31
    private static let passes = 2

    var pixels: [UInt8]

    /// Blurs `frame`, which must be BGRA. vImage's ARGB8888 routines are
    /// channel-agnostic, so BGRA is fine as long as nothing cares which byte
    /// is which.
    static func blur(_ frame: CVPixelBuffer) -> Backdrop? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }

        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(CVPixelBufferGetHeight(frame)),
            width: vImagePixelCount(CVPixelBufferGetWidth(frame)),
            rowBytes: CVPixelBufferGetBytesPerRow(frame))
        var a = [UInt8](repeating: 0, count: width * height * 4)
        var b = a
        a.withUnsafeMutableBytes { aPtr in
            b.withUnsafeMutableBytes { bPtr in
                var dst = buffer(aPtr.baseAddress!)
                var tmp = buffer(bPtr.baseAddress!)
                vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
                for _ in 0..<passes {
                    vImageTentConvolve_ARGB8888(
                        &dst, &tmp, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
                    vImageTentConvolve_ARGB8888(
                        &tmp, &dst, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return Backdrop(pixels: a)
    }

    static func load(from url: URL) -> Backdrop? {
        guard let data = try? Data(contentsOf: url), data.count == width * height * 4 else { return nil }
        return Backdrop(pixels: [UInt8](data))
    }

    func save(to url: URL) throws {
        try Data(pixels).write(to: url, options: .atomic)
    }

    static func buffer(_ data: UnsafeMutableRawPointer) -> vImage_Buffer {
        vImage_Buffer(
            data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: width * 4)
    }
}

/// Card renders the frame we serve when there's no live video to pass
/// through: before the first frame, while the host is resetting the Cam
/// Link, and when it's missing.
///
/// Meeting participants see this, so it says nothing. The background is a
/// backdrop (a blurred, dimmed still of a recent healthy moment) so the call
/// looks paused rather than broken, or plain dark if we've never had video.
/// A slow spinner on top means "working on it". The host's details stay in
/// the log.
final class Card {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private var template: [UInt8]
    private var frameIndex = 0

    /// Whether to draw the spinner. Off when there's nothing to wait for
    /// (Cam Link unplugged, or every reset failed), so nobody watches it
    /// spin forever.
    var spinning = true

    private static let background = (r: 0.08, g: 0.09, b: 0.11)
    private static let dim = 0.35

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.template = [UInt8](repeating: 0, count: width * 4 * height)
        show(nil)
    }

    /// Sets the background: the backdrop scaled up and dimmed, or plain dark
    /// for nil. Runs on a drop to the card, not per frame.
    func show(_ backdrop: Backdrop?) {
        guard var pixels = backdrop?.pixels else {
            withTemplateContext { ctx in
                ctx.setFillColor(CGColor(
                    srgbRed: Self.background.r, green: Self.background.g, blue: Self.background.b, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            return
        }
        pixels.withUnsafeMutableBytes { srcPtr in
            template.withUnsafeMutableBytes { dstPtr in
                var src = Backdrop.buffer(srcPtr.baseAddress!)
                var dst = vImage_Buffer(
                    data: dstPtr.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: bytesPerRow)
                vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        withTemplateContext { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: Self.dim))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Copies the next frame into `buffer`, which must be a BGRA buffer of
    /// the card's dimensions.
    func render(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        // Pool buffers may pad their rows, so copy row by row when strides
        // differ.
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        template.withUnsafeBytes { src in
            if dstStride == bytesPerRow {
                base.copyMemory(from: src.baseAddress!, byteCount: template.count)
            } else {
                for row in 0..<height {
                    (base + row * dstStride).copyMemory(
                        from: src.baseAddress! + row * bytesPerRow, byteCount: bytesPerRow)
                }
            }
        }

        frameIndex += 1
        guard spinning,
            let ctx = Self.context(base, width: width, height: height, bytesPerRow: dstStride)
        else { return }
        drawSpinner(ctx)
    }

    /// A thin arc circling a faint track, about one turn every 1.5s at 30fps.
    /// Slow and quiet on purpose: it reads as "one moment", not "error".
    private func drawSpinner(_ ctx: CGContext) {
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Sized for a 1080p frame that a meeting app will shrink into a tile.
        let radius: CGFloat = 46
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let start = -CGFloat(frameIndex) * (.pi * 2 / 45)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .pi * 0.6, clockwise: false)
        ctx.strokePath()
    }

    private func withTemplateContext(_ body: (CGContext) -> Void) {
        template.withUnsafeMutableBytes { raw in
            guard let ctx = Self.context(raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow)
            else { return }
            body(ctx)
        }
    }

    private static func context(_ data: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
        // premultipliedFirst + byteOrder32Little lays pixels out as BGRA,
        // matching kCVPixelFormatType_32BGRA.
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
