import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// FrameDump grabs a few seconds of frames from the Cam Link exactly as the
/// agent sees them (scaled to 1080p BGRA by CameraCapture) and writes them
/// to a directory: a PNG and raw BGRA of the first, middle and last frame,
/// plus one line per frame with its hash, how much it moved since the
/// previous one, and what the hold detector makes of it. It's how we learn
/// what the Cam Link sends in a given state, and how to refresh
/// FrameSample.noSignal: run it with the camera off and paste the sample it
/// prints.
///
/// Run it through LaunchServices so TCC treats it as Understudy (a shell
/// launch asks on behalf of the terminal instead):
///
///     open -n -W --stdout OUT /Applications/Understudy.app --args dump-frames DIR [SECONDS]
enum FrameDump {
    static func run(to dir: URL, seconds: Double, deviceName: String) -> Never {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("can't create \(dir.path): \(error.localizedDescription)")
            exit(1)
        }

        let capture = CameraCapture(deviceName: deviceName)
        // A full 1080p frame is 8MB, so keep only the ones we write out.
        // Touched on the capture queue until stop() has drained it.
        var kept: [(name: String, pixels: [UInt8])] = []
        var previous: [UInt8]?
        var hashes = Set<UInt64>()
        var lines: [String] = []
        var firstSample: FrameSample?
        var previousSample: FrameSample?
        let started = nowNanos()
        let middleAt = UInt64(seconds * 500_000_000)

        capture.holdsFrames = false
        capture.onEvent = { event in print("event: \(event)") }
        capture.onFrame = { buffer in
            let pixels = packed(buffer)
            let elapsed = nowNanos() - started
            let hash = fnv1a(pixels)
            let moved = previous.map { meanDifference($0, pixels) } ?? 0
            let sample = FrameSample(buffer)
            let verdict =
                sample?.isNoSignal == true ? "no-signal" : sample != nil && sample == previousSample ? "frozen" : ""
            firstSample = firstSample ?? sample
            previousSample = sample
            lines.append(
                String(format: "%5d  %5dms  %016llx  moved=%.3f  ", lines.count, elapsed / 1_000_000, hash, moved)
                    + verdict)
            hashes.insert(hash)
            if previous == nil {
                kept.append(("first", pixels))
            } else if elapsed >= middleAt, !kept.contains(where: { $0.name == "middle" }) {
                kept.append(("middle", pixels))
            }
            previous = pixels
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("camera access not granted to Understudy (status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
            exit(1)
        }
        capture.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            capture.stop()
            // stop() drains on the capture queue; give it a beat so no frame
            // lands while we write.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let previous { kept.append(("last", previous)) }
                write(kept, lines, distinct: hashes.count, to: dir)
                if let firstSample {
                    try? firstSample.base64.write(
                        to: dir.appendingPathComponent("sample.b64"), atomically: true, encoding: .utf8)
                    print("first frame's sample (FrameSample.noSignal format), also in sample.b64:")
                    print(firstSample.base64)
                }
                exit(lines.isEmpty ? 1 : 0)
            }
        }
        dispatchMain()
    }

    private static func write(
        _ kept: [(name: String, pixels: [UInt8])], _ lines: [String], distinct: Int, to dir: URL
    ) {
        let summary = lines.joined(separator: "\n") + "\n"
        try? summary.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        print(summary, terminator: "")
        print("\(lines.count) frames, \(distinct) distinct")

        for (name, pixels) in kept {
            try? Data(pixels).write(to: dir.appendingPathComponent("\(name).bgra"))
            writePNG(pixels, to: dir.appendingPathComponent("\(name).png"))
        }
        print("wrote \(kept.map(\.name).joined(separator: "/")) .png and .bgra to \(dir.path)")
    }

    /// Copies a BGRA buffer into a tightly packed array, dropping any row
    /// padding so frames compare and save byte for byte.
    private static func packed(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let rowBytes = width * 4
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        out.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                (dst.baseAddress! + row * rowBytes).copyMemory(from: base + row * stride, byteCount: rowBytes)
            }
        }
        return out
    }

    /// Mean absolute difference per byte, 0-255. Sensor noise on a live
    /// camera keeps this above zero even when nothing in the room moves.
    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    private static func writePNG(_ pixels: [UInt8], to url: URL) {
        let width = 1920, height = 1080
        guard pixels.count == width * height * 4,
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
