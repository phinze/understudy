# Edge-trigger investigation: "need the camera" instead of "plugged in"

Notes-to-self for a follow-up session. Context is fresh now (2026-07); it
won't be later.

## UPDATE 3 (2026-10) — superseded by the virtual camera

The make-or-break question below got its answer from the observe-only log:
yes, apps still emit `device-control` while the Cam Link is wedged (Chrome did,
right before both manual kicks the week of 2026-10-02). The same log showed two
more things. The wedges developed hours after a clean wake check, and an ffmpeg
probe once read "healthy" a minute before Chrome's video was plainly broken. So
probing from the side is wrong in both directions: it misses wedges and it can
cause storms.

The fix was to stop being a side client. `mac/` adds a CoreMediaIO virtual
camera whose host agent is the Cam Link's *only* client. Demand comes from the
extension's own stream start (no log scraping), and health is whether our own
session gets frames, which is exactly what the meeting app experiences. See the
README's "Virtual camera mode". Everything below is history.

## UPDATE 2 (2026-07) — reactive trigger REVERTED: it caused a UVC interrupt storm

The `device-control` reactive trigger from UPDATE 1 got reverted. It turned a
working machine into a molasses swamp: load 20-36 on a 16-core box with almost
no visible CPU%, terminals crawling.

Mechanism: a health check isn't passive — `canCapture` opens the Cam Link via
ffmpeg *twice* (a `1x1` mode-detect open, then a capture at the device's full
advertised mode, e.g. `3840x2160@30`). The reactive trigger fired one of those
on every `device-control` edge, rate-limited to once per 30s. During a live
meeting that means the daemon bolts its own ffmpeg client onto the *already
streaming* camera every 30 seconds, all call long — forcing the macOS UVC stack
to attach/detach a second client on an active isochronous stream over and over.
On a marginal Cam Link through a dock, that tips it into a pathological USB
interrupt pattern: `kernel_task` ~14k wakeups/s, ~10k IPI/s on one core,
`UVCAssistant` pinned ~550ms/s. The device keeps producing frames (so the health
check reads "healthy" and never resets — the blind spot), it just floods the bus.

Background apps made it worse: an idle "Around" was throwing `device-control`
edges every few minutes while the user wasn't even using it, so the daemon was
poking a live camera all day.

Reverted to observe-only on the camCh path. Real wedges are still caught by the
`startup`/`wake`/`usb-arrival` checks and the manual `--kick`. The cost is we no
longer proactively check the instant you open a meeting app; if the camera
wedges from something *other* than sleep/usb mid-session, hit `--kick`.

If we ever revisit a reactive trigger: the fix is to NOT probe when a real
client is already streaming successfully (the app's own success IS the health
signal — probing then is both useless and actively harmful). And/or add
storm-aware detection (watch the wakeup/IPI rate, not just "did I get a frame")
so a storm self-heals instead of sitting there. Neither is worth it unless the
problem recurs with the reactive trigger gone.

## UPDATE — root cause was the health check, not the trigger

