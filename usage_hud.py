#!/usr/bin/env python3
"""
usage_hud.py - a small always-on-top floating window showing how much of your
Claude and Codex/ChatGPT usage quota is left.

Everything is read from local files. No network calls, no credentials, no scraping.

Modes
-----
  python3 usage_hud.py                     start the floating HUD
  python3 usage_hud.py --once              print one snapshot to stdout and exit
  python3 usage_hud.py --json              print one snapshot as JSON and exit
  python3 usage_hud.py --claude-statusline use as Claude Code's statusLine command
  python3 usage_hud.py --install-claude-statusline   wire the above into settings.json
  python3 usage_hud.py --probe-claude      force one live quota probe now
  python3 usage_hud.py --probe-if-stale    internal: Claude Code UserPromptSubmit
                                           hook - live-probe when cache > 2 min old

Data sources
------------
  Claude : Claude Code passes a `rate_limits` object on stdin to your statusline
            command (Claude Code >= 2.1.80, Pro/Max subscribers). --claude-statusline
            caches it to ~/.usage-hud/claude.json. These numbers are the *account*
            quota, shared by Claude Code, claude.ai and the desktop app.
            Every conversation start keeps this live: interactive turns via the
            statusline hook, headless agent runs via a UserPromptSubmit hook
            (--probe-if-stale re-probes through the API whenever the cache is
            over 2 minutes old). When the cache goes stale or a window resets,
            the HUD also probes the API directly with Claude Code's own OAuth
            token from the macOS keychain (a ~1-token request), renewing that
            token itself when it expires, so fresh numbers arrive without
            opening Claude. In the HUD, R forces such a live probe immediately.
  Codex  : Codex CLI writes `token_count` events containing `rate_limits` into
           ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Read directly, no setup.

Keys: drag to move - r redraw - R live-probe Claude quota now - q or Esc quit - right-click for menu.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HOME = Path.home()
STATE_DIR = Path(os.environ.get("USAGE_HUD_HOME", HOME / ".usage-hud"))
CLAUDE_CACHE = STATE_DIR / "claude.json"
POS_FILE = STATE_DIR / "position.json"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", HOME / ".codex"))

REFRESH_SECONDS = 20
STALE_AFTER = 6 * 3600  # cached Claude numbers older than this are marked stale
TAIL_BYTES = 512 * 1024  # how much of a session log to read from the end

KEYCHAIN_ITEM = "Claude Code-credentials"
API_URL = "https://api.anthropic.com/v1/messages"
OAUTH_REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # Claude Code's public client id
OAUTH_UA = "claude-cli/2.1.80 (external, cli)"  # python-urllib UA is Cloudflare-banned here
PROBE_FRESH = 900  # probe when the Claude cache is older than this (s)
PROBE_MIN = 300  # never probe more often than this (s)
HOOK_FRESH = 120  # --probe-if-stale: re-probe when the cache is older (s)
PROBE_STATE = {"probing": False, "last": 0.0, "error": None, "manual": False}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

_LABELS = {
    "five_hour": "5h",
    "seven_day": "7d",
    "primary": "5h",
    "secondary": "wk",
}


def label_for(key: str, window_minutes=None) -> str:
    if window_minutes:
        m = int(window_minutes)
        if m % 10080 == 0:
            return f"{m // 10080}wk"
        if m % 1440 == 0:
            return f"{m // 1440}d"
        if m % 60 == 0:
            return f"{m // 60}h"
        return f"{m}m"
    if key in _LABELS:
        return _LABELS[key]
    for prefix, short in _LABELS.items():
        if key.startswith(prefix):
            rest = key[len(prefix):].strip("_").replace("_", " ")
            return f"{short} {rest}".strip()
    return key.replace("_", " ")[:8]


def fmt_delta(seconds) -> str:
    if seconds is None:
        return ""
    seconds = int(seconds)
    if seconds <= 0:
        return "now"
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m"


def as_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def find_key(obj, name):
    """Depth-first search for the first value stored under `name`."""
    if isinstance(obj, dict):
        if name in obj:
            return obj[name]
        for v in obj.values():
            found = find_key(v, name)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = find_key(v, name)
            if found is not None:
                return found
    return None


def parse_windows(rate_limits: dict, captured_at: float):
    """Normalise either provider's rate_limits blob into a list of windows."""
    out = []
    if not isinstance(rate_limits, dict):
        return out
    for key, val in rate_limits.items():
        if not isinstance(val, dict):
            continue
        pct = as_float(val.get("used_percentage"))
        if pct is None:
            pct = as_float(val.get("used_percent"))
        if pct is None:
            continue

        resets_at = as_float(val.get("resets_at"))
        if resets_at is None:
            rin = as_float(val.get("resets_in_seconds"))
            if rin is not None:
                resets_at = captured_at + rin

        out.append({
            "label": label_for(key, val.get("window_minutes")),
            "pct": max(0.0, min(100.0, pct)),
            "resets_at": resets_at,
            # Once resets_at has passed the window started over, so the cached
            # percentage says nothing about the new one. Don't pretend it does.
            "expired": bool(resets_at and resets_at < time.time()),
        })
    out.sort(key=lambda w: w["resets_at"] or float("inf"))
    return out


