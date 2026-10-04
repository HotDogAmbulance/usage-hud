# Changelog

## Unreleased

- Claude Code connects by itself: when it's on the Mac, the app adds session-start, prompt and end-of-turn hooks plus its statusline to `~/.claude/settings.json` (one backup, nothing else touched, someone else's statusline kept), and adds them again if Claude Code is reinstalled. The hooks also fire in the Claude app's Code tab, and they only nudge the running app, so a hook never brings a Keychain prompt. **Live from Claude Code** in Claude's menu switches it off; the uninstaller removes them; a deleted app leaves them silent.
- An idle Claude battery now says it updates when you next use Claude Code, in the CLI or the app's Code tab.
- Menus are shorter: the provider in bold with its plan or balance, then one line per reading with the value in bold, such as "5h  96% left · ↻ 4h 11m"; long resets read "4d 9h". Money drops empty cents everywhere: "$0 / $20 · this month", "$1.25 / $20"; a capped OpenRouter key reads "$0 / $5 · ↻ 12h 35m". When every reading is old, "cached" shows once beside the name instead of on each line.
- Free resets show for Codex and Claude ("Free resets  2 · until Oct 23"), and Claude shows its prepaid balance. Both are read hourly with the same sign-in the battery already uses; either one failing just leaves its row out. Codex's purchased credits show only when there are some, instead of "0 credits left".
- Antigravity's and OpenRouter's hover panels open with one bold line ("Antigravity  14 models", "OpenRouter  $26.25 left · 2 keys"); each pool or key shows its battery and when it refills.
- Battery digits are Regular 10pt SF Pro (tabular), measured against macOS 27's own battery: Medium 11pt stood taller with thicker strokes.
- Batteries leave with their source: uninstalling Antigravity, Codex or Grok, signing out of Claude Code, or deleting a provider's key removes its battery, and one without a good read for a week hides too. Closing an app or an outage only dims it. The background keeps checking, so each returns by itself with its next good read.
- A provider used in the last ten minutes refreshes every minute instead of every five, so Codex and Antigravity batteries follow a chat while it runs. A provider paused after a Keychain prompt stays paused.
- Keychain prompts can't come back every few minutes, even for someone who clicks Allow instead of Always Allow: secrets stay in memory and are fetched again only when the Keychain item itself changes (its attributes are read without asking). While Claude Code's statusline reports, Claude's battery doesn't touch the Keychain at all; extra-usage credits still update hourly.
- Antigravity groups models that share a quota into one row each ("Claude & GPT", "Gemini"), leads the battery with the tightest pool, and folds untouched pools into one full row named by their families ("GPT & Gemini") when a plan has many; the per-model submenu is gone. A closed Antigravity no longer pulses; its battery dims with the last reading.
- Sign-in problems offer their fix: "Sign in to Claude again…" in the battery menu runs `claude auth login` out of sight, the browser opens, and the battery refreshes once you approve there; no Terminal, nothing to type. A CLI that needs a terminal after all gets one (through a .command file, so no Automation permission). Only commands built into the app can run.
- An idle Claude Code token is no longer a sign-in problem: the battery keeps its last reading and heals by itself the next time Claude Code runs, including from its statusline.
- The menu bar learns each person's main tools: a week-long usage score, counted per five-minute stretch so chatty providers don't win, decides which batteries stay visible and which takes the first spot, instead of whichever was used last.
- DeepSeek, Kimi and Vercel need no Keychain setup when their key is already in `DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`/`KIMI_API_KEY` or `AI_GATEWAY_API_KEY`, or in Claude Code's settings.
- The 7d layer behind 5h (and the hovered 7d view) sinks toward grey instead of white on dark menu bars, so it no longer reads as the Mac's own battery from a distance. GLM, Grok and Vercel move from white and silver to indigo, slate and warm grey for the same reason. The self-test fails if any tint drifts back toward white, and writes font-preview.png to compare digit fonts.
- Batteries lose the faint white fringe around full fills (each layer now fills only its own span), and their digits are bold like the system battery's and centred on their ink, so "100" no longer sits left and high.
- OpenRouter's hover panel draws each key as a small battery, green, yellow under 30% and red under 10%, widens to show whole reset times, mentions refresh problems, and opens faster.
- A management key kept in a profile or script is recognised and lists the team; your own keys appear once, not again in the team list. Revoked keys in old scripts are skipped, and OpenRouter stays hidden until one key works. The key search runs hourly, not every refresh.
- Codex and Claude stay out of the menu bar until their first read; any hidden provider still appears when it needs you (a Keychain prompt or a rejected key).
- Keychain: a prompt's pause lifts after a day, and Claude Code hooks respect it too.
- A Refresh chosen during a background pass runs right after it instead of being dropped.
- Balance alerts say "Balance low" and cap alerts "near its cap" without amounts, so one hover silences them; an overdrawn balance alerts.
- The app opens at login once installed (macOS 13+), ignores launch arguments macOS adds, survives a CLI that exits early, and uses your own home folder when the app was built on another Mac.
- GLM: a limit in an unknown unit is no longer shown as the 5h window, and one host refusing the key still tries the other.

- Codex and Grok work when the app is opened from Finder or at login: npm, nvm, bun and Volta installs are found, and each CLI runs with its own folder on PATH so `node` resolves.
- GLM needs no setup when Claude Code already points at Z.ai or Zhipu: the key comes from `~/.claude/settings.json` and goes only to the quota host.
- A Keychain password prompt can never repeat on its own: after one, background refreshes leave that provider alone and its battery asks you to choose Refresh (then Always Allow). OpenRouter no longer touches the Keychain just to decide whether to refresh.
- OpenRouter needs no setup: keys already in `OPENROUTER_API_KEY`, shell profiles, AI tool configs or `.sh` scripts within three levels of home (skipping folders macOS guards) are found by their exact format and named after their variable or file. `providers.json` still overrides.
- OpenRouter team mode: one management key lists every enabled key (paged), with a hover panel of per-key cap cells and an All keys menu. Teammates at their caps don't pulse; your own keys do. OpenRouter now refreshes in the background once a key is configured, and stays out of the menu bar until its first read.
- Batteries that need attention pulse soft red until hovered: a rejected key or expired sign-in, an OpenRouter key within 10% of its cap, or a balance under `lowBalance` ($1 by default). Alerting batteries always stay in the menu bar.
- OpenRouter keys read today's spend, remaining cap and reset period from OpenRouter, count days in UTC, and list the key closest to its cap first.
- Draw for light menu bars too: dark outlines, and pale tints deepen so white and silver batteries stay visible.
- Read Claude extra usage in the currency's minor units (`decimal_places`, cents by default); show spend without a cap, and Off when disabled. Money rows now appear in hover text.
- Offer newer GitHub releases from every battery menu.
- Show at most three batteries, the most recently used; the rest fold into a +N item that opens on hover. Set `visibleBatteries` to change the limit.
- Balance batteries stretch with their digits: $26 keeps the standard size, $26.25 widens to fit.
- Match battery colours to each brand: DeepSeek's whale blue, Kimi's azure, Gemini's four-colour mark; black-and-white brands (GLM, Grok, Vercel) use light neutrals. OpenRouter turns poison green.
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
