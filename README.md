# Usage HUD

A tiny floating window showing how much Claude and Codex usage you've got
left, so you stop finding out you're rate-limited mid-task.

```
CLAUDE
  5h       #...........   6%   resets 4h38m
  7d       ##..........  12%   resets 6d09h

CODEX
  5h       ####........  32%   resets 2h29m
  1wk      #...........  12%   resets 6d05h
```

Drag it wherever, it stays out of the way and updates itself. No login, no
config file, no server. Everything shown comes from files already on disk,
plus one thing explained below.

## What it does

- Live progress bar per quota window, for both Claude and Codex.
- Codex: zero setup, reads `~/.codex/sessions/**/rollout-*.jsonl` directly.
- Claude: works out of the box too. Install wires it into Claude Code's
  `statusLine` so it updates for free on every turn; if that's somehow
  not set up, it falls back to probing Anthropic's API itself.
- `--once` / `--json` for a terminal/script check instead of the window.
- Drag to move, `r` redraw, `R` force-refresh, `q`/Esc quit, right-click
  for the same as a menu.

## Is this for you?

Mac, and you use Claude Code and/or Codex CLI. Only use one? The other
panel just says "no data yet" — nothing breaks.

## Before you install

Needs Python 3.9+ with Tk. The installer looks for one and tells you what
to do if it can't find one. You're covered if you have any of:

- [`uv`](https://docs.astral.sh/uv/) (`uv python install 3.12`)
- Homebrew's `python3`, or the python.org installer
- Xcode Command Line Tools (`/usr/bin/python3`)

Apple Silicon or Intel, macOS 10.13+. It's a shell script + icon, not a
compiled binary, so architecture doesn't matter.

## Install

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh
```

Finds a working Python, copies `usage_hud.py` into `~/.usage-hud/` (so it
survives you deleting this clone), wires up the Claude statusline, and
builds **Usage HUD.app** in `~/Applications`. Double-click to run, or add
it to **Login Items** to start at login.

Flags, if you need them:

```bash
./install.sh --dest "/Applications"     # install for all users
./install.sh --python /path/to/python3  # skip auto-detect
./install.sh --launch                   # open it right after install
```

## Command-line flags

```
usage_hud.py                     start the floating HUD
usage_hud.py --once              print one snapshot, exit
usage_hud.py --json              same, as JSON
usage_hud.py --claude-statusline used internally by Claude Code
usage_hud.py --install-claude-statusline   wire it up (install.sh does this for you)
usage_hud.py --probe-claude      force one live quota check
usage_hud.py --probe-if-stale    internal hook entry point
usage_hud.py --alpha 0.9         window opacity
usage_hud.py --refresh 20        seconds between redraws
```

## Why Claude needs a keychain, not just a file

Codex writes its numbers to a log, easy. Claude has no such file, because
Anthropic doesn't expose a "check my quota" endpoint — the only place that
number exists is in the response of a real API call. So getting it means
making a real call, authenticated as *you*, against your actual Pro/Max
plan. That means reusing Claude Code's own OAuth token from the keychain
(refreshing it when it expires, same as Claude Code does) instead of
asking you to paste in a separate API key with its own separate quota.
None of this is an official integration — it's built by matching what
Claude Code itself does.

## Why it's safe to run

- No telemetry, nothing phones home.
- Codex and cached Claude data: just local files.
- The only network calls: `api.anthropic.com` for the quota check, and
  (only if your token expired) Anthropic's OAuth refresh endpoint — same
  calls Claude Code itself makes. Your token never leaves your keychain
  and is never logged.
- Each live check costs ~1 token and is throttled to once per 5 minutes.

It's one file, no dependencies — read `usage_hud.py` yourself if you want
to be sure.

## What's in here

```
usage_hud.py      the whole app, stdlib only
install.sh        finds Python+Tk, builds and installs the .app
uninstall.sh      removes it
icon/AppIcon.icns app icon
```

## Uninstalling

```bash
./uninstall.sh            # removes the .app
./uninstall.sh --purge    # also wipes ~/.usage-hud
```

Doesn't touch the `statusLine` entry in `~/.claude/settings.json` — edit
that by hand if you want it gone (a backup of your old settings was saved
the first time it was installed).

## License

MIT, see [LICENSE](LICENSE).
