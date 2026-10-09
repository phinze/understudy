import CoreMedia
import CoreMediaIO
import Foundation
import UnderstudyShared

/// VirtualCamera is the host's view of our own extension's device, through
/// the CoreMediaIO C API: it watches the demand property and writes frames
/// into the sink stream.
final class VirtualCamera {
    static let deviceUID = virtualCameraUID

    let deviceID: CMIOObjectID
    private let sinkStreamID: CMIOStreamID
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private(set) var sinkRunning = false

    /// Finds our device among the system's CMIO devices, or returns nil if
    /// the extension isn't (yet) visible to this process.
    init?() {
        let all = CMIO.devices()
        guard let device = all.first(where: { CMIO.uid(of: $0) == Self.deviceUID }) else {
            log.debug("our device not among \(all.count) CMIO devices: \(all.map { CMIO.uid(of: $0) ?? "?" }, privacy: .public)")
            return nil
        }
        let streams = CMIO.objectIDs(device, selector: kCMIODevicePropertyStreams)
        // Directions are from the system's point of view: a camera's normal
        // stream is 1 (input to the system), so our sink is the 0 (output).
        // Getting this backwards makes the host a second *viewer* of the
        // source stream, which pins demand on forever.
        guard let sink = streams.first(where: { Self.direction(of: $0) == 0 }) else {
            log.error("virtual camera has no sink stream (streams=\(streams), directions=\(streams.map(Self.direction(of:))))")
            return nil
        }
        deviceID = device
        sinkStreamID = sink
    }

    // MARK: demand

    /// The number of apps streaming from the virtual camera, as published
    /// by the extension's 'dmnd' property.
    func demand() -> Int {
        do {
            return Int(try CMIO.string(deviceID, CMIO.demandSelector)) ?? 0
        } catch {
            log.error("reading demand failed: \((error as NSError).code)")
            return 0
        }
    }

    /// Calls `handler` on `queue` whenever the extension says demand changed.
    func onDemandChange(queue: DispatchQueue, _ handler: @escaping () -> Void) {
        var addr = CMIO.address(CMIO.demandSelector)
        let err = CMIOObjectAddPropertyListenerBlock(deviceID, &addr, queue) { _, _ in handler() }
        if err != noErr {
            log.error("listening for demand failed: \(err)")
        }
    }

    /// Tells the extension our state through its writable 'stat' property,
    /// which picks how the card looks. Empty means nothing special.
    func setStatus(_ status: String) {
        var addr = CMIO.address(CMIO.statusSelector)
        var value = status as CFString
        let err = withUnsafePointer(to: &value) {
            CMIOObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), $0)
        }
        if err != noErr {
            log.error("setting card status to \(status.debugDescription, privacy: .public) failed: \(err)")
        }
    }

    // MARK: sink

    func startSink() {
        guard !sinkRunning else { return }
        if queue == nil {
            var q: Unmanaged<CMSimpleQueue>?
            let err = CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &q)
            guard err == noErr, let q else {
                log.error("copying sink buffer queue failed: \(err)")
                return
            }
            queue = q.takeRetainedValue()
        }
        let err = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard err == noErr else {
            log.error("starting sink failed: \(err)")
            return
        }
        sinkRunning = true
        log.info("sink started")
    }

    func stopSink() {
        guard sinkRunning else { return }
        let err = CMIODeviceStopStream(deviceID, sinkStreamID)
        if err != noErr {
            log.error("stopping sink failed: \(err)")
        }
        sinkRunning = false
        log.info("sink stopped")
    }

    /// Enqueues one frame. Drops it if the extension hasn't drained the last
    /// ones yet: falling behind live video should cost frames, not latency.
    func send(_ pixelBuffer: CVPixelBuffer) {
        guard sinkRunning, let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sample: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard err == noErr, let sample else { return }
        // The queue takes ownership of one retain; the extension releases it.
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }

    // MARK: CMIO helpers

    private static func direction(of stream: CMIOStreamID) -> UInt32 {
        var addr = CMIO.address(UInt32(kCMIOStreamPropertyDirection))
        var value: UInt32 = 0
        var used: UInt32 = 0
        _ = CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return value
    }
}

