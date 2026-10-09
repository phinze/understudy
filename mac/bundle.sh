#!/bin/bash
set -euo pipefail

# Build, bundle, and sign Understudy.app with its embedded camera extension.
# Same shape as music-stuff's dj/bundle.sh: SwiftPM builds the binaries, this
# script hand-assembles the bundles and signs them with the Apple Development
# cert.
#
# Prerequisites (one-time, developer portal, team 472M2826KP):
#   1. App ID ph.inze.understudy with the System Extension capability
#   2. App ID ph.inze.understudy.camera (no capabilities needed)
#   3. A macOS App Development profile for each, saved as
#      Resources/host.provisionprofile and Resources/camera.provisionprofile
#
# Without the profiles this still builds and ad-hoc signs, which is enough to
# check that everything compiles and assembles, but sysextd will refuse it.
#
#   ./bundle.sh            build + assemble + sign into .build/Understudy.app
#   ./bundle.sh --install  ...then copy to /Applications and activate

cd "$(dirname "$0")"

MODE="${1:-}"
case "$MODE" in
    ""|--install) ;;
    *) echo "Usage: $0 [--install]" >&2; exit 2 ;;
esac

HOST_PROFILE="Resources/host.provisionprofile"
CAMERA_PROFILE="Resources/camera.provisionprofile"
EXT_ID="ph.inze.understudy.camera"

APP_DIR=".build/Understudy.app"
CONTENTS="$APP_DIR/Contents"
EXT_DIR="$CONTENTS/Library/SystemExtensions/$EXT_ID.systemextension"

# sysextd only replaces an installed extension with a *newer* CFBundleVersion,
# so stamp every build.
VERSION="$(date +%Y%m%d%H%M%S)"

# The commit this build came from, stamped into the app so the agent can
# tell when nix-darwin has moved Understudy past what's installed (Nix
# can't build or sign the app itself). In jj the source is @, or @- when @
# is the empty working-copy commit; uncommitted edits make it "dirty".
source_revision() {
    if command -v jj >/dev/null && jj root >/dev/null 2>&1; then
        if [ -n "$(jj log --no-graph -r @ -T 'if(empty, "", "x")' 2>/dev/null)" ]; then
            echo dirty
        else
            jj log --no-graph -r @- -T 'commit_id' 2>/dev/null
        fi
    elif git rev-parse HEAD >/dev/null 2>&1; then
        if git diff --quiet HEAD 2>/dev/null; then git rev-parse HEAD; else echo dirty; fi
    else
        echo unknown
    fi
}
REVISION="$(source_revision)"

team_id_from_profile() {
    [ -f "$1" ] || return 1
    security cms -D -i "$1" 2>/dev/null \
        | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null
}

SIGNED=1
TEAM_ID="${UNDERSTUDY_TEAM_ID:-$(team_id_from_profile "$HOST_PROFILE" || true)}"
if [ -z "$TEAM_ID" ] || [ ! -f "$CAMERA_PROFILE" ]; then
    echo "WARNING: provisioning profiles missing; ad-hoc signing (won't activate)." >&2
    SIGNED=0
    TEAM_ID="${TEAM_ID:-TEAMID}"
fi

echo "==> Building..."
# Clear Nix SDK vars so system Swift uses its own SDK
unset SDKROOT DEVELOPER_DIR
swift build -c release

echo "==> Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$EXT_DIR/Contents/MacOS"

# render <src> <dst>: fill in TEAMID, VERSION and REVISION placeholders.
render() {
    sed -e "s/TEAMID/$TEAM_ID/g" -e "s/VERSION/$VERSION/g" -e "s/REVISION/$REVISION/g" "$1" > "$2"
}

cp .build/release/understudy "$CONTENTS/MacOS/understudy"
render Resources/host-Info.plist "$CONTENTS/Info.plist"

cp .build/release/understudy-camera "$EXT_DIR/Contents/MacOS/$EXT_ID"
render Resources/camera-Info.plist "$EXT_DIR/Contents/Info.plist"

if [ "$SIGNED" = 1 ]; then
    cp "$HOST_PROFILE" "$CONTENTS/embedded.provisionprofile"
    cp "$CAMERA_PROFILE" "$EXT_DIR/Contents/embedded.provisionprofile"

    # `|| true` because under pipefail a grep with no match would exit here
    # silently, before the message below could explain.
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk -F'"' '{print $2}' || true)
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: No valid Apple Development signing identity found." >&2
        exit 1
    fi
else
    IDENTITY="-"
fi

echo "==> Signing with: $IDENTITY"
ENT_DIR=$(mktemp -d)
trap 'rm -rf "$ENT_DIR"' EXIT
render Resources/camera.entitlements "$ENT_DIR/camera.entitlements"
render Resources/host.entitlements "$ENT_DIR/host.entitlements"

# Inside out: the extension first, then the app that seals it.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENT_DIR/camera.entitlements" "$EXT_DIR"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENT_DIR/host.entitlements" "$APP_DIR"

codesign --verify --strict --deep "$APP_DIR"

if [ "$MODE" = "--install" ]; then
    if [ "$SIGNED" = 0 ]; then
        echo "ERROR: refusing to install an ad-hoc build; add the profiles first." >&2
        exit 1
    fi
    # /Applications, not ~/Applications: sysextd won't activate from anywhere
    # else.
    echo "==> Installing to /Applications/Understudy.app..."
    rm -rf /Applications/Understudy.app
    ditto "$APP_DIR" /Applications/Understudy.app
    echo "==> Activating..."
    /Applications/Understudy.app/Contents/MacOS/understudy activate

    # macOS can lose an upgrade: while the old extension's launchd job is
    # still dying, CMIO decides the new one is "already running", skips
    # launching it, and the camera vanishes even though sysextd says
    # activated. Installing once more (with a new version stamp) after the
    # old job is gone registers it cleanly.
    camera_listed() {
        system_profiler SPCameraDataType 2>/dev/null | grep -q '^ *Understudy:$'
    }
    listed=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if camera_listed; then listed=1; break; fi
        sleep 1
    done
    if [ "$listed" = 0 ]; then
        if [ -n "${UNDERSTUDY_BUNDLE_RETRY:-}" ]; then
            echo "ERROR: virtual camera still missing after a retry; a reboot clears it." >&2
            exit 1
        fi
        echo "WARNING: virtual camera didn't register (macOS upgrade race); reinstalling once..." >&2
        sleep 1
        UNDERSTUDY_BUNDLE_RETRY=1 exec "$0" --install
    fi
    echo "==> (Re)starting agent..."
    AGENT_LABEL="org.nixos.understudy"
    if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
        # nix-darwin owns the agent; let launchd restart it with its own env.
        launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"
    else
        # Restart through LaunchServices so TCC attributes camera access to
        # Understudy, not to whatever terminal ran this script. That launch
        # doesn't inherit our PATH, so pass uhubctl's location explicitly.
        pkill -f '/Applications/Understudy.app/Contents/MacOS/understudy' || true
        # LaunchServices needs a beat to notice the old instance is gone, or
        # open fails with -600.
        while pgrep -f '/Applications/Understudy.app/Contents/MacOS/understudy' >/dev/null; do sleep 0.2; done
        sleep 1
        open -g --env "UNDERSTUDY_UHUBCTL=$(command -v uhubctl || echo uhubctl)" /Applications/Understudy.app
    fi
fi

echo "==> Done (version $VERSION, revision $REVISION)."