# --------------------------------------------------------------------------
# Claude: read the cache written by the statusline hook
# --------------------------------------------------------------------------

def read_claude():
    panel = {"name": "CLAUDE", "windows": [], "note": ""}
    try:
        blob = json.loads(CLAUDE_CACHE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        panel["note"] = "no Claude data yet - send a message in Claude Code"
        return panel
    except Exception as exc:
        panel["note"] = f"cache unreadable ({exc.__class__.__name__})"
        return panel

    captured = as_float(blob.get("captured_at")) or time.time()
    panel["windows"] = parse_windows(blob.get("rate_limits") or {}, captured)
    panel["captured_at"] = captured

    if not panel["windows"]:
        panel["note"] = "no rate_limits yet - open Claude Code"
    elif time.time() - captured > STALE_AFTER:
        panel["note"] = f"stale, last seen {fmt_delta(time.time() - captured)} ago"
        for w in panel["windows"]:
            w["stale"] = True
    expired = [w["label"] for w in panel["windows"] if w.get("expired")]
    if expired:
        panel["note"] = (f"{'+'.join(expired)} window reset - waiting for fresh "
                         f"data (auto-probe or Claude Code)")
    return panel


def claude_statusline():
    """Run as Claude Code's statusLine command: cache rate_limits, print a line."""
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("")
        return 0

    if isinstance(payload.get("rate_limits"), dict):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = CLAUDE_CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps({
            "captured_at": time.time(),
            "rate_limits": payload["rate_limits"],
        }), encoding="utf-8")
        os.replace(tmp, CLAUDE_CACHE)  # atomic, survives concurrent sessions

    # Still print a useful status line so you lose nothing by installing this.
    model = payload.get("model")
    model = model.get("display_name") if isinstance(model, dict) else (model or "")
    ctx = as_float(find_key(payload.get("context_window") or {}, "used_percentage"))
    bits = [b for b in [model, f"ctx {ctx:.0f}%" if ctx is not None else ""] if b]
    for w in parse_windows(payload.get("rate_limits") or {}, time.time()):
        left = fmt_delta((w["resets_at"] - time.time()) if w["resets_at"] else None)
        bits.append(f"{w['label']} {w['pct']:.0f}%" + (f" ({left})" if left else ""))
    print(" | ".join(bits))
    return 0


def install_claude_statusline(force=False):
    settings = HOME / ".claude" / "settings.json"
    script = Path(__file__).resolve()
    command = f'"{sys.executable}" "{script}" --claude-statusline'

    data = {}
    if settings.exists():
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"! {settings} is not valid JSON ({exc}); fix it first.")
            return 1
        if data.get("statusLine") and not force:
            print(f"! You already have a statusLine configured:\n  "
                  f"{json.dumps(data['statusLine'])}\n"
                  f"  Re-run with --force to replace it, or add this command yourself:\n"
                  f"  {command}")
            return 1
        backup = settings.with_suffix(".json.usage-hud-backup")
        backup.write_text(settings.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"backed up {settings} -> {backup}")

    settings.parent.mkdir(parents=True, exist_ok=True)
    data["statusLine"] = {"type": "command", "command": command, "padding": 0}
    settings.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(f"wrote statusLine into {settings}")
    print("Now start Claude Code and send one message; the HUD fills in after that.")
    return 0


# --------------------------------------------------------------------------
# Claude direct probe: ask the API for quota headers using Claude Code's
# own OAuth token. The token is read from the keychain and never logged or
# stored anywhere except its keychain entry. When the stored access token
# has expired, it is renewed with the refresh token from that same entry
# (what Claude Code itself does on startup) and written back there.
# --------------------------------------------------------------------------