The edge-trigger turned out to be a fix for a symptom. The real bug: the health
check hardcoded a capture format (`1920x1080@59.94`), and a Cam Link advertises
a *different* mode depending on its HDMI source (locked to a 1080p60 source it's
`1920x1080@59.94`; with no signal it's `3840x2160@30`). So the moment the mode
wasn't exactly the hardcoded one, ffmpeg I/O-errored and the daemon read a
perfectly healthy camera as broken and reset it. That's the aggression, and it
had nothing to do with *when* we checked.

Verified matrix (capturing at whatever mode the device *advertises*, not a
hardcoded one):

| state | advertises | grab at advertised mode |
|---|---|---|
| healthy + signal | 1920x1080@59.94 | frame, instant |
| healthy + no signal | its current mode | frame, instant (the Elgato pane) |
| wedged | stale/nothing, or ports dark | no frame |

Fix shipped: `health.Check` now detects the advertised mode and captures at it,
and logs ffmpeg stderr on failure. This alone kills the false-positive resets,
no demand signal required. Also fixed a nastier bug found the same day: an
interrupted reset (killed during its power-off window) left the USB ports dark,
which is what actually wedged the camera during debugging. Reset now guarantees
power-on (deferred) and the daemon calls `reset.Heal` at startup to recover any
stranded-dark ports.

Net: the health-check fix is the core correctness fix. camwatch was then
promoted from observe-only to a real trigger — its `device-control` signal (an
app actually grabbing the camera) now fires a health check, so a wedge that
develops mid-session gets caught when you open your meeting app instead of
sitting there unnoticed. Guards: our own probes (ffmpeg/system_profiler) are
ignored to avoid a self-trigger loop, and a 30s cooldown keeps a live meeting
from re-probing constantly. So the "need the camera" edge trigger from the
original investigation did land — it just rides on top of the health-check fix
rather than replacing it. Everything below is the original investigation, kept
for context.

---

## The idea

Today the daemon fires its check-and-reset on environmental events: `wake`,
`usb-arrival`, `startup`, plus the manual `SIGUSR1` kick. Three of those four
are "something changed in my hardware environment," which means the camera gets
reset on every lid-open whether or not you're about to use it. On a meeting-free
week that's pure downside: unnecessary power-cycles (and notifications) for a
camera you were happy to leave off.

We want to move the trigger from "plugged the laptop in" toward "an app actually
reached for the camera." The open question was whether macOS even exposes a
usable "camera demanded" signal. It does.

## What we found (the signal)

macOS logs camera activity through CoreMediaIO. Streaming the unified log
(`log stream --predicate 'subsystem == "com.apple.cmio" ...'`) surfaces markers
when an app opens a camera. There is no single clean "camera opened" line;
instead there are three, and which one fires depends on state:

- **cold-start** — `CMIO_DAL_System.cpp:...:CheckOutInstance The System is
  starting`. Fires only when the app is the first CMIO client after the system
  was fully torn down.
- **warm-open** — `CMIO_DAL_System.cpp:...:Get System unsuspended`. Fires on a
  normal open when the DAL system was already alive. Bursts ~17x per open.
- **device-control** — `...:SetPropertyData ... setting deviceControlPID`.
  Fires when a client takes (or releases) control of an actual device. Closest
  thing to "about to stream." This looks like the most promising signal.

Crucially, all three are logged by the **client app itself**, so the ndjson
`processImagePath` is the app (e.g. "Photo Booth"), not a system daemon. We get
attribution for free. (`process` is often null in ndjson; fall back to the
basename of `processImagePath`.)

## What we built (this is shipped as observe-only)

`internal/camwatch/watcher_darwin.go` tails `log stream --style ndjson` for all
three markers, tags each with its signal name, debounces the per-open burst
(3s per process+signal), and emits an `Event{Process, Signal}`. It is wired into
`cmd/camlink-fix/main.go` but **drives nothing** — the select case just logs:

```
camera-open observed (app="Photo Booth" signal=device-control) — not acting (observe-only)
```

The whole point of shipping it observe-only is to collect real-world data across
scenarios we can't reproduce on the couch, before committing to the rework.

## Where to look

Log lands in `/tmp/camlink-fix.log` (the launchd agent redirects stdout/stderr
there). To scan for real app opens, filter out our own health-check probes:

```
grep 'camera-open observed' /tmp/camlink-fix.log | grep -vE 'system_profiler|ffmpeg'
```

`system_profiler` and `ffmpeg` are the daemon's *own* health check opening the
camera, and they look identical to any other app. The apps that matter are the
real ones: `zoom.us`, `Google Chrome` (browser-based Meet shows up as the
browser process, not "Meet"), Slack, FaceTime, etc.

## Questions the observe phase should answer

1. **Which signal reliably means "I need the camera"?** Hypothesis:
   `device-control`. Confirm against real meeting joins.
2. **THE make-or-break one: does the signal still fire when the Cam Link is
   wedged?** The whole edge-trigger idea depends on it. Can't be manufactured on
   demand; only happens after certain sleep/wake cycles. Next time your camera
   is black in a call, check whether camwatch logged a `device-control` around
   that timestamp.
3. **Do real meeting apps behave like Photo Booth?** Zoom vs a Meet tab in the
   browser vs Slack huddle vs FaceTime may emit different mixes of the three
   signals.
4. **What's the false-positive rate?** How much does the log light up during a
   normal day from background apps polling the camera?

Note: in pure observe-only mode we do NOT run a health check at open time, so
the log won't independently confirm the camera was wedged at that instant. We
correlate by timestamp against the wake-triggered health checks already in the
log. If that turns out too soft, we could add a passive health check on each
open, but that risks fighting the app for the device (and re-introduces the
ffmpeg self-trigger), so we left it out for now.

## Gotchas for the NEXT phase (wiring it to actually reset)

- **Feedback loop.** Our health check opens the camera (system_profiler +
  ffmpeg) → camwatch sees a camera-open → which would trigger another health
  check → loop. Before camwatch can drive a reset, suppress our own probe PIDs
  (or otherwise exclude our processes).
- **Latency tradeoff.** A reactive trigger means eating the ~10-20s reset
  latency at the moment you join the call, instead of the current model where
  wake pre-warms the camera before you sit down. This is the fundamental cost of
  going reactive.

## Options on the table (from the design discussion)

1. **Camera-demand hook** (what we built) — truest "need it" edge trigger, but
   pays the reset latency at join time, and depends on question #2 above.
2. **Calendar pre-warm** — check the calendar, run the fix a couple minutes
   before a meeting. Sidesteps the latency problem and stays silent on
   meeting-free weeks. Needs calendar access. Arguably the best fit since your
   meetings are calendared.
3. **Lean on the manual kick** — menu-bar item / hotkey, make the human the
   edge. Zero magic, but you have to remember it.

Likely landing spot: calendar-warm as primary with the manual kick as fallback,
and fold in the camera-open signal if question #2 validates. Demoting the `wake`
trigger is the common thread in all of them.

## Status / deploy

- Code committed and pushed to `main` (`2cbd91c`).
- nix-config `flake.lock` bumped to that rev; `darwin-rebuild build` validated
  clean.
- **PENDING:** the `darwin-rebuild switch` has NOT been run yet, so the live
  daemon is still the old build with no camwatch. Finish with:
  ```
  sudo darwin-rebuild switch --flake ~/src/github.com/phinze/nix-config#phinze-mrn-mbp
  ```
  Then confirm `camwatch: listening for camera-open events` shows up in
  `/tmp/camlink-fix.log`.
