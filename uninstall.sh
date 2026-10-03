#!/bin/bash
# Remove the app, optionally its cache; never remove provider credentials.
set -euo pipefail
DEST="$HOME/Applications"
APP_NAME="Usage HUD"
PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        --purge) PURGE=1; shift ;;
        -h|--help) echo 'Usage: ./uninstall.sh [--dest DIR] [--name NAME] [--purge]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ "$APP_NAME" != */* && -n "$APP_NAME" ]] || exit 1
APP="$DEST/$APP_NAME.app"
STATE_DIR="${USAGE_HUD_HOME:-$HOME/.usage-hud}"
BINARY="$APP/Contents/MacOS/usagehud"
if [ -x "$BINARY" ]; then "$BINARY" --stop-running "$BINARY"; fi
rm -rf "$APP"
rm -f "$STATE_DIR/usagehud"
if [ "$PURGE" -eq 1 ]; then
    case "$STATE_DIR" in ''|/|"$HOME") echo 'Refusing an unsafe purge directory.' >&2; exit 1 ;; esac
    rm -rf "$STATE_DIR"
fi
echo 'Removed Usage HUD. Provider credentials were not changed.'
echo 'Remove any Usage HUD hooks from Claude settings if no longer needed.'
