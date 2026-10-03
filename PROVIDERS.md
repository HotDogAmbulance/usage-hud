# Providers

`UsageProvider` in `Sources/UsageHUDCore/Providers.swift` is the plugin boundary: stable `id`, display `name`, automatic/manual refresh policy, `refresh()` and `panel()`. Register another adapter in `Engine`. Provider failures are isolated. UI consumes normalized `Panel`/`Window` models and contains no provider-auth or HTTP logic.

Quota adapters persist `used_percentage`, `window_minutes` where applicable, `resets_at` and a capture timestamp per window. Missing windows retain their previous reading as stale. The battery displays remaining percentage; no reset is interpreted as a fresh zero.

## OpenRouter

Create `~/.usage-hud/providers.json` with your own Keychain selectors:

```json
[
  {
    "id": "worker-1",
    "label": "Worker 1",
    "sources": [
      {"provider": "openrouter", "service": "com.example.openrouter", "account": "primary"}
    ]
  }
]
```

Ordered sources provide fallbacks. Keep slot IDs stable. A source change or new local day resets the daily baseline. Today's spend is measured since the day's first manual check, not a billing-day guarantee. Failed sources preserve prior readings as stale. Credentials never belong in config, cache or logs.

OpenRouter uses `/api/v1/key` for cumulative key usage and `/api/v1/credits` for the account's USD balance. It refreshes only on request. A money balance has no percentage denominator.

## GLM, Gemini and Grok

These three stay out of the menu bar until their first successful read, so people who don't use them never see an empty battery. They refresh in the background with Codex and Claude.

| Provider | What it reads | Setup |
| --- | --- | --- |
| GLM Coding Plan | 5h and weekly credit windows from `/api/monitor/usage/quota/limit` | Store your Coding Plan API key in the Keychain (below) |
| Gemini | Daily per-model pools (Pro, Flash, Flash Lite) from the Gemini CLI quota endpoint | Install [Gemini CLI](https://github.com/google-gemini/gemini-cli) and sign in with Google |
| Grok | Monthly spend against the plan limit, via `grok agent stdio` | Install Grok CLI and run `grok login` |

**GLM.** Use `api.z.ai` as the account for Z.ai, or `open.bigmodel.cn` for Zhipu:

```bash
security add-generic-password -s "Usage HUD GLM" -a api.z.ai -w
```

macOS asks for the key without echoing it. Z.ai reports credit windows (`CREDIT_LIMIT`, unit 3 = hours, unit 6 = weeks) and older plans report `TOKENS_LIMIT` for the 5h window; the monthly MCP allowance (`TIME_LIMIT`) is not shown.

**Gemini.** The app reads `~/.gemini/oauth_creds.json` and never renews or rewrites it. Google access tokens are short-lived, so when the token has expired the battery keeps its last reading as cached until you next use `gemini`. API-key and Vertex sign-ins are not supported.

**Grok.** Set `USAGE_HUD_GROK_CLI` to an absolute path if `grok` is not in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` or the app's PATH.

The Gemini quota endpoint, the Z.ai monitor endpoint and Grok's billing RPC are not documented public APIs. Field handling is defensive, and these adapters were written from fixtures rather than live accounts.

## OpenAI API credit estimate

`~/.usage-hud/credits.json` can select a restricted organization Admin key:

```json
{"openai": {"service": "openai-platform", "account": "owner"}}
```

A non-secret USD seed and timestamp come from `codex.json`, or `balance_seed_usd` / `balance_seed_at` in the configuration. Refresh is manual. The app reconciles organization Costs and Completions Usage, taking the larger total against the seed and preserving the existing pinned tariff. Unknown models/tiers fail closed. This is an estimate of API credits, separate from Codex subscription quota. Top-ups require updating the seed; the billing page is authoritative.

## Boundaries

All credential access is read-only. Swift calls macOS's existing `/usr/bin/security` tool for credential reads, and the independent Codex CLI for its official app-server integration. No app-owned interpreter or script runs. Account credentials and caches are not distributed with the repository.
