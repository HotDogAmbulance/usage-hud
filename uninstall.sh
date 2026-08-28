#!/bin/bash
# uninstall.sh - remove the Usage HUD app (and optionally its saved state).
#
# Usage:
#   ./uninstall.sh [--dest DIR] [--name NAME] [--purge]
#
#   --dest DIR   where the .app was installed (default: ~/Applications)
#   --name NAME  app bundle display name (default: Usage HUD)
#   --purge      also delete ~/.usage-hud (cached quota data, saved window
#                position, and the installed copy of usage_hud.py)

set -euo pipefail

DEST="$HOME/Applications"
APP_NAME="Usage HUD"
PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        --purge) PURGE=1; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

APP="$DEST/$APP_NAME.app"
STATE_DIR="${USAGE_HUD_HOME:-$HOME/.usage-hud}"

pkill -f "$STATE_DIR/usage_hud.py" 2>/dev/null || true

if [ -d "$APP" ]; then
    rm -rf "$APP"
    echo "Removed: $APP"
else
    echo "Not found (already removed?): $APP"
fi

if [ "$PURGE" -eq 1 ]; then
    if [ -d "$STATE_DIR" ]; then
        rm -rf "$STATE_DIR"
        echo "Removed: $STATE_DIR"
    fi
else
    echo "Kept: $STATE_DIR (cached quota data, position, script). Pass --purge to remove it too."
fi

echo
echo "Note: this does not remove a Claude Code statusLine entry you may have"
echo "installed via --install-claude-statusline. Edit ~/.claude/settings.json"
echo "by hand to remove it (a backup was saved as settings.json.usage-hud-backup"
echo "the first time you ran that command)."
