#!/bin/bash
# Build and install the macOS-only Swift app. No runtime interpreter.
set -euo pipefail
umask 077
DEST="$HOME/Applications"
APP_NAME="Usage HUD"
DO_LAUNCH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        --launch) DO_LAUNCH=1; shift ;;
        -h|--help) echo 'Usage: ./install.sh [--dest DIR] [--name NAME] [--launch]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { echo 'Requires macOS.' >&2; exit 1; }
[[ "$APP_NAME" != */* && -n "$APP_NAME" ]] || { echo 'Invalid app name.' >&2; exit 1; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${USAGE_HUD_HOME:-$HOME/.usage-hud}"
HUD_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$HUD_BUILD_DIR"' EXIT
swift build --package-path "$REPO_DIR" --configuration release --product usagehud
BIN_DIR="$(swift build --package-path "$REPO_DIR" --configuration release --show-bin-path)"
BINARY="$BIN_DIR/usagehud"
APP="$HUD_BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STATE_DIR" "$DEST"
chmod 700 "$STATE_DIR"
cp "$BINARY" "$APP/Contents/MacOS/usagehud"
"$BINARY" --write-bundle-info "$APP/Contents/Info.plist" "$APP_NAME" "$STATE_DIR"
cp "$REPO_DIR/icon/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Stop only this app's executables; never touch Codex or Claude processes.
"$BINARY" --stop-running "$DEST/$APP_NAME.app/Contents/MacOS/usagehud"
"$BINARY" --stop-running "$DEST/$APP_NAME.app/Contents/MacOS/usage-hud-menubar"
"$BINARY" --stop-running "$STATE_DIR/usage-hud-menubar"
if [ -e "$DEST/$APP_NAME.app" ]; then mv "$DEST/$APP_NAME.app" "$HUD_BUILD_DIR/previous.app"; fi
mv "$APP" "$DEST/$APP_NAME.app"
ln -sfn "$DEST/$APP_NAME.app/Contents/MacOS/usagehud" "$STATE_DIR/usagehud"
USAGE_HUD_HOME="$STATE_DIR" "$BINARY" --migrate-hooks
# Retire only the app's known Python files; leave caches and configuration alone.
rm -f "$STATE_DIR/usage_hud.py" "$STATE_DIR/collector.py" "$STATE_DIR/test_usage_hud.py" "$STATE_DIR/test_plugins.py" "$STATE_DIR/usage-hud-menubar"
for name in __init__ claude codex openrouter; do rm -f "$STATE_DIR/plugins/$name.py"; done
rm -rf "$STATE_DIR/__pycache__" "$STATE_DIR/plugins/__pycache__"
rmdir "$STATE_DIR/plugins" 2>/dev/null || true
echo "Installed native Swift app: $DEST/$APP_NAME.app"
if [ "$DO_LAUNCH" -eq 1 ]; then open "$DEST/$APP_NAME.app"; fi
