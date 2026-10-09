import Foundation

/// Where the Cam Link sits in the USB hub tree, as uhubctl names it. VIA Labs
/// hubs expose a USB 3 hub and a USB 2 companion with the same port layout,
/// and a full reset has to power both down or the device just falls back to
/// the USB 2 side.
struct HubLocation: Codable, CustomStringConvertible {
    var hub: String
    var port: String
    var companion: String?

    var description: String { "\(hub) port \(port)" + (companion.map { " (+\($0))" } ?? "") }
}

/// UsbReset power-cycles the Cam Link's hub port with uhubctl: the software
/// version of reaching under the desk. Ported from the Go daemon's
/// internal/reset (tag camlink-fix-final), same stages and same
/// heal-on-startup backstop.
final class UsbReset {
    struct Stage {
        let name: String
        let offSeconds: Int
        let bothPorts: Bool
        let settleSeconds: Double
    }

    // Settle times are shorter than the Go daemon's, which needed the device
    // fully up before its ffmpeg probe. Here the agent waits for the device
    // to reappear and the first-frame watchdog catches one that isn't ready,
    // so settle only has to cover the port's power-on bounce.
    static let stages = [
        Stage(name: "quick cycle", offSeconds: 2, bothPorts: false, settleSeconds: 1),
        Stage(name: "full reset", offSeconds: 10, bothPorts: true, settleSeconds: 2),
        Stage(name: "extended reset", offSeconds: 30, bothPorts: true, settleSeconds: 2),
    ]

    private let uhubctl: String
    private static let callTimeout: TimeInterval = 15

    // Remembers where the device lives so a reset killed mid-cycle can be
    // healed on the next start: once its ports are off, uhubctl can't find
    // the device to locate it again. Temp dir on purpose; a reboot re-powers
    // USB anyway.
    private let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("camlink-host.location.json")

    init(uhubctl: String) {
        self.uhubctl = uhubctl
    }

    /// Finds the device's hub and port, plus the companion hub if there is
    /// one. Nil if the device isn't on a uhubctl-controllable hub (or isn't
    /// plugged in at all).
    func locate() -> HubLocation? {
        let out = run([])
        // Swift 5 mode has no bare /regex/ literals, so these are typed by hand.
        let hubRe = try! Regex(#"^Current status for hub ([0-9.\-]+)\s+\[([0-9a-f:]+)"#, as: (Substring, Substring, Substring).self)
        let portRe = try! Regex(#"^\s+Port\s+(\d+):"#, as: (Substring, Substring).self)

        var found: HubLocation?
        var hub = ""
        for line in out.split(separator: "\n") {
            if let m = line.firstMatch(of: hubRe) {
                hub = String(m.1)
            } else if let m = line.firstMatch(of: portRe), line.contains("Cam Link"), !hub.isEmpty {
                found = HubLocation(hub: hub, port: String(m.1))
                break
            }
        }
        guard var loc = found else { return nil }

        hub = ""
        var vid = ""
        for line in out.split(separator: "\n") {
            if let m = line.firstMatch(of: hubRe) {
                hub = String(m.1)
                vid = String(m.2)
            } else if vid == "2109:2813" || vid == "2109:0813", hub != loc.hub,
                let m = line.firstMatch(of: portRe), String(m.1) == loc.port
            {
                loc.companion = hub
                break
            }
        }
        return loc
    }

    /// Runs one stage against `loc`. Blocks for the off window plus settle
    /// time, so call it off any queue that matters. The power-on is deferred
    /// so a reset can't leave the ports dark short of SIGKILL, which heal()
    /// covers.
    func cycle(_ stage: Stage, at loc: HubLocation) {
        save(loc)
        if stage.bothPorts, let companion = loc.companion {
            defer {
                hubctl(loc.hub, loc.port, "on")
                hubctl(companion, loc.port, "on")
            }
            hubctl(loc.hub, loc.port, "off")
            hubctl(companion, loc.port, "off")
            Thread.sleep(forTimeInterval: Double(stage.offSeconds))
        } else {
            hubctl(loc.hub, loc.port, "cycle", extra: ["-d", String(stage.offSeconds)])
        }
        Thread.sleep(forTimeInterval: stage.settleSeconds)
    }

    /// Powers the last-known ports back on. A no-op when they're already on,
    /// so it's safe to call unconditionally at startup.
    func heal() {
        guard let data = try? Data(contentsOf: stateURL),
            let loc = try? JSONDecoder().decode(HubLocation.self, from: data)
        else { return }
        log.info("reset: healing, making sure \(loc.description, privacy: .public) is powered on")
        hubctl(loc.hub, loc.port, "on")
        if let companion = loc.companion {
            hubctl(companion, loc.port, "on")
        }
    }

    private func save(_ loc: HubLocation) {
        do {
            try JSONEncoder().encode(loc).write(to: stateURL)
        } catch {
            log.error("reset: couldn't persist location: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hubctl(_ hub: String, _ port: String, _ action: String, extra: [String] = []) {
        _ = run(["-l", hub, "-p", port, "-a", action] + extra, logFailure: true)
    }

    /// Runs uhubctl and returns its combined output. uhubctl exits non-zero
    /// in some successful cases, so the output is what callers go by.
    @discardableResult
    private func run(_ args: [String], logFailure: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [uhubctl] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            log.error("reset: couldn't run \(self.uhubctl, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // uhubctl can wedge in the kernel on these hubs (seen: a power-on
        // stuck for over a minute). A reset that never returns would park
        // the agent in "resetting" forever, so cap every call.
        let pid = p.processIdentifier
        let watchdog = DispatchWorkItem { [uhubctl] in
            guard p.isRunning else { return }
            log.error("reset: \(uhubctl, privacy: .public) \(args.joined(separator: " "), privacy: .public) hung; killing it")
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        let out = String(decoding: data, as: UTF8.self)
        if logFailure, p.terminationStatus != 0 {
            log.error("reset: uhubctl \(args.joined(separator: " "), privacy: .public) exited \(p.terminationStatus): \(out, privacy: .public)")
        }
        return out
    }
}
