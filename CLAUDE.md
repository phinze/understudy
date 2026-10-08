# camlink-fix

A Go daemon that automatically resets the Elgato Cam Link 4K when it becomes
unresponsive after macOS sleep/wake cycles.

## Architecture

- `cmd/camlink-fix/` - Entry point, event loop, signal handling
- `internal/usbwatch/` - IOKit USB device arrival detection via purego
- `internal/sleepwatch/` - Sleep/wake detection via mac-sleep-notifier
- `internal/health/` - Camera health checks (system_profiler + ffmpeg)
- `internal/reset/` - Escalating USB power cycle via uhubctl
- `internal/notify/` - macOS notifications via osascript
- `nix/` - Nix module and packaging
- `mac/` - Virtual camera mode (Swift, SwiftPM), which replaces the daemon on
  macOS:
  - `Sources/camlink-camera/` - CMIO camera extension. Relays frames from its
    sink stream to its source stream and draws the no-video card. Publishes a
    `dmnd` device property (is any app streaming?) and accepts a writable
    `stat` property (host state, picks spinner or not).
  - `Sources/camlink-host/` - Host app and agent. Listens on `dmnd`, captures
    the real Cam Link with AVFoundation, feeds the sink, and runs the
    watchdog and uhubctl reset (`UsbReset.swift`, ported from
    `internal/reset`).
  - `bundle.sh` - Builds, assembles and signs `CamLinkFix.app` outside Nix.

### Virtual camera gotchas

- CMIO stream direction is from the system's side: the source (what apps
  read) is 1 and the sink is 0. Getting it backwards makes the host a second
  viewer of its own camera.
- CMIO calls the extension's `startStream`/`stopStream` once per stream, not
  once per client.
- sysextd needs `NSSystemExtensionUsageDescription` in the extension's own
  Info.plist, and only activates from `/Applications`.
- Upgrading the extension while an app holds it open can lose the new
  version (CMIO thinks it's "already running"). `bundle.sh --install`
  detects that and reinstalls once.
- uhubctl can hang on these hubs; every call has a timeout.
- `log show` and `log stream` need `--info`/`--level info` to see the
  extension's and agent's lines, and debug lines are never persisted.

## Building

```bash
go build ./cmd/camlink-fix
```

## Running

```bash
./camlink-fix --uhubctl-path /path/to/uhubctl --ffmpeg-path /path/to/ffmpeg
```

## Nix

```bash
nix build
```

The flake exports `darwinModules.default` for use in nix-darwin configurations.
