# Understudy

I got tired of reaching under my desk to unplug and replug my Elgato Cam Link 4K every morning. It stops producing video after macOS sleep/wake cycles, especially through a Thunderbolt dock, and the only fix is the ol' unplug-replug.

I explored the annals of user forums and found only the echoes of other people with the same problem. I have yet to find a silver bullet for this. The consensus seems to be "USB things are finicky." The good news is I discovered it's not that hard to programmatically unplug/replug. The VIA Labs chipset that many USB hubs use lets you power-cycle individual ports from software via [uhubctl](https://github.com/mvp/uhubctl).

This started life as camlink-fix, a daemon that did exactly that. It grew into a virtual camera that stands in for the real one whenever the real one can't go on, hence the new name. Today it knows one camera (the Cam Link) and one trick (resetting it). The plan is any camera, effects, and falling back to a second camera instead of a card.

## How It Works

Understudy.app installs a virtual camera, **Understudy**, and you pick that in Zoom, Meet, and so on. Behind it, an agent is the real Cam Link's only client:

- When an app opens the virtual camera, the agent opens the Cam Link and passes its video through (about 270ms to first frame). When the last app leaves, it lets go, so the Cam Link sits idle between meetings.
- Because nothing else reads the Cam Link, "are my frames still arriving" is exactly what the meeting app sees. If they stop for 2 seconds, the agent power-cycles the port with uhubctl (quick cycle, then the full and extended resets) and reconnects. A quick cycle takes about 3.5 seconds.
- During all of that the app keeps its camera. It sees a blurred, dimmed still of a recent moment with a quiet spinner, never a dead device or an error message, so there's nothing to reselect afterwards and nothing odd for the other people on the call.
- `understudy kick` forces a reset. The Nix module puts `understudy` on your PATH; without it, run `/Applications/Understudy.app/Contents/MacOS/understudy kick`.

The hub and port are discovered from `uhubctl` output, so it should work with any uhubctl-compatible USB hub (VIA Labs chipset is the most common).

This replaced an earlier Go daemon that probed the camera with ffmpeg after wake and USB events and reset it when the probe failed. A Cam Link usually wedges hours later, right when you open a meeting, and probing it then means attaching a second client to a camera the meeting app is already streaming, which tipped a marginal Cam Link into a USB interrupt storm. The daemon's last version is tagged [`camlink-fix-final`](https://github.com/phinze/understudy/tree/camlink-fix-final), and `docs/edge-trigger-investigation.md` has the story of how we got here.

## Requirements

- macOS, and an Apple developer team that can grant the System Extension entitlement
- [uhubctl](https://github.com/mvp/uhubctl) and a compatible USB hub. [This is the one I use](https://www.microcenter.com/product/684604/inland-type-c-4-port-usb-30-(usb-32-gen-1)-type-a-hub), but many USB hubs have the same underlying VIA Labs chipset

## Installation

It's a CoreMediaIO camera extension, so it has to be signed, installed in `/Applications`, and approved once in System Settings. `mac/bundle.sh` builds and signs it the same way as music-stuff's dj; see the comment at its top for the one-time developer portal setup. Then:

```bash
mac/bundle.sh --install    # build, sign, copy to /Applications, activate, (re)start the agent
```

### Nix (nix-darwin)

Nix can't build the signed app, but the module runs the installed app's agent under launchd, gives it passwordless uhubctl, and warns when the installed app falls behind the flake's revision.

```nix
# flake.nix
inputs.understudy.url = "github:phinze/understudy";
```

```nix
# configuration.nix
imports = [ inputs.understudy.darwinModules.default ];

services.understudy.enable = true;
```

## Logs

Logs go to the unified log:

```bash
log stream --level info --predicate 'subsystem BEGINSWITH "ph.inze.understudy"'
```
