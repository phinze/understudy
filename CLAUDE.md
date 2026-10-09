# camlink-fix

A macOS virtual camera that keeps the Elgato Cam Link 4K working through the
wedges and resets it suffers after sleep/wake cycles. The last version of the
older Go probe-and-reset daemon is tagged `camlink-fix-final`.

## Architecture

All in `mac/` (Swift, SwiftPM), plus the nix-darwin module in `nix/`:

- `Sources/camlink-camera/` - CMIO camera extension. Relays frames from its
  sink stream to its source stream and draws the no-video card. Publishes a
  `dmnd` device property (is any app streaming?) and accepts a writable
  `stat` property (host state, picks spinner or not).
- `Sources/camlink-host/` - Host app and agent. Listens on `dmnd`, captures
  the real Cam Link with AVFoundation, feeds the sink, and runs the
  watchdog and uhubctl reset (`UsbReset.swift`).
- `bundle.sh` - Builds, assembles and signs `CamLinkFix.app` outside Nix.
- `nix/module.nix` - Runs the installed app's agent under launchd.

## Gotchas

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
mac/bundle.sh             # build + sign into mac/.build/CamLinkFix.app
mac/bundle.sh --install   # also install to /Applications and restart the agent
```

## Nix

The flake exports only `darwinModules.default` for nix-darwin. Nix can't build
the signed app; the module runs the copy `bundle.sh --install` put in
`/Applications`.
