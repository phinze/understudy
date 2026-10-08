import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

let log = Logger(subsystem: "ph.inze.camlink-fix.camera", category: "extension")

// One fixed format for now. Apps pick from what we advertise, and the host
// scales whatever mode the Cam Link is in down to this before sending it.
let frameWidth: Int32 = 1920
let frameHeight: Int32 = 1080
let frameRate: Int32 = 30

// The device ID has to be stable across launches. Apps remember the camera
// you picked by its unique ID, and a fresh UUID per launch would make Zoom
// forget the choice every time the extension restarts.
let deviceID = UUID(uuidString: "6C1A4F2E-9B0D-4E57-A3C8-2F7D1B5E8C40")!
let sourceStreamID = UUID(uuidString: "0E8B3D71-4C2A-4F96-B15E-7A9C6D2F4B13")!
let sinkStreamID = UUID(uuidString: "A2D94C5B-7E31-4B8F-9C06-3F5E8A1D7B24")!

// demandProperty is how the host learns that an app wants video: "1" while
// the source stream is running, "0" otherwise. The host
// can't use the device's own "running somewhere" flag for this, because its
// sink stream counts as running too, so it would never see the last app
// leave. Host side reads it as selector 'dmnd', global scope, element 0.
let demandProperty = CMIOExtensionProperty(rawValue: "4cc_dmnd_glob_0000")

// statusProperty is the other direction: the host's state while there's no
// live video. "" (starting up or waiting), "reconnecting", "not-connected",
// or "gave-up". It only picks whether the card spins; the card never shows
// text, since meeting participants see it.
let statusProperty = CMIOExtensionProperty(rawValue: "4cc_stat_glob_0000")

// The backdrop refreshes from live video once per session after the
// picture has settled (auto-exposure, someone sitting down), then at most
// this often. Rarely on purpose: it only has to look like "a recent you".
let backdropSettleNanos: UInt64 = 3_000_000_000
let backdropRefreshNanos: UInt64 = 300_000_000_000

// If the sink has been quiet this long, the source shows the card instead.
// A few frame intervals, so a single late frame doesn't flash the card.
let sinkStaleAfterNanos: UInt64 = 300_000_000

