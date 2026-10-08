# camlink-fix

I got tired of reaching under my desk to unplug and replug my Elgato Cam Link 4K every morning. It stops producing video after macOS sleep/wake cycles, especially through a Thunderbolt dock, and the only fix is the ol' unplug-replug.

I explored the annals of user forums and found only the echoes of other people with the same problem. I have yet to find a silver bullet for this. The consensus seems to be "USB things are finicky." The good news is I discovered it's not that hard to programmatically unplug/replug. The VIA Labs chipset that many USB hubs use lets you power-cycle individual ports from software via [uhubctl](https://github.com/mvp/uhubctl).

So I wrote a daemon that does exactly that, just slightly more automated and with fewer trips under the desk.

## How It Works

The daemon sits in the background waiting for things that usually break the camera:

- **USB arrival** - the Cam Link appears on the bus (you just docked)
- **Sleep/wake** - macOS woke up and the camera is probably confused again
- **Manual kick** - `camlink-fix --kick` for when you know it's broken

Detection is event-driven, not polled. USB arrival uses IOKit callbacks and sleep/wake uses macOS notifications, so the daemon uses zero CPU while idle.

When triggered, it grabs a test frame via ffmpeg. If that fails, it power-cycles the USB port using [uhubctl](https://github.com/mvp/uhubctl), the software equivalent of reaching under the desk. If the camera isn't ready yet (say you docked but hadn't turned it on), it retries every 30 seconds for a few minutes.

The hub and port are discovered dynamically from `uhubctl` output, so it should work with any uhubctl-compatible USB hub (VIA Labs chipset is the most common).

## Virtual camera mode (macOS, recommended)

The daemon above has a blind spot: it checks the camera on wake and USB events, but a Cam Link usually wedges hours later, right when you open a meeting. Checking it then means attaching a second client (ffmpeg) to a camera the meeting app is already streaming, which tipped a marginal Cam Link into a USB interrupt storm. So `mac/` takes a different approach.

CamLinkFix.app installs a virtual camera, **Cam Link (camlink-fix)**, and you pick that in Zoom, Meet, and so on. Behind it, an agent is the real Cam Link's only client:

- When an app opens the virtual camera, the agent opens the Cam Link and passes its video through (about 270ms to first frame). When the last app leaves, it lets go, so the Cam Link sits idle between meetings.
- Because nothing else reads the Cam Link, "are my frames still arriving" is exactly what the meeting app sees. If they stop for 2 seconds, the agent power-cycles the port with uhubctl (quick cycle, then the full and extended resets) and reconnects. A quick cycle takes about 3.5 seconds.
- During all of that the app keeps its camera. It sees a blurred, dimmed still of a recent moment with a quiet spinner, never a dead device or an error message, so there's nothing to reselect afterwards and nothing odd for the other people on the call.
- `camlink-host kick` (or `camlink-kick` with the Nix module) forces a reset.

It's a CoreMediaIO camera extension, so it has to be signed with a team that can grant the System Extension entitlement, installed in `/Applications`, and approved once in System Settings. `mac/bundle.sh` builds and signs it the same way as music-stuff's dj; see the comment at its top for the one-time developer portal setup. Then:

```bash
mac/bundle.sh --install    # build, sign, copy to /Applications, activate, (re)start the agent
```

With nix-darwin, set `services.camlink-fix.virtualCamera.enable = true;`. That runs the installed app's agent under launchd and turns off the Go daemon, whose probes would be a second client on the Cam Link.

Logs go to the unified log:

```bash
log stream --level info --predicate 'subsystem BEGINSWITH "ph.inze.camlink-fix"'
```

## Requirements

- macOS (uses IOKit for USB device detection, CoreFoundation for sleep/wake)
- [uhubctl](https://github.com/mvp/uhubctl) and a compatible USB hub. [This is the one I use](https://www.microcenter.com/product/684604/inland-type-c-4-port-usb-30-(usb-32-gen-1)-type-a-hub), but many USB hubs have the same underlying VIA Labs chipset
- ffmpeg (for camera health checks)

## Installation

### Nix (nix-darwin)

```nix
# flake.nix
inputs.camlink-fix.url = "github:phinze/camlink-fix";
```

```nix
# configuration.nix
imports = [ inputs.camlink-fix.darwinModules.default ];

services.camlink-fix = {
  enable = true;
};
```

### From Source

```bash
go build ./cmd/camlink-fix
./camlink-fix --uhubctl-path /path/to/uhubctl --ffmpeg-path /path/to/ffmpeg
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--device-name` | `Cam Link 4K` | Camera name in `system_profiler SPCameraDataType` |
| `--uhubctl-path` | `uhubctl` | Path to uhubctl binary |
| `--ffmpeg-path` | `ffmpeg` | Path to ffmpeg binary |
| `--wake-delay` | `5s` | Delay after wake before checking |
| `--retry-delay` | `30s` | Delay between retries after failure |
| `--max-retries` | `10` | Max retries before giving up |
| `--notify` | `true` | Send macOS notifications |
| `--kick` | | Signal a running daemon to check immediately |
