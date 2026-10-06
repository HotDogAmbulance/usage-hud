# Changelog

## Unreleased

- Expired Claude sign-in renews itself the way Claude Code always does: when the credential has expired, Usage HUD makes your own `claude` command send one tiny request (haiku, no tools, nothing saved), then removes the empty project folder it leaves in `~/.claude/projects`. At most once per six hours (retry after half an hour if it failed), at most three times in a row without real use, with a notice and a line in `~/.usage-hud/renewals.log`; `touch ~/.usage-hud/no-auto-renew` turns it off. The expired-credential message now says so.

- Many sources: the stacked-batteries logo opens a tray (every battery as a tile, springing out of the logo; Reduce Motion fades instead) in place of a menu that opened on hover. Hover only shows "+n more"; clicking a tile keeps that battery in the bar, or lets it go, and a battery asking for attention is never pushed out; right-click a tile for its menu. Click anywhere else to put the tray away. The key rows in the hover panel no longer repeat as a tooltip, and show five keys, the rest under "All keys (n)".
- Add a source: drop a file or folder on the bar, or choose "Add source…" in the tray (hidden folders can be chosen). Only the paths are kept, in `~/.usage-hud/key-sources.json`; keys are read when needed and stay in memory.
- The group's capsule is a flat tint of the bar's ink, shown only on hover and while a menu or the tray is open, with the full bar height and wider padding; panels use a popover blur with a hairline edge.

- Menu-bar group: more room inside the rounded edge (7 pt) and between batteries (6 pt each pair), and the stack logo follows the same ink strength as the empty part of a battery. The empty part is now the bar's own ink (white at 44.7% on a dark bar, black at 42.4% on a light one, measured on the Mac's own battery over seven solid bars) instead of one grey, so no wallpaper can match it; a provider's 5h colour is no longer darkened on a light bar, and the 7d layer is that colour at about half strength over the empty part. `--self-test` writes `track-contrast.png` comparing the result with the measurements. macOS reports every click on the group (one status item) at one fixed point, so a click is given to the cell the pointer is really over, not to the one at that point; the stack logo is coloured in the image because the template tint did not reach it; with a file `~/.usage-hud/click-debug` present, clicks are logged to `click-log.txt` (positions and cell names only).

- Detail batteries follow the originating menu bar’s contrast, including VibrantDark/VibrantLight, rather than the hover panel’s independent appearance. Healthy key/budget cells are white on dark bars and black on light bars; warning colors and cached marks stay consistent.
- Antigravity rows carry model-family palettes. The recently used pool selects the main palette; Google/Gemini uses Google colors, Claude & GPT uses black/charcoal plus Claude earth tone, and unknown families stay neutral.
- Model-only hover identifiers now use available installed vendor templates without adding another quota table. Missing templates retain ordinary names/tooltips; aggregator/infra and Antigravity retain detail tables.
- 5h/7d warnings follow the tighter current window. Claude connection/refresh controls are temporarily hidden while Desktop quota delivery is unresolved; cached status remains visible and collection behavior is unchanged.

- Automatic source notices: new connections and confirmed removals share a quiet native notice that disappears after six seconds. Successful-reader receipts choose the wording; startup, repeat reads, cached data and temporary outages do not generate notices.
- Codex failure recovery now checks its actual quota cache file.

- Claude: an expired credential now says the HUD is waiting for fresh usage. Documentation distinguishes activity hooks from statusline quota data, bounds the reported Desktop/CLI renewal observation, and explains the missing reset-grant indicator and current hybrid OAuth/statusline collection.
- Round 3: bound HTTP bodies while receiving and reject redirects; keep LiteLLM addresses and keys paired by source; preserve negative balance digits; tolerate extreme numeric fields; keep Keychain prompt pauses until manual refresh; suppress new low-balance warnings from failed/cached readings; create self-test output folders.

- Review fixes: the test list compiles again; xAI teams billed afterwards no longer error on the missing prepaid ledger; Fireworks accounts may contain `_`; a LiteLLM gateway that is down is left alone for an hour instead of costing 30 s at every refresh; plain `http` is accepted only for localhost and local-network proxies; Kimi's TOML may use single quotes; `--help` lists every provider; battery digits drop any currency symbol, not just `$`.
- The Antigravity battery follows the pool you used last and dissolves into the next one when it changes; a spent pool simply reads 0, with no pulse, and the battery turns the Mac's red only when every pool is at 20% or less. New brand colours: GLM #01989B, Kimi #1161BE (Kimi Code #147DF3), Fireworks #5D1CE6, LiteLLM #FB6A2A, Grok black and xAI graphite blue (both lifted to grey on a dark bar, where black would vanish); OpenRouter stays #C8FE01. One yellow (#FFD800) and one red (#FF3B30) serve the battery warnings: a 5h/7d reading with 15% and then 10% left, spent Antigravity pools, a low OpenRouter balance and the pulse; the small hover bars keep the Mac battery colours. GLM, Fireworks and LiteLLM paint the 7d layer in a second colour, and xAI, Fireworks and LiteLLM show their spend limit as a small battery on hover. `--self-test` writes `palette-dark.png` and `palette-light.png` to `~/.usage-hud` with every battery.
- OpenRouter's battery is lime (#C8FE01), turns yellow under $15 and breathes a faint red under $10, and its body is as full as the tightest capped key.

- Grok works again: current Grok CLI versions refuse the billing RPC the HUD used, so it now reads credit usage from the CLI's own billing endpoint with the sign-in `grok login` saved, and shows the plan ("SuperGrok Heavy"). An old sign-in waits quietly for the CLI to renew it.
- New batteries, hidden until their first good read and not yet checked against real accounts: **Kimi Code** (5h, weekly and monthly windows), **xAI** API teams (prepaid balance, or spend against the spending limit, with a management key), **Fireworks** (spend against the monthly limit) and **LiteLLM** proxies (a virtual key's spend against its budget). Each finds its key the way the others do: Claude Code's settings, the provider's own CLI config, or the usual variables.
- All key-based providers share one adapter (`KeyProvider`), so a new one is a few lines. A key's spend with no cap shows as "$3 spent" and never counts as a low balance.
- Claude Code connects by itself: when it's on the Mac, the app adds session-start, prompt and end-of-turn hooks plus its statusline to `~/.claude/settings.json` (one backup, nothing else touched, someone else's statusline kept), and adds them again if Claude Code is reinstalled. The hooks also fire in the Claude app's Code tab, and they only nudge the running app, so a hook never brings a Keychain prompt. **Live from Claude Code** in Claude's menu switches it off; the uninstaller removes them; a deleted app leaves them silent.
- An idle Claude battery now says it updates when you next use Claude Code, in the CLI or the app's Code tab.
- Menus are shorter: the provider in bold with its plan or balance, then one line per reading with the value in bold, such as "5h  96% left · ↻ 4h 11m"; long resets read "4d 9h". Money drops empty cents everywhere: "$0 / $20 · this month", "$1.25 / $20"; a capped OpenRouter key reads "$0 / $5 · ↻ 12h 35m". When every reading is old, "cached" shows once beside the name instead of on each line.
- Free resets show for Codex ("Free resets  2 · ends in 5d 7h"), and the row stays out when there are none; Claude shows its prepaid balance. (Claude's free resets are not shown: its server only answers them for Claude Code's own client.) Both are read hourly with the same sign-in the battery already uses; either one failing just leaves its row out. Codex's purchased credits show only when there are some, instead of "0 credits left".
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
