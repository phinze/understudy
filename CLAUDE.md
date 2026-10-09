# Understudy

A macOS virtual camera that steps in when the real camera can't: today it
keeps an Elgato Cam Link 4K usable through the wedges and resets it suffers
after sleep/wake cycles. Formerly camlink-fix; the last version of the older
Go probe-and-reset daemon is tagged `camlink-fix-final`.

Nothing should hardcode "Cam Link". The real camera is whatever
`UNDERSTUDY_DEVICE_NAME` (the module's `deviceName`) says.

## Architecture

All in `mac/` (Swift, SwiftPM), plus the nix-darwin module in `nix/`:

- `Sources/understudy-camera/` - CMIO camera extension. Relays frames from its
  sink stream to its source stream and draws the no-video card. Publishes a
  `dmnd` device property (is any app streaming?) and accepts a writable
  `stat` property (host state, picks spinner or not).
- `Sources/understudy/` - Host app and agent (`understudy`). Listens on
  `dmnd`, captures the real camera with AVFoundation, feeds the sink, and runs the
  watchdog and uhubctl reset (`UsbReset.swift`). Draws effects (blob
  tracking today) on live frames between the hold detector and the sink,
  configured by `~/.local/state/understudy/effects.json`, which it watches.
  `understudy render-effect IN OUT [SETTINGS]` runs a clip or still through
  the same code.
- `Sources/understudy-settings/` - Understudy Settings.app, a SwiftUI editor
  for effects.json and nothing else: no camera, no talking to the agent.
- `Sources/UnderstudyShared/` - The effects.json schema both of those share.
  Decoding clamps or defaults bad fields instead of failing.
- `bundle.sh` - Builds, assembles and signs `Understudy.app` outside Nix.
  The CMIO device and stream UUIDs in `Extension.swift` must never change:
  apps remember the camera by them.
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
mac/bundle.sh             # build + sign into mac/.build/Understudy.app
mac/bundle.sh --install   # also install to /Applications and restart the agent
```

## Nix

The flake exports only `darwinModules.default` for nix-darwin. Nix can't build
the signed app; the module runs the copy `bundle.sh --install` put in
`/Applications`.
