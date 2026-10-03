#!/bin/bash
# Build a native menu-bar app; install stdlib-only provider adapters separately.
set -euo pipefail
umask 077
DEST="$HOME/Applications"
APP_NAME="Usage HUD"
HUD_PYTHON="/usr/bin/python3"
DO_LAUNCH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --python) HUD_PYTHON="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        --launch) DO_LAUNCH=1; shift ;;
        -h|--help) echo 'Usage: ./install.sh [--dest DIR] [--python PATH] [--name NAME] [--launch]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { echo 'Requires macOS.' >&2; exit 1; }
[[ "$APP_NAME" != */* && -n "$APP_NAME" ]] || { echo 'Invalid app name.' >&2; exit 1; }
"$HUD_PYTHON" -c 'import sys; assert sys.version_info >= (3,9), "Python 3.9+ required"'
xcrun --find swiftc >/dev/null
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${USAGE_HUD_HOME:-$HOME/.usage-hud}"
HUD_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$HUD_BUILD_DIR"' EXIT
APP="$HUD_BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -target "$(uname -m)-apple-macosx12.0" "$REPO_DIR/MenuBar.swift" -o "$APP/Contents/MacOS/usage-hud-menubar"
"$HUD_PYTHON" - "$APP/Contents/Info.plist" "$APP_NAME" "$STATE_DIR" "$HUD_PYTHON" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump(dict(CFBundleName=sys.argv[2], CFBundleDisplayName=sys.argv[2],
        CFBundleIdentifier='local.usage-hud', CFBundleVersion='2', CFBundleShortVersionString='1.1',
        CFBundlePackageType='APPL', CFBundleExecutable='usage-hud-menubar', CFBundleIconFile='AppIcon',
        LSUIElement=True, LSMinimumSystemVersion='12.0', NSHighResolutionCapable=True,
        UsageHUDDataDirectory=sys.argv[3], UsageHUDPython=sys.argv[4]),file)
PY
cp "$REPO_DIR/icon/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$STATE_DIR/plugins" "$DEST"
chmod 700 "$STATE_DIR" "$STATE_DIR/plugins"
cp "$REPO_DIR/usage_hud.py" "$REPO_DIR/collector.py" "$STATE_DIR/"
cp "$REPO_DIR/plugins/"*.py "$STATE_DIR/plugins/"
chmod 600 "$STATE_DIR/"*.py "$STATE_DIR/plugins/"*.py
# Keep credentials, caches, provider settings and Claude Code settings intact.
if [ -e "$DEST/$APP_NAME.app" ]; then
    mv "$DEST/$APP_NAME.app" "$HUD_BUILD_DIR/previous.app"
fi
mv "$APP" "$DEST/$APP_NAME.app"
echo "Installed: $DEST/$APP_NAME.app"
echo 'Sign in using standalone Codex CLI and Claude Code; no desktop app is required.'
if [ "$DO_LAUNCH" -eq 1 ]; then open "$DEST/$APP_NAME.app"; fi
