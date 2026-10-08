import AppKit
import AVFoundation
import Foundation
import os.log
import SystemExtensions

let log = Logger(subsystem: "ph.inze.camlink-fix.host", category: "host")

let extensionID = "ph.inze.camlink-fix.camera"

func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// MARK: extension install/remove

// sysextd only honors these requests from an app running out of
// /Applications, so run them from the installed bundle, not the build tree.
final class Requester: NSObject, OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(ext.bundleShortVersion) (\(ext.bundleVersion))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("""
            waiting for approval: System Settings → General → Login Items & Extensions → Camera Extensions
            (this command exits once you allow it)
            """)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            print("done")
        case .willCompleteAfterReboot:
            print("done, but takes effect after a reboot")
        @unknown default:
            print("finished with unknown result \(result.rawValue)")
        }
        exit(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsErr = error as NSError
        print("failed: \(nsErr.localizedDescription) (\(nsErr.domain) \(nsErr.code))")
        exit(1)
    }
}

func submit(_ request: OSSystemExtensionRequest) -> Never {
    let requester = Requester()
    request.delegate = requester
    OSSystemExtensionManager.shared.submitRequest(request)
    dispatchMain()
}

// MARK: single instance

// Two agents feeding one sink would fight over the Cam Link, so the agent
// holds an exclusive lock on its pid file for as long as it runs. The pid in
// it is also how `kick` finds the agent.
let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/camlink-fix")
let pidPath = stateDir.appendingPathComponent("host.pid").path

func lockPidFile() -> Bool {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let fd = open(pidPath, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    // Deliberately never closed: the lock lives as long as the process.
    ftruncate(fd, 0)
    let pid = "\(getpid())\n"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return true
}

func kickAgent() -> Never {
    guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        kill(pid, SIGUSR1) == 0
    else {
        print("no running camlink-host agent found")
        exit(1)
    }
    print("kicked camlink-host (pid \(pid))")
    exit(0)
}

// MARK: entry

let usage = "usage: camlink-host [run|kick|activate|deactivate]"
let command = CommandLine.arguments.dropFirst().first ?? "run"

switch command {
case "activate":
    submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
case "deactivate":
    submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
case "kick":
    kickAgent()
case "run":
    break
default:
    print(usage)
    exit(2)
}

// run: the long-lived agent. Launch it through LaunchServices or launchd
// (`open /Applications/CamLinkFix.app`), not from a shell, so TCC asks about
// camera access on behalf of CamLinkFix rather than your terminal.
guard lockPidFile() else {
    log.info("another agent is already running; exiting")
    exit(0)
}

let env = ProcessInfo.processInfo.environment
let deviceName = env["CAMLINK_DEVICE_NAME"] ?? "Cam Link 4K"
let uhubctl = env["CAMLINK_UHUBCTL"] ?? "uhubctl"
let notify = env["CAMLINK_NOTIFY"] != "0"
log.info("starting (device=\(deviceName, privacy: .public) uhubctl=\(uhubctl, privacy: .public) notify=\(notify))")

let agent = Agent(deviceName: deviceName, uhubctl: uhubctl, notify: notify)

signal(SIGUSR1, SIG_IGN)
let kickSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
kickSource.setEventHandler { agent.kick() }
kickSource.resume()

log.info("camera authorization status: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
AVCaptureDevice.requestAccess(for: .video) { granted in
    log.info("camera access granted=\(granted)")
    if granted {
        agent.run()
    } else {
        log.error("camera access denied; allow CamLinkFix in System Settings → Privacy & Security → Camera")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