func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "Cam Link (camlink-fix)")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        log.info("client connected: pid=\(client.pid)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        log.info("client disconnected: pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "camlink-fix"
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// DeviceSource owns the relay between the two streams. Apps read from the
/// source stream; the host writes Cam Link frames into the sink stream. Each
/// tick, if a fresh sink frame is waiting it goes out, and if the sink has
/// gone quiet the card goes out instead, so apps never see the video stop.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: SinkSource!
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let card: Card
    private var status = ""

    // All of the state below is only touched on `queue`.
    private let queue = DispatchQueue(label: "camlink-camera.relay", qos: .userInteractive)
    private var sourceStreaming = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: UInt64 = 0
    /// What the card sits on. Persisted in the extension's container so a
    /// meeting that starts out wedged still gets a familiar backdrop.
    private var backdrop: Backdrop?
    private let backdropURL: URL
    private var liveSince: UInt64 = 0
    private var backdropTakenAt: UInt64 = 0
    private var showingLive = false
    private var timer: DispatchSourceTimer?

    init(localizedName: String) {
        card = Card(width: Int(frameWidth), height: Int(frameHeight))
        // In the sandbox this resolves inside the extension's own container.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        backdropURL = support.appendingPathComponent("backdrop.bgra")
        backdrop = Backdrop.load(from: backdropURL)
        super.init()
        card.show(backdrop)

        device = CMIOExtensionDevice(
            localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: frameWidth, height: frameHeight, extensions: nil,
            formatDescriptionOut: &videoDescription)

        let poolAttrs: NSDictionary = [
            kCVPixelBufferWidthKey: frameWidth,
            kCVPixelBufferHeightKey: frameHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs, &bufferPool)

        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: videoDescription, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil)

        sourceStream = StreamSource(
            localizedName: "camlink-fix.video", streamID: sourceStreamID, streamFormat: format,
            device: device)
        sinkStream = SinkSource(
            localizedName: "camlink-fix.sink", streamID: sinkStreamID, streamFormat: format,
            device: device)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, demandProperty, statusProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "camlink-fix virtual camera"
        }
        if properties.contains(demandProperty) {
            let streaming = queue.sync { sourceStreaming }
            props.setPropertyState(demandState(streaming), forProperty: demandProperty)
        }
        if properties.contains(statusProperty) {
            let current = queue.sync { status }
            // Writable, or the DAL refuses the host's set.
            let attrs = CMIOExtensionPropertyAttributes<AnyObject>(
                minValue: nil, maxValue: nil, validValues: nil, readOnly: false)
            props.setPropertyState(
                CMIOExtensionPropertyState(value: current as NSString, attributes: attrs),
                forProperty: statusProperty)
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        guard let state = deviceProperties.propertiesDictionary[statusProperty],
            let value = state.value as? String
        else { return }
        queue.async { [self] in
            guard value != status else { return }
            status = value
            log.info("card status: \(value.isEmpty ? "(none)" : value, privacy: .public)")
            // Spin while something is about to happen; sit still when we're
            // waiting on a human.
            card.spinning = value != "not-connected" && value != "gave-up"
        }
    }

    private func demandState(_ streaming: Bool) -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: (streaming ? "1" : "0") as NSString)
    }

    // MARK: source side (apps)

    // These are the demand edges the whole design hangs on. CMIO calls them
    // once per stream, not per viewer: start when the first app opens the
    // virtual camera, stop when the last one leaves.
    func sourceStarted() {
        queue.async { [self] in
            sourceStreaming = true
            log.info("source start")
            publishDemand()
            guard timer == nil else { return }

            showingLive = false
            card.show(backdrop)
            card.spinning = true
            // Take a fresh backdrop early in every session.
            backdropTakenAt = 0
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func sourceStopped() {
        queue.async { [self] in
            sourceStreaming = false
            log.info("source stop")
            publishDemand()
            timer?.cancel()
            timer = nil
        }
    }

    private func publishDemand() {
        device.notifyPropertiesChanged([demandProperty: demandState(sourceStreaming)])
    }

    // MARK: sink side (host)

    func sinkStarted(client: CMIOExtensionClient?) {
        queue.async { [self] in
            sinkClient = client
            log.info("sink start (host pid=\(client?.pid ?? -1))")
        }
    }

    func sinkStopped() {
        queue.async { [self] in
            sinkClient = nil
            log.info("sink stop")
        }
    }

    // MARK: relay

    private func tick() {
        let now = nowNanos()
        if let client = sinkClient {
            // Pull at most one frame per tick. Anything that arrives faster
            // waits in the host's queue, which is shallow on purpose: a stale
            // backlog is worse than a dropped frame.
            sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sample, seq, _, _, _ in
                guard let self, let sample else { return }
                self.queue.async { self.forward(sample, sequence: seq) }
            }
        }

        let live = lastSinkFrame != 0 && now - lastSinkFrame < sinkStaleAfterNanos
        if live != showingLive {
            showingLive = live
            log.info("\(live ? "live: passing sink frames through" : "card: sink quiet, showing card", privacy: .public)")
            if live {
                liveSince = now
            } else {
                card.show(backdrop)
            }
        }
        if !live {
            emitCard(now: now)
        }
    }

    private func forward(_ sample: CMSampleBuffer, sequence: UInt64) {
        let now = nowNanos()
        lastSinkFrame = now
        maybeRefreshBackdrop(from: sample, now: now)
        sinkStream.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
        guard sourceStreaming else { return }
        sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
    }

    private func maybeRefreshBackdrop(from sample: CMSampleBuffer, now: UInt64) {
        guard showingLive, now - liveSince > backdropSettleNanos,
            backdropTakenAt == 0 || now - backdropTakenAt > backdropRefreshNanos,
            let frame = CMSampleBufferGetImageBuffer(sample),
            let fresh = Backdrop.blur(frame)
        else { return }
        backdropTakenAt = now
        backdrop = fresh
        do {
            try fresh.save(to: backdropURL)
            log.info("backdrop refreshed")
        } catch {
            log.error("saving backdrop failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func emitCard(now: UInt64) {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &buffer) == kCVReturnSuccess,
            let buffer
        else {
            log.error("pixel buffer pool exhausted, dropping frame")
            return
        }
        card.render(into: buffer)

        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sample: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: videoDescription,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard err == noErr, let sample else {
            log.error("CMSampleBufferCreateForImageBuffer failed: \(err)")
            return
        }
        sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .source,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        return props
    }

    // Only one format, so there's nothing for a client to change.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? DeviceSource)?.sourceStarted()
    }

    func stopStream() throws {
        (device.source as? DeviceSource)?.sourceStopped()
    }
}

/// SinkSource is the host's way in. The host enqueues Cam Link frames on the
/// sink's buffer queue, and DeviceSource pulls them off on its tick.
final class SinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    // consumeSampleBuffer needs the writing client, and the only place we're
    // handed it is the authorization check just before startStream.
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .sink,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            props.sinkBufferQueueSize = 2
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            props.sinkBuffersRequiredForStartup = 1
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        (device.source as? DeviceSource)?.sinkStarted(client: client)
    }

    func stopStream() throws {
        (device.source as? DeviceSource)?.sinkStopped()
    }
}
