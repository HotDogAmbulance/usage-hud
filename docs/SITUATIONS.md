# When something goes wrong

Every reader follows the same rules when its source lets it down. The rules are kept by a test, `testSituationMatrix` in `Tests/UsageHUDCoreTests/SituationTests.swift`, which runs each provider through the situations below and compares what a person would see with the policy. `swift run usagehud-tests` runs it with the rest.

## The rules

1. **Never worked, never shown.** A provider that has not yet given one good reading stays out of the menu bar, whatever goes wrong. The one exception is a key the person stored on purpose (or the one Claude Code itself uses for Z.ai) that the provider refuses: its battery appears and asks, so they can fix it.
2. **After a good reading, a failure keeps the last numbers, dimmed.** Offline, a timeout, a 5xx, a 429, an answer that is not JSON, too large, or in a different shape: the battery keeps what it last read, dimmed, with the reason in its note. It never turns into zero, into full, or into something that looks fresh.
3. **Quiet unless only the person can fix it.** A stored key or sign-in the provider refuses makes the battery pulse. A key merely found in a shell profile or a script, refused, stays quiet. OpenRouter, which holds many keys, says once that a key was refused and then drops its row.
4. **A source that is gone takes its battery with it.** A deleted Keychain item, an uninstalled app or CLI: the battery leaves. A closed app or an outage only dims. OpenRouter announces which key went and keeps the others.
5. **It comes back by itself.** The next good read clears the dimming, the note and the alert. A gateway that has answered as LiteLLM is never written off for being down, slow or refusing a key for a while; only an address that never answered like it is left alone.
6. **A window the provider stops sending does not linger.** If a plan change or a renamed field drops a window from the answers, its old reading stays, dimmed, only while it could still be true: until its own reset, or, with no reset time, for twice its length.
7. **No secret leaves memory.** After every cell below, the key is searched for in the cache folder and in the panels' JSON.

## The matrix

`dim` the last numbers stay, dimmed, quiet. `dim+asks` the same, and the battery pulses. `says why` the row's own text states the problem. `leaves` the battery goes. `n/a` the situation does not exist for that reader. `(known)` differs from the rules on purpose, see below.

| provider | key from | offline | timeout | server error | rate limited | rejected | not JSON | too large | shape changed | source removed | recovery |
|---|---|---|---|---|---|---|---|---|---|---|---|
| claude | Keychain | dim | dim | dim | dim | dim+asks | dim | dim | dim | leaves | recovers |
| openrouter | profile | dim | dim | dim | dim | says why | dim | dim | dim | leaves | recovers |
| openrouter | Keychain | dim | dim | dim | dim | says why | dim | dim | dim | says why (known) | recovers |
| glm | Claude Code settings | dim | dim | dim | dim | dim+asks (known) | dim | dim | dim | leaves | recovers |
| glm | Keychain | dim | dim | dim | dim | dim+asks | dim | dim | dim | leaves | recovers |
| vercel, deepseek, kimi, kimi-code, xai, fireworks | profile | dim | dim | dim | dim | dim | dim | dim | dim | leaves | recovers |
| vercel, deepseek, kimi, kimi-code, xai, fireworks | Keychain | dim | dim | dim | dim | dim+asks | dim | dim | dim | leaves | recovers |
| litellm | profile | dim | dim | dim | dim | dim | dim | dim | dim | leaves | recovers |
| antigravity | the running app | dim | n/a | n/a | n/a | n/a | n/a | n/a | dim+asks (known) | leaves | recovers |
| grok | Grok CLI sign-in | dim | dim | dim | dim | dim | dim | dim | dim | leaves | recovers |
| grokbot | the app's saved reading | dim | n/a | n/a | n/a | n/a | n/a | n/a | dim | leaves | recovers |
| codex | Codex CLI | dim | n/a | n/a | n/a | dim | dim | n/a | dim | n/a | recovers |

The six key readers behave alike, so the test runs each of them but the table shows them once. For Codex, "offline" is the CLI closing its pipe, "rejected" an error from its server, and a hung CLI is covered by `testProcessTimeoutIsBounded`.

### Differences on purpose

- **openrouter, Keychain key removed → says why.** OpenRouter holds several keys. One whose Keychain item is gone is announced once and its row goes; the battery stays for the others.
- **glm, key from Claude Code's settings, refused → asks.** That is the key Claude Code itself uses for Z.ai; if it is refused, that tool is broken too.
- **antigravity, answer without quota → asks (once it has worked).** A signed-out app and a changed local protocol answer the same way, so the battery asks the person to look. An app that was never signed in stays out of the bar.

## Covered by their own tests

Claude's expired sign-in and its renewal, the 429 back-off, statusline readings taking precedence, Keychain prompts that never return on their own, plan changes at Codex (`testProUsesWeeklyWindowInsteadOfOldFiveHour`), reset boundaries and early resets (`testWindowNormalizationAndReset`, `testAnEarlyResetReadsFreshNotStale`), UTC cap resets, extreme and malformed numbers, redirects and oversized bodies, teams of a hundred keys.

## Not yet checked against a real account

Fixtures only, no live read: Kimi Code, xAI, Fireworks, LiteLLM, Grok CLI, GLM (Z.ai's monitor endpoint is not a documented API) and Codex Pro. The matrix proves how each reader behaves when an answer goes wrong; it cannot prove the first answer is read correctly. See [PROVIDERS.md](PROVIDERS.md).

## Adding a provider

Add a `World` in `SituationTests.swift`: how to plant its source, how to build it, what a healthy answer looks like and what a changed one looks like. The matrix then runs it through every situation. A cell that differs from the rules needs an entry in `acceptedCells` with the reason.
