# Usage HUD

A tiny floating window that sits on top of everything and tells you how much
of your Claude and Codex usage you've got left, so you stop finding out
you're rate-limited mid-task.

```
CLAUDE
  5h       #...........   6%   resets 4h38m
  7d       ##..........  12%   resets 6d09h

CODEX
  5h       ####........  32%   resets 2h29m
  1wk      #...........  12%   resets 6d05h
```

That's it, that's the app. Drag it wherever, it stays out of the way, and it
updates itself. No login, no config file to hand-edit, no server anywhere.

Everything it shows comes from files already on your disk. The only time it
talks to the network is an optional, on-demand quota check against
Anthropic's own API, using Claude Code's own login — more on that below.

## What it actually does

- Floating always-on-top bar with a progress bar per quota window (5-hour
  and weekly, for both Claude and Codex).
- Codex needs zero setup — it just reads `rate_limits` out of
  `~/.codex/sessions/**/rollout-*.jsonl`, which Codex CLI already writes.
- Claude needs one command (below) to hook into Claude Code's `statusLine`,
  after which every conversation you have — interactive or a headless agent
  run — keeps the numbers fresh. When the cache goes stale it'll also probe
  the API directly on its own, or you can press `R` to force it.
- `--once` / `--json` if you'd rather check from a terminal or a script
  than look at the window.
- Drag to move, `r` to redraw, `R` to force-refresh Claude's numbers, `q`
  or Esc to quit, right-click for a menu with the same options.

## Is this for you?

If you use Claude Code and/or the Codex CLI on a Mac and have ever wanted
to glance at a corner of your screen instead of running a command to check
your quota — yes. Only use one of the two tools? Fine, the other panel just
says "no data yet" instead of complaining.

## Before you install

You need a Python 3.9+ that has Tk (the GUI toolkit) built in. This trips
people up more than anything else here, so the installer checks for you and
tells you exactly what's missing if nothing works. In practice:

- Got [`uv`](https://docs.astral.sh/uv/)? `uv python install 3.12` bundles Tk. Done.
- Got Homebrew's `python3`, or the python.org installer? Also bundles Tk.
- Got Xcode Command Line Tools installed? Their Python (`/usr/bin/python3`)
  has Tk too.
- A totally bare Mac has no usable `python3` at all — the installer will
  tell you which of the above to run.

Runs on Apple Silicon and Intel alike — it's a shell script and an icon in
a folder, not a compiled binary, so there's nothing architecture-specific
about it. macOS 10.13 or newer.

## Install

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh
```

It finds a working Python, copies `usage_hud.py` into `~/.usage-hud/` (so
the app keeps working even after you delete this cloned folder), and builds
**Usage HUD.app** in `~/Applications`. Double-click it to run. Add it to
**System Settings > General > Login Items** if you want it running from
login onward.

A couple of flags if the defaults don't suit you:

```bash
./install.sh --dest "/Applications"     # install for all users instead of ~/Applications
./install.sh --python /path/to/python3  # skip auto-detection, use a specific interpreter
./install.sh --launch                   # open it as soon as install finishes
```

## Hooking up live Claude data

Codex works the moment you install. Claude actually works out of the box
too, as long as you're already logged into Claude Code: the moment the HUD
opens with no cached numbers, it fires off one live probe on its own,
straight to Anthropic's API using Claude Code's own login from your
keychain, and fills in within a couple of seconds. No message required.

The one thing that live probe costs is about a token off your quota per
check, so it's throttled to once every 5 minutes. If you'd rather it update
for free on every turn instead, run this once:

```bash
python3 ~/.usage-hud/usage_hud.py --install-claude-statusline
```

This drops the command into `~/.claude/settings.json` as your `statusLine`.
Claude Code already computes your rate-limit numbers for its own status bar
on every turn — this just also hands a copy to the HUD, so it stays current
for free and even covers headless/agent runs, without ever calling the API
itself. It's a nice-to-have, not a requirement.

## Why the Claude side is more involved than the Codex side

Codex CLI just writes your rate-limit numbers to a local log file, so
reading them is a non-issue. Claude has no equivalent "check my quota" file
or endpoint, because Anthropic doesn't publish one — the only two places
that number exists at all are:

1. The `rate_limits` object Claude Code's own client receives for its
   status bar, on every turn, but only while a conversation is running.
2. A handful of response headers (`anthropic-ratelimit-unified-5h-...`)
   that come back on any real API call — meaning the only way to ask "how
   much do I have left" is to actually make a request and read its headers.

There's no free-standing, read-only "get my usage" API. So to show you a
number without a conversation open, this script does the only thing
available: it makes a real (tiny, ~1 token) API call itself, authenticated
as you, and reads those headers. To call the API "as you" against your
Pro/Max plan's shared pool — rather than a separate API key with its own
separate, billed pool — it has to reuse Claude Code's own login rather than
asking you to generate a new credential. That's the whole reason it reads
Claude Code's OAuth token from the macOS keychain, and why it also knows
how to refresh that token when it expires (via the same OAuth endpoint
Claude Code itself calls on startup) and write the renewed one back.

None of this is a documented, supported integration — it's built by reading
how Claude Code behaves and doing the same thing. That's also why it needs
a specific `anthropic-beta` header and a Claude-Code-shaped User-Agent
string just to get an authenticated response instead of a block. If
Anthropic ever ships an actual "check my quota" endpoint, most of this
file gets a lot shorter.

## Command-line flags

```
usage_hud.py                     start the floating HUD
usage_hud.py --once              print one snapshot to stdout and exit
usage_hud.py --json              same, but as JSON
usage_hud.py --claude-statusline used internally as Claude Code's statusLine command
usage_hud.py --install-claude-statusline   wire the above into settings.json for you
usage_hud.py --probe-claude      force one live quota check right now
usage_hud.py --probe-if-stale    internal: hook entry point, re-probes only when stale
usage_hud.py --alpha 0.9         window opacity, 0.3 to 1.0
usage_hud.py --refresh 20        seconds between redraws
```

## Why it's safe to run

I get it, a script that reads your Claude Code credentials sounds like a
thing to be careful with, so here's exactly what it does and doesn't do:

- No telemetry, no analytics, nothing phoning home to me or anyone else.
- Codex data and the Claude cache are just files it reads off your disk.
- The only outbound calls are to `api.anthropic.com` (the quota check) and,
  only when your token has actually expired, `platform.claude.com`'s OAuth
  refresh endpoint — the exact same calls Claude Code itself makes on
  startup. Your token is read from the `Claude Code-credentials` item in
  the macOS keychain, and if it gets refreshed, written back to that same
  keychain entry. It is never logged, printed, or sent anywhere else.
- Each check costs roughly one token off your quota and won't fire more
  than once every 5 minutes.

Read `usage_hud.py` yourself before trusting any of this — it's one file,
no dependencies, nothing hidden in a build step.

## What's in here

```
usage_hud.py      the whole app, stdlib only
install.sh        finds Python+Tk, builds and installs the .app
uninstall.sh       removes it again
icon/AppIcon.icns  the app icon
```

## Uninstalling

```bash
./uninstall.sh            # removes the .app
./uninstall.sh --purge    # also wipes ~/.usage-hud (cached data, the installed script)
```

It won't touch the `statusLine` entry in `~/.claude/settings.json` — that's
a one-line edit if you want it gone, and a backup of your old settings was
saved the first time you ran `--install-claude-statusline`.

## License

MIT, see [LICENSE](LICENSE). Do whatever you want with it.
