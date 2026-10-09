import AVFoundation
import CoreMedia
import UnderstudyShared

/// StreamStats watches the preview's frames and boils each second down to a
/// few numbers for the status bar.
final class StreamStats: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Snapshot: Equatable {
        var fps = 0.0
        var width = 0
        var height = 0
        var format = ""
        /// Longest wait between two frames, which is where stutter shows.
        var maxGapMs: Double?
        /// From the agent sending a frame to it reaching us. The extension
        /// passes live frames through with the agent's host-clock timestamp,
        /// so this is Understudy's own relay delay; it isn't meaningful for
        /// the card, which the extension stamps as it draws.
        var latencyMs: Double?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var frames = 0
    private var lastArrival: Double?
    private var maxGap = 0.0
    private var latencyTotal = 0.0
    private var latencyCount = 0
    private var width = 0
    private var height = 0
    private var format = ""
    private var windowStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let description = CMSampleBufferGetFormatDescription(sample)
        lock.withLock {
            frames += 1
            if let lastArrival { maxGap = max(maxGap, now - lastArrival) }
            lastArrival = now
            // Anything outside this range is a timestamp from some other
            // clock, not a delay.
            let latency = now - pts
            if latency >= 0, latency < 2 {
                latencyTotal += latency
                latencyCount += 1
            }
            if let description {
                let dims = CMVideoFormatDescriptionGetDimensions(description)
                width = Int(dims.width)
                height = Int(dims.height)
                format = Self.fourCC(CMFormatDescriptionGetMediaSubType(description))
            }
        }
    }

    /// The numbers since the last call, then starts a new window.
    func take() -> Snapshot {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        return lock.withLock {
            defer {
                frames = 0
                maxGap = 0
                latencyTotal = 0
                latencyCount = 0
                windowStart = now
            }
            let elapsed = max(now - windowStart, 0.001)
            return Snapshot(
                fps: Double(frames) / elapsed, width: width, height: height, format: format,
                maxGapMs: frames > 1 ? maxGap * 1000 : nil,
                latencyMs: latencyCount > 0 ? latencyTotal / Double(latencyCount) * 1000 : nil)
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> $0))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

/// What the agent says it's doing, from the extension's 'stat' property.
/// Empty means nothing special: live video when frames are flowing.
enum AgentStatus {
    static func read() -> String? {
        guard let device = CMIO.virtualCamera() else { return nil }
        return try? CMIO.string(device, CMIO.statusSelector)
    }

    /// The card's reason in words, or nil for live video.
    static func describe(_ status: String) -> String? {
        switch status {
        case "": nil
        case "no-signal": "camera has no signal"
        case "frozen": "camera picture frozen"
        case "reconnecting": "resetting the camera"
        case "not-connected": "camera not connected"
        case "gave-up": "camera didn't recover"
        default: status
        }
    }
}