def _keychain_account():
    import subprocess
    try:
        meta = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_ITEM],
            capture_output=True, text=True, timeout=10).stdout
        for line in meta.splitlines():
            if line.strip().startswith('"acct"'):
                part = line.split("=", 1)[1].strip()
                return part.strip('"') if part and part != "<NULL>" else None
    except Exception:
        pass
    return None


def _oauth_refresh(oauth: dict, blob: dict):
    """Trade the refresh token for a fresh access token. The response rotates
    the refresh token too, so persist the pair to the keychain BEFORE the
    rotated one is allowed to go stale."""
    import subprocess
    body = json.dumps({"grant_type": "refresh_token",
                       "refresh_token": oauth.get("refreshToken"),
                       "client_id": OAUTH_CLIENT_ID}).encode()
    req = urllib.request.Request(OAUTH_REFRESH_URL, data=body, headers={
        "Content-Type": "application/json", "Accept": "application/json",
        "User-Agent": OAUTH_UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = json.loads(exc.read().decode()).get("error_description", "")[:120]
        except Exception:
            pass
        return None, (f"token refresh failed (HTTP {exc.code}"
                      f"{' - ' + detail if detail else ''}) - open Claude Code to re-login")
    except Exception as exc:
        return None, f"token refresh failed ({exc.__class__.__name__})"

    new_tok = data.get("access_token")
    if not new_tok:
        return None, "token refresh response had no access_token"
    oauth["accessToken"] = new_tok
    if data.get("refresh_token"):
        oauth["refreshToken"] = data["refresh_token"]
    oauth["expiresAt"] = int((time.time() + data.get("expires_in", 3600)) * 1000)

    cmd = ["security", "add-generic-password", "-U", "-s", KEYCHAIN_ITEM]
    acct = _keychain_account()
    if acct:
        cmd += ["-a", acct]
    cmd += ["-w", json.dumps(blob)]
    try:
        if subprocess.run(cmd, capture_output=True, text=True,
                          timeout=10).returncode != 0:
            return None, "token renewed but keychain write failed - open Claude Code"
    except Exception:
        return None, "token renewed but keychain write failed - open Claude Code"
    return new_tok, None


def claude_oauth():
    """Return (access_token, error) from Claude Code's macOS keychain entry,
    renewing the token first if it has expired."""
    import subprocess
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_ITEM, "-w"],
            capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return None, "no macOS keychain access"
    if not raw:
        return None, "no Claude Code credentials in keychain"
    try:
        blob = json.loads(raw)
        oauth = blob.get("claudeAiOauth") or blob
        tok, exp = oauth.get("accessToken"), oauth.get("expiresAt")
    except Exception:
        return None, "keychain credential unreadable"
    if not tok:
        return None, "keychain credential has no token"
    if not (exp and exp / 1000 < time.time()):
        return tok, None
    if not oauth.get("refreshToken"):
        return None, "OAuth token expired and no refresh token - open Claude Code"
    return _oauth_refresh(oauth, blob)


def probe_claude():
    """Fetch official 5h/7d quota from the API; update CLAUDE_CACHE. ~1 token."""
    tok, err = claude_oauth()
    if err:
        return False, err

    body = json.dumps({"model": "claude-haiku-4-5", "max_tokens": 1,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(API_URL, data=body, headers={
        "Authorization": f"Bearer {tok}",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
        "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            headers = {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = json.loads(exc.read().decode()).get("error", {}).get("message", "")[:120]
        except Exception:
            pass
        return False, f"probe HTTP {exc.code}{' - ' + detail if detail else ''}"
    except Exception as exc:
        return False, f"probe failed ({exc.__class__.__name__})"

    rl = {}
    for key, suffix in (("five_hour", "5h"), ("seven_day", "7d")):
        util = as_float(headers.get(f"anthropic-ratelimit-unified-{suffix}-utilization"))
        if util is None:
            continue
        window = {"used_percentage": util * 100}
        reset = as_float(headers.get(f"anthropic-ratelimit-unified-{suffix}-reset"))
        if reset:
            window["resets_at"] = reset
        rl[key] = window
    if not rl:
        return False, "no rate limit headers in API response"

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CLAUDE_CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"captured_at": time.time(), "rate_limits": rl}),
                   encoding="utf-8")
    os.replace(tmp, CLAUDE_CACHE)
    return True, ", ".join(f"{label_for(k)} {v['used_percentage']:.0f}%"
                           for k, v in rl.items())


def claude_needs_probe():
    try:
        blob = json.loads(CLAUDE_CACHE.read_text(encoding="utf-8"))
    except Exception:
        return True
    captured = as_float(blob.get("captured_at")) or 0
    if time.time() - captured > PROBE_FRESH:
        return True
    return any(w.get("expired")
               for w in parse_windows(blob.get("rate_limits") or {}, captured))


def maybe_probe():
    """Background-refresh the Claude cache when stale or expired (throttled)."""
    if PROBE_STATE["probing"] or time.time() - PROBE_STATE["last"] < PROBE_MIN:
        return
    if not claude_needs_probe():
        PROBE_STATE["error"] = None
        return
    run_probe(force=False, manual=False)


def run_probe(force=False, manual=False):
    """Kick off one probe in a background thread (single-flight). `force`
    bypasses the PROBE_MIN throttle - that is the HUD's R key. Returns True
    if a probe was started."""
    if PROBE_STATE["probing"]:
        return False
    if not force and time.time() - PROBE_STATE["last"] < PROBE_MIN:
        return False
    PROBE_STATE["probing"] = True
    PROBE_STATE["manual"] = manual

    def worker():
        try:
            ok, msg = probe_claude()
            PROBE_STATE["error"] = None if ok else msg
        finally:
            PROBE_STATE["last"] = time.time()
            PROBE_STATE["probing"] = False
            PROBE_STATE["manual"] = False

    threading.Thread(target=worker, daemon=True).start()
    return True


def probe_if_stale():
    """Hook entry point (UserPromptSubmit): every conversation start - inter-
    active or headless (agents) - refreshes the Claude cache when it is older
    than HOOK_FRESH. Never fails the host command: always exit 0."""
    try:
        try:
            blob = json.loads(CLAUDE_CACHE.read_text(encoding="utf-8"))
            age = time.time() - (as_float(blob.get("captured_at")) or 0)
        except Exception:
            age = float("inf")
        if age >= HOOK_FRESH:
            ok, msg = probe_claude()
            if not ok:
                print(f"usage-hud probe: {msg}", file=sys.stderr)
    except Exception as exc:
        print(f"usage-hud hook error: {exc.__class__.__name__}", file=sys.stderr)
    return 0


# --------------------------------------------------------------------------
# Codex: read rate_limits straight out of the newest session log
# --------------------------------------------------------------------------

def newest_codex_logs(limit=8):
    root = CODEX_HOME / "sessions"
    if not root.is_dir():
        return []
    files = []
    # sessions/YYYY/MM/DD/rollout-*.jsonl - walk newest date folders first
    for year in sorted((p for p in root.iterdir() if p.is_dir()), reverse=True):
        for month in sorted((p for p in year.iterdir() if p.is_dir()), reverse=True):
            for day in sorted((p for p in month.iterdir() if p.is_dir()), reverse=True):
                files.extend(day.glob("*.jsonl"))
                if len(files) >= limit * 3:
                    break
            if len(files) >= limit * 3:
                break
        if len(files) >= limit * 3:
            break
    if not files:  # older/flat layouts
        files = list(root.rglob("*.jsonl"))
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[:limit]


def last_rate_limits_in(path: Path):
    """Scan a session log backwards for the most recent rate_limits payload."""
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()  # drop the partial line
            lines = fh.read().splitlines()
    except OSError:
        return None

    for raw in reversed(lines):
        if b"rate_limits" not in raw:
            continue
        try:
            event = json.loads(raw)
        except Exception:
            continue
        rl = find_key(event, "rate_limits")
        if isinstance(rl, dict) and rl:
            ts = event.get("timestamp")
            captured = path.stat().st_mtime
            if isinstance(ts, str):
                try:
                    from datetime import datetime
                    captured = datetime.fromisoformat(
                        ts.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    pass
            return rl, captured
    return None


def read_codex():
    panel = {"name": "CODEX", "windows": [], "note": ""}
    logs = newest_codex_logs()
    if not logs:
        panel["note"] = "no ~/.codex/sessions found"
        return panel

    for path in logs:
        hit = last_rate_limits_in(path)
        if hit:
            rl, captured = hit
            panel["windows"] = parse_windows(rl, captured)
            panel["captured_at"] = captured
            if time.time() - captured > STALE_AFTER:
                panel["note"] = f"stale, last seen {fmt_delta(time.time() - captured)} ago"
                for w in panel["windows"]:
                    w["stale"] = True
            return panel

    panel["note"] = "no rate_limits in recent sessions"
    return panel


# --------------------------------------------------------------------------
# snapshot + text output
# --------------------------------------------------------------------------

def snapshot():
    return [read_claude(), read_codex()]


def bar(pct, width=12):
    filled = int(round(pct / 100 * width))
    return "#" * filled + "." * (width - filled)


def print_once(as_json=False):
    panels = snapshot()
    if as_json:
        print(json.dumps(panels, indent=2, default=str))
        return 0
    now = time.time()
    for p in panels:
        print(p["name"])
        for w in p["windows"]:
            if w.get("expired"):
                print(f"  {w['label']:<8} {bar(0)}     ?%  window reset since last reading")
                continue
            left = fmt_delta((w["resets_at"] - now) if w["resets_at"] else None)
            flag = "  (stale)" if w.get("stale") else ""
            print(f"  {w['label']:<8} {bar(w['pct'])} {w['pct']:5.1f}%"
                  f"  resets {left}{flag}")
        if p["note"]:
            print(f"  - {p['note']}")
        print()
    return 0


# --------------------------------------------------------------------------
# the floating window
# --------------------------------------------------------------------------

BG = "#14161a"
FG = "#e8e8ea"
DIM = "#6b7280"
TRACK = "#2a2e36"
GREEN, AMBER, RED = "#4ade80", "#fbbf24", "#f87171"
W = 246
ROW_H = 19
HEAD_H = 19
PAD = 9


def colour_for(pct):
    return GREEN if pct < 50 else (AMBER if pct < 80 else RED)


def run_hud(alpha=0.9, refresh=REFRESH_SECONDS):
    try:
        import tkinter as tk
    except ImportError:
        print("tkinter is missing. Debian/Ubuntu: sudo apt install python3-tk\n"
              "macOS/Windows: use the python.org build, which bundles it.\n"
              "Meanwhile `--once` still works in a terminal.", file=sys.stderr)
        return 1

    root = tk.Tk()
    root.title("usage")
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    try:
        root.attributes("-alpha", alpha)
    except tk.TclError:
        pass

    canvas = tk.Canvas(root, bg=BG, highlightthickness=0, bd=0)
    canvas.pack(fill="both", expand=True)

    x, y = 60, 60
    try:
        pos = json.loads(POS_FILE.read_text(encoding="utf-8"))
        x, y = int(pos["x"]), int(pos["y"])
    except Exception:
        pass
    root.geometry(f"+{x}+{y}")

    drag = {"x": 0, "y": 0}

    def start_drag(e):
        drag["x"], drag["y"] = e.x, e.y

    def do_drag(e):
        root.geometry(f"+{root.winfo_pointerx() - drag['x']}"
                      f"+{root.winfo_pointery() - drag['y']}")

    def save_and_quit(*_):
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            POS_FILE.write_text(json.dumps(
                {"x": root.winfo_x(), "y": root.winfo_y()}), encoding="utf-8")
        except Exception:
            pass
        root.destroy()

    def draw():
        canvas.delete("all")
        maybe_probe()
        panels = snapshot()
        now = time.time()
        yy = PAD
        for p in panels:
            if p["name"] == "CLAUDE":
                if PROBE_STATE["probing"] and PROBE_STATE["manual"]:
                    p["note"] = "probing quota (R)..."
                elif PROBE_STATE["probing"]:
                    p["note"] = "auto-probing quota..."
                elif PROBE_STATE["error"]:
                    p["note"] = f"auto-probe: {PROBE_STATE['error']}"
            canvas.create_text(PAD, yy, anchor="nw", text=p["name"],
                               fill=DIM, font=("TkDefaultFont", 9, "bold"))
            yy += HEAD_H
            for w in p["windows"]:
                expired = w.get("expired")
                pct = 0.0 if expired else w["pct"]
                col = DIM if (expired or w.get("stale")) else colour_for(pct)
                canvas.create_text(PAD, yy + 4, anchor="nw", text=w["label"],
                                   fill=DIM, font=("TkDefaultFont", 9))
                bx0, bx1 = PAD + 26, W - 96
                canvas.create_rectangle(bx0, yy + 5, bx1, yy + 12,
                                        fill=TRACK, outline="")
                end = bx0 + (bx1 - bx0) * pct / 100
                if end > bx0:
                    canvas.create_rectangle(bx0, yy + 5, end, yy + 12,
                                            fill=col, outline="")
                canvas.create_text(bx1 + 8, yy + 4, anchor="nw",
                                   text="?" if expired else f"{pct:.0f}%", fill=col,
                                   font=("TkDefaultFont", 9, "bold"))
                left = ("reset" if expired else
                        fmt_delta((w["resets_at"] - now) if w["resets_at"] else None))
                if left:
                    canvas.create_text(W - PAD, yy + 4, anchor="ne", text=left,
                                       fill=DIM, font=("TkDefaultFont", 9))
                yy += ROW_H
            if p["note"]:
                canvas.create_text(PAD, yy, anchor="nw", text=p["note"],
                                   fill=DIM, font=("TkDefaultFont", 8))
                yy += ROW_H - 3
            yy += 4

        root.geometry(f"{W}x{int(yy + PAD - 4)}")

    # 1 s heartbeat: cache writes from any Claude conversation (statusline on
    # interactive turns, UserPromptSubmit hook on headless agent runs) or from
    # a probe show up live; everything else redraws on the regular cadence.
    last_cache = {"m": None}
    ticks = {"n": 0}

    def cache_state():
        try:
            return CLAUDE_CACHE.stat().st_mtime_ns
        except OSError:
            return None

    def tick():
        ticks["n"] += 1
        m = cache_state()
        changed = m != last_cache["m"]
        last_cache["m"] = m
        if changed:
            PROBE_STATE["error"] = None  # fresh data supersedes probe errors
            draw()
        elif ticks["n"] * 1 >= refresh:
            ticks["n"] = 0
            draw()
        canvas.after(1000, tick)

    def clear_claude_cache(*_):
        try:
            CLAUDE_CACHE.unlink()
        except FileNotFoundError:
            pass
        draw()

    def manual_probe(*_):
        run_probe(force=True, manual=True)  # R: live check right now
        draw()
        return "break"

    menu = tk.Menu(root, tearoff=0)
    menu.add_command(label="Refresh", command=draw)
    menu.add_command(label="Probe Claude quota now (R)", command=manual_probe)
    menu.add_command(label="Clear Claude cache", command=clear_claude_cache)
    menu.add_command(label="Quit", command=save_and_quit)

    for widget in (root, canvas):
        widget.bind("<Button-1>", start_drag)
        widget.bind("<B1-Motion>", do_drag)
        widget.bind("<Button-3>", lambda e: menu.tk_popup(e.x_root, e.y_root))
        widget.bind("<Button-2>", lambda e: menu.tk_popup(e.x_root, e.y_root))
    root.bind("<Escape>", save_and_quit)
    root.bind("q", save_and_quit)
    root.bind("r", lambda e: draw())
    root.bind("R", manual_probe)

    draw()
    tick()
    root.mainloop()
    return 0


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--once", action="store_true", help="print a snapshot and exit")
    ap.add_argument("--json", action="store_true", help="print a snapshot as JSON")
    ap.add_argument("--claude-statusline", action="store_true",
                    help="internal: Claude Code statusLine command")
    ap.add_argument("--install-claude-statusline", action="store_true",
                    help="wire this script into ~/.claude/settings.json")
    ap.add_argument("--probe-claude", action="store_true",
                    help="probe the API for fresh Claude quota and update the cache")
    ap.add_argument("--probe-if-stale", action="store_true",
                    help="internal: hook entry point - probe only when the "
                         "cache is older than HOOK_FRESH; always exit 0")
    ap.add_argument("--force", action="store_true",
                    help="with --install-claude-statusline, replace an existing one")
    ap.add_argument("--alpha", type=float, default=0.9, help="opacity, 0.3-1.0")
    ap.add_argument("--refresh", type=int, default=REFRESH_SECONDS,
                    help="seconds between refreshes")
    args = ap.parse_args()

    if args.claude_statusline:
        return claude_statusline()
    if args.probe_if_stale:
        return probe_if_stale()
    if args.probe_claude:
        ok, msg = probe_claude()
        print(("ok - " if ok else "failed - ") + msg)
        return 0 if ok else 1
    if args.install_claude_statusline:
        return install_claude_statusline(force=args.force)
    if args.once or args.json:
        return print_once(as_json=args.json)
    return run_hud(alpha=args.alpha, refresh=args.refresh)


if __name__ == "__main__":
    sys.exit(main())
