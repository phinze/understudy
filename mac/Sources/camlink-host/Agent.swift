import Foundation

/// Agent ties demand to the Cam Link. When an app opens the virtual camera it
/// opens the Cam Link and feeds the sink; when the last app leaves it lets go
/// entirely, so the Cam Link sits idle between meetings. In between, if our
/// own session stops getting frames, it power-cycles the Cam Link while the
/// app keeps watching the card.
final class Agent {
    private enum Phase: CustomStringConvertible {
        /// No app wants video.
        case idle
        /// Capture is running (or starting) and the watchdog is armed.
        case streaming
        /// An app wants video but the Cam Link isn't on the bus.
        case waitingForDevice
        /// A uhubctl cycle is in flight.
        case resetting
        /// Every reset stage failed. Waits for a replug, a kick, or the
        /// next demand edge.
        case gaveUp

        var description: String {
            switch self {
            case .idle: "idle"
            case .streaming: "streaming"
            case .waitingForDevice: "waiting-for-device"
            case .resetting: "resetting"
            case .gaveUp: "gave-up"
            }
        }
    }

    private let capture: CamLinkCapture
    private let reset: UsbReset
    private let notify: Bool
    private var camera: VirtualCamera?
    private let queue = DispatchQueue(label: "camlink-host.agent")
    private let resetQueue = DispatchQueue(label: "camlink-host.reset")

    // All of the state below is only touched on `queue`.
    private var phase = Phase.idle
    private var demand = 0
    /// Index into UsbReset.stages of the next reset to try. Escalates while
    /// resets don't stick, and drops back to 0 once video has stayed healthy
    /// for a while.
    private var nextStage = 0
    private var healthySince: UInt64?
    private var attachAttempts = 0

    /// How long video has to flow before a later wedge starts the escalation
    /// over from the quick cycle.
    private static let stableAfter: UInt64 = 30_000_000_000

    init(deviceName: String, uhubctl: String, notify: Bool) {
        capture = CamLinkCapture(deviceName: deviceName)
        reset = UsbReset(uhubctl: uhubctl)
        self.notify = notify
    }

    func run() {
        queue.async { [self] in
            // A reset that was killed mid-cycle may have left the ports dark.
            // Power them back on before anything else.
            resetQueue.async { self.reset.heal() }
            capture.onEvent = { [weak self] event in
                self?.queue.async { self?.handle(event) }
            }
            attach()
        }
    }

    /// A manual kick: reset now, from the quickest stage. Replaces
    /// `camlink-fix --kick` for the times you can see it's broken and the
    /// watchdog hasn't noticed.
    func kick() {
        queue.async { [self] in
            log.info("kick (phase=\(self.phase.description, privacy: .public) demand=\(self.demand))")
            guard phase != .resetting else {
                log.info("kick: reset already in progress")
                return
            }
            nextStage = 0
            beginReset(reason: "manual kick")
        }
    }

    // MARK: virtual camera

    /// The extension's device can take a moment to show up in a freshly
    /// launched process, so look for it until it does. This only lists
    /// devices; nothing touches the Cam Link.
    private func attach() {
        guard let camera = VirtualCamera() else {
            attachAttempts += 1
            if attachAttempts == 1 {
                log.info("virtual camera not visible yet; retrying")
            }
            // CoreMediaIO's device list in this process can go stale if we
            // launched while the extension was being swapped out. Exiting
            // gets a fresh one from launchd's KeepAlive.
            if attachAttempts >= 30 {
                log.error("virtual camera still not visible after \(self.attachAttempts)s; exiting for a fresh start")
                exit(1)
            }
            queue.asyncAfter(deadline: .now() + 1) { self.attach() }
            return
        }
        self.camera = camera
        capture.onFrame = { [weak camera] buffer in camera?.send(buffer) }
        camera.onDemandChange(queue: queue) { [weak self] in self?.demandChanged() }
        log.info("attached to virtual camera (device \(camera.deviceID))")
        demandChanged()
    }

    private func demandChanged() {
        guard let camera else { return }
        let was = demand
        demand = camera.demand()
        log.info("demand \(was)→\(self.demand) (phase=\(self.phase.description, privacy: .public))")

        if demand > 0, was == 0 {
            camera.startSink()
            // A fresh demand edge is a fresh chance, even after giving up.
            nextStage = 0
            startCapture()
        } else if demand == 0, was > 0 {
            capture.stop()
            camera.stopSink()
            setStatus(nil)
            // A reset in flight keeps going (the ports must come back on);
            // it notices demand is gone when it finishes.
            if phase != .resetting {
                phase = .idle
            }
        }
    }

