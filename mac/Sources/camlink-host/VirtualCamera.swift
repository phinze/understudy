import CoreMedia
import CoreMediaIO
import Foundation

/// VirtualCamera is the host's view of our own extension's device, through
/// the CoreMediaIO C API: it watches the demand property and writes frames
/// into the sink stream.
final class VirtualCamera {
    static let deviceUID = "6C1A4F2E-9B0D-4E57-A3C8-2F7D1B5E8C40"

    let deviceID: CMIOObjectID
    private let sinkStreamID: CMIOStreamID
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private(set) var sinkRunning = false

    /// Finds our device among the system's CMIO devices, or returns nil if
    /// the extension isn't (yet) visible to this process.
    init?() {
        let all = Self.devices()
        guard let device = all.first(where: { Self.uid(of: $0) == Self.deviceUID }) else {
            log.debug("our device not among \(all.count) CMIO devices: \(all.map { Self.uid(of: $0) ?? "?" }, privacy: .public)")
            return nil
        }
        let streams = Self.objectIDs(device, selector: kCMIODevicePropertyStreams)
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
        var addr = Self.address(fourCC("dmnd"))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, size, &used, &value)
        guard err == noErr, let str = value?.takeRetainedValue() else {
            log.error("reading demand failed: \(err)")
            return 0
        }
        return Int(str as String) ?? 0
    }

    /// Calls `handler` on `queue` whenever the extension says demand changed.
    func onDemandChange(queue: DispatchQueue, _ handler: @escaping () -> Void) {
        var addr = Self.address(fourCC("dmnd"))
        let err = CMIOObjectAddPropertyListenerBlock(deviceID, &addr, queue) { _, _ in handler() }
        if err != noErr {
            log.error("listening for demand failed: \(err)")
        }
    }

    /// Tells the extension our state through its writable 'stat' property,
    /// which picks how the card looks. Empty means nothing special.
    func setStatus(_ status: String) {
        var addr = Self.address(fourCC("stat"))
        var value = status as CFString
        let err = withUnsafePointer(to: &value) {
            CMIOObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), $0)
        }
        if err != noErr {
            log.error("setting card status failed: \(err)")
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

    private static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func devices() -> [CMIOObjectID] {
        objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
    }

    private static func objectIDs(_ object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(UInt32(selector))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func uid(of device: CMIOObjectID) -> String? {
        var addr = address(UInt32(kCMIODevicePropertyDeviceUID))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func direction(of stream: CMIOStreamID) -> UInt32 {
        var addr = address(UInt32(kCMIOStreamPropertyDirection))
        var value: UInt32 = 0
        var used: UInt32 = 0
        _ = CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return value
    }
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}
