import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnderstudyShared

/// RenderEffect runs a clip or still through the same EffectChain the agent
/// uses, so effects can be tuned without a meeting. Stills (a dump-frames
/// PNG, say) come out as PNG; anything else is read as video and written as
/// an H.264 .mov at the source's size and timing, without audio. It reads
/// effects.json unless given a settings file, and never touches a camera.
///
///     understudy render-effect IN OUT [SETTINGS.json]
enum RenderEffect {
    static func run(input: URL, output: URL, settingsURL: URL?) -> Never {
        let settings: EffectSettings
        do {
            settings = try EffectSettings.load(from: settingsURL ?? EffectSettings.defaultURL)
        } catch {
            print("can't read settings: \(error.localizedDescription)")
            exit(1)
        }
        print("effects: \(settings.summary)")
        if !settings.anyEnabled {
            print("warning: every effect is off, so the output will match the input")
        }
        let chain = EffectChain(settings)

        let isImage = UTType(filenameExtension: input.pathExtension)?.conforms(to: .image) == true
        Task {
            do {
                if isImage {
                    try renderImage(input, to: output, chain)
                } else {
                    try await renderVideo(input, to: output, chain)
                }
            } catch {
                print("render failed: \(error.localizedDescription)")
                exit(1)
            }
            print("wrote \(output.path)")
            exit(0)
        }
        dispatchMain()
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: stills

    private static func renderImage(_ input: URL, to output: URL, _ chain: EffectChain) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw Failure("can't read image \(input.path)") }

        let buffer = try makeBuffer(width: image.width, height: image.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let rendered = chain.apply(buffer)
        CVPixelBufferLockBaseAddress(rendered, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rendered, .readOnly) }
        guard
            let outCtx = CGContext(
                data: CVPixelBufferGetBaseAddress(rendered), width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(rendered),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let result = outCtx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure("can't write \(output.path)") }
        CGImageDestinationAddImage(dest, result, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("can't write \(output.path)") }
    }

    private static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
                == kCVReturnSuccess, let buffer
        else { throw Failure("can't allocate a \(width)x\(height) frame") }
        return buffer
    }

    // MARK: video

    private static func renderVideo(_ input: URL, to output: URL, _ chain: EffectChain) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure("no video track in \(input.path)")
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = naturalSize.applying(transform)
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? Failure("can't read \(input.path)") }
        guard writer.startWriting() else { throw writer.error ?? Failure("can't write \(output.path)") }

        var frames = 0
        var started = false
        var applying: UInt64 = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            let before = nowNanos()
            let rendered = chain.apply(buffer)
            applying += nowNanos() - before
            while !writerInput.isReadyForMoreMediaData { usleep(1000) }
            guard adaptor.append(rendered, withPresentationTime: time) else {
                throw writer.error ?? Failure("writing frame \(frames) failed")
            }
            frames += 1
        }
        if reader.status == .failed { throw reader.error ?? Failure("reading \(input.path) failed") }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure("finishing \(output.path) failed") }
        // The agent has ~33ms a frame at 30fps, shared with capture and the
        // hold detector.
        print(String(format: "%d frames, effects took %.2fms a frame", frames, Double(applying) / Double(max(frames, 1)) / 1e6))
    }
}
