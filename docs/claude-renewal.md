# Renewing an expired Claude Code sign-in without touching the token

Written so other tools can reuse it instead of working it out again. Observed on macOS with Claude Code 2.1.289 in October 2026; behaviour may change, and Anthropic has not documented any of this as a supported way to read usage.

## The problem

Claude Code keeps its OAuth credential in the macOS Keychain (`Claude Code-credentials`) with an `expiresAt` about eight hours ahead. Claude Code renews it only when it makes a request. A tool that reads usage on the side (a menu-bar app, a status monitor) therefore finds an expired credential after a long stretch without a terminal session, and the Desktop app's Code tab did not renew it in our tests. `claude auth status` does not renew it either: it makes no request.

## The technique

Let `claude` renew itself by making one tiny request, from a throwaway directory, and discard the result:

```sh
mkdir -p ~/.usage-hud/renew && cd ~/.usage-hud/renew
claude -p "Reply with the single word OK" --model haiku --no-session-persistence \
  --setting-sources local --tools "" --disable-slash-commands \
  --output-format stream-json --verbose
```

- The tool never reads, writes or refreshes the token; Claude Code does what it always does before a request.
- `--no-session-persistence` saves no conversation. Claude Code still left an empty `memory` folder under `~/.claude/projects/<directory name>`; the tool removes that one folder (the name is the working directory with every `/` and `.` turned into `-`).
- `--setting-sources local` keeps your own hooks and settings out of the call; `--bare` is not an option because it does not read OAuth or the Keychain.
- Cost: about 6,700 tokens (mostly Claude Code's own system prompt), roughly 1.4 cents at API prices.

## A bonus: the quota arrives with it

With `--output-format stream-json --verbose` the stream contains a `rate_limit_event`:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour",
 "unifiedWindows":{"five_hour":{"utilization":0.23,"resetsAt":1791293400},
                   "seven_day":{"utilization":0.4,"resetsAt":1791489600}}}}
```

`utilization` is a fraction (0.23 is 23%); it matched Claude Code's own display. That is the 5h and 7d quota reported by Claude Code itself, with no call to the undocumented usage endpoint.

## Limits worth keeping

Only when the credential has expired; at most once every six hours after a success and again after half an hour after a failure; stop after three renewals in a row with no real use in between; tell the person each time and log it; provide an opt-out. See `Sources/UsageHUDCore/ClaudeRenewal.swift` and its test for one implementation.

## Not established

Whether Anthropic's terms allow timer-driven automated `claude -p` calls on a subscription; whether the stream format stays stable. `claude -p` is documented as a supported programmatic mode.