    // MARK: capture

    private func startCapture() {
        guard capture.isDevicePresent else {
            phase = .waitingForDevice
            setStatus("not-connected")
            log.info("Cam Link not on the bus; waiting for it")
            return
        }
        phase = .streaming
        setStatus(nil)
        capture.start()
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .healthy:
            guard phase == .streaming else { return }
            healthySince = nowNanos()
            setStatus(nil)

        case .unhealthy(let reason):
            guard phase == .streaming, demand > 0 else { return }
            if let since = healthySince, nowNanos() - since > Self.stableAfter {
                nextStage = 0
            }
            healthySince = nil
            beginReset(reason: reason)

        case .disconnected:
            // Our own resets unplug the device too; only an unplug we didn't
            // cause means "wait for it to come back".
            guard phase == .streaming else { return }
            capture.stop()
            phase = .waitingForDevice
            setStatus("not-connected")

        case .connected:
            guard demand > 0 else { return }
            switch phase {
            case .waitingForDevice:
                startCapture()
            case .gaveUp:
                // A replug is the human version of our reset. Try again.
                log.info("Cam Link replugged after giving up; retrying")
                nextStage = 0
                startCapture()
            default:
                break
            }
        }
    }

    // MARK: reset

    private func beginReset(reason: String) {
        guard nextStage < UsbReset.stages.count else {
            giveUp(reason: reason)
            return
        }
        let stage = UsbReset.stages[nextStage]
        nextStage += 1
        phase = .resetting
        log.error("reset: \(reason, privacy: .public); trying \(stage.name, privacy: .public)")
        capture.stop()
        setStatus("reconnecting")

        resetQueue.async { [self] in
            guard let loc = reset.locate() else {
                // Usually it's unplugged. But a dark port looks the same, so
                // power the last known location back on: harmless if it's
                // unplugged, and a rescue if something left it off.
                log.error("reset: Cam Link not found on a uhubctl hub; re-powering its last known port")
                reset.heal()
                queue.async { self.resetFinished(located: false) }
                return
            }
            log.info("reset: \(stage.name, privacy: .public) at \(loc.description, privacy: .public)")
            reset.cycle(stage, at: loc)
            queue.async { self.resetFinished(located: true) }
        }
    }

    private func resetFinished(located: Bool) {
        guard demand > 0 else {
            log.info("reset: finished with nobody watching; going idle")
            phase = .idle
            return
        }
        guard located else {
            // Not on the bus at all (unplugged, or undocked): nothing to cycle.
            phase = .waitingForDevice
            setStatus("not-connected")
            return
        }
        waitForDevice(deadline: nowNanos() + 15_000_000_000)
    }

    /// After power returns the Cam Link takes a few seconds to enumerate.
    /// Check for it every half second (local, bounded, and only during a
    /// reset) rather than trusting the connect notification to arrive.
    private func waitForDevice(deadline: UInt64) {
        guard demand > 0, phase == .resetting else { return }
        if capture.isDevicePresent {
            log.info("reset: Cam Link is back; restarting capture")
            startCapture()
        } else if nowNanos() > deadline {
            log.error("reset: Cam Link didn't come back within 15s")
            phase = .streaming
            handle(.unhealthy("device missing after reset"))
        } else {
            queue.asyncAfter(deadline: .now() + 0.5) { self.waitForDevice(deadline: deadline) }
        }
    }

    private func giveUp(reason: String) {
        phase = .gaveUp
        capture.stop()
        log.error("reset: giving up after every stage (\(reason, privacy: .public))")
        setStatus("gave-up")
        if notify {
            Notifier.send("Cam Link didn't recover after resets. Try replugging it.")
        }
    }

    // MARK: card

    /// Tells the extension what state we're in while there's no live video:
    /// "reconnecting", "not-connected", "gave-up", or nil for none of those.
    /// The card turns it into spinner-or-not, never text.
    private func setStatus(_ status: String?) {
        camera?.setStatus(status ?? "")
    }
}

enum Notifier {
    static func send(_ message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(message)\" with title \"Cam Link Fix\""]
        try? p.run()
    }
}
