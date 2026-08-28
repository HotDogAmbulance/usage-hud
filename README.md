# Usage HUD

A small, always-on-top floating window for macOS that shows how much of your
Claude and Codex/ChatGPT usage quota is left.

```
CLAUDE
  5h       #...........   6%   resets 4h38m
  7d       ##..........  12%   resets 6d09h

CODEX
  5h       ####........  32%   resets 2h29m
  1wk      #...........  12%   resets 6d05h
```

Everything is read from local files. The only network calls are optional,
on-demand quota probes to Anthropic's own API, made with Claude Code's own
OAuth token — see [Privacy & security](#privacy--security).

## Features

- Floating, draggable, always-on-top HUD with a live progress bar per quota
  window (5-hour / weekly, for both Claude and Codex).
- No setup needed for Codex: reads `rate_limits` straight out of
  `~/.codex/sessions/**/rollout-*.jsonl`.
- For Claude, wires into Claude Code's `statusLine` hook so every
  conversation (interactive or headless/agent) keeps the cache fresh, and
  can also live-probe the API directly using Claude Code's own keychain
  credentials when the cache goes stale.
- `--once` / `--json` for scripting or a terminal check instead of the GUI.
- Right-click for a menu (refresh, probe now, clear cache, quit); `q`/Esc to
  quit, `r` to redraw, `R` to force a live probe.

## Requirements

- macOS 10.13+
- Python 3.9+ with Tk support. Most installs already have this — Homebrew's
  `python3`, `python.org` installers, and `uv python install` builds all
  bundle Tk. Apple's bare-bones system Python usually does not.

## Install

```bash
git clone https://github.com/<you>/usage-hud.git
cd usage-hud
./install.sh
```

This finds a working Python 3 + Tk, copies `usage_hud.py` into
`~/.usage-hud/` (so the app keeps working after you delete the clone), and
builds **Usage HUD.app** into `~/Applications`.

Useful flags:

```bash
./install.sh --dest "/Applications" # install system-wide instead of ~/Applications
./install.sh --python /path/to/python3   # skip auto-detection
./install.sh --launch                    # open it once install finishes
```

Double-click **Usage HUD.app** to start it. To have it start automatically,
add it to **System Settings > General > Login Items**.

## Claude Code live data

Codex works out of the box. For Claude, run once:

```bash
python3 ~/.usage-hud/usage_hud.py --install-claude-statusline
```

This wires the script into `~/.claude/settings.json` as your `statusLine`
command (backing up any existing one first). After your next message in
Claude Code, the HUD fills in. From then on:

- Every interactive turn refreshes the cache via the statusline hook.
- Headless/agent runs refresh it via a `UserPromptSubmit` hook
  (`--probe-if-stale`), if you've wired one up.
- When the cache goes stale or a window resets, the HUD probes the API
  directly (throttled), or press `R` to force it immediately.

## CLI reference

```
usage_hud.py                     start the floating HUD
usage_hud.py --once              print one snapshot to stdout and exit
usage_hud.py --json              print one snapshot as JSON and exit
usage_hud.py --claude-statusline use as Claude Code's statusLine command
usage_hud.py --install-claude-statusline   wire the above into settings.json
usage_hud.py --probe-claude      force one live quota probe now
usage_hud.py --probe-if-stale    internal: UserPromptSubmit hook entry point
usage_hud.py --alpha 0.9         HUD opacity (0.3-1.0)
usage_hud.py --refresh 20        seconds between redraws
```

## Privacy & security

- No telemetry, no analytics, no third-party services.
- Codex and cached Claude data are read from files already on your disk.
- The only outbound requests are quota probes to `api.anthropic.com` and
  (only when your access token has expired) `platform.claude.com`'s OAuth
  refresh endpoint — the same calls Claude Code itself makes. The OAuth
  token is read from, and any refreshed token is written back to, the
  `Claude Code-credentials` item in your macOS keychain. It is never logged,
  printed, or sent anywhere other than those two Anthropic endpoints.
- Each probe costs about 1 token against your quota and is throttled to at
  most once every 5 minutes.

## Uninstall

```bash
./uninstall.sh            # removes the .app
./uninstall.sh --purge    # also deletes ~/.usage-hud (cached data, script)
```

This does not remove a `statusLine` entry from `~/.claude/settings.json`;
edit that file by hand if you want to revert it (a backup was written the
first time you ran `--install-claude-statusline`).

## License

MIT — see [LICENSE](LICENSE).
