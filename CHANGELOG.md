# Changelog

## Unreleased

- Match battery colours to each brand: DeepSeek's whale blue, Kimi's azure, Gemini's four-colour mark; black-and-white brands (GLM, Grok, Vercel) use light neutrals.
- Add optional Vercel AI Gateway, DeepSeek and Kimi balance batteries, read from each provider's documented balance endpoint.
- Hovering over a Codex or Claude battery shows its 7d window on its own, in the lighter weekly shade; moving away returns to 5h.
- Remove the white weekly boundary marker.
- Add optional GLM Coding Plan, Gemini CLI and Grok CLI batteries. Each appears only after its first successful read; see PROVIDERS.md for setup.

## 2.0.1 — 2026-10-03

- Use transparent cutout digits and the system semibold font, matching the macOS battery reference.
- Increase weekly-layer contrast and retain its boundary under overlapping 5-hour fill.
- Give OpenRouter a pale violet body and more room for the dollar balance.

## 2.0 — 2026-10-03

- Move all provider reads, quota normalization, CLI hooks, cache and credit accounting to Swift.
- Remove Python source, collector processes and interpreter configuration from the app and repository.
- Introduce a small Swift package and a shared provider protocol; no third-party dependencies.
- Lock atomic cache merges across app and CLI; preserve existing configuration and cached readings.
- Retain native battery styling, weekly fallback, manual credit refresh and normal app reopening.
- Add native checks for transport deadlines, failure isolation, credentials, cache migration and Decimal accounting.


## 2026-10-03

- Replace the floating Tk note with native Swift menu-bar batteries.
- Layer 5h and 7d inside a single body, with cached-weekly fallback.
- Read live Codex quota through standalone CLI app-server and Claude usage through GET, without inference or credential mutation.
- Isolate providers, remove obsolete window/activity/log-scan paths, preserve credit accounting and Claude hooks.
- Bundle the native executable directly and handle app reopening.
- Update installation and documentation for Swift UI plus stdlib Python adapters.


## 2026-08-29

- Claude's quota now refreshes on real session activity, not just hooks.
  Turns out `Stop` never fires on a mid-turn cancel, and `UserPromptSubmit`
  can't be trusted to catch a one-shot run from another agent or tool. So
  now the HUD also watches `~/.claude/sessions/*.json` — Claude Code's own
  busy/idle status file, written for every `claude` process on the machine
  whether or not it goes through our hooks — and re-checks quota the moment
  anything changes there. The old timer's still around as a backstop, just
  loosened up since it's not doing the heavy lifting anymore.
- Fixed that same change firing a needless extra probe on every normal
  turn too, not just the gap cases — a completed turn flips the session
  file *and* the statusline cache at once, so now it only probes when
  activity changed without a matching cache write.

## 2026-08-28

- Statusline is now the default way Claude quota gets fed in — free,
  updates every turn, no extra API calls. Direct probing is the fallback
  for when that's not wired up.
- Initial release: floating HUD for Claude + Codex usage, install/uninstall
  scripts, app icon.
