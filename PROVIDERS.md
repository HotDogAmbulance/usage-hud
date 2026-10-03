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

## OpenAI API credit estimate

`~/.usage-hud/credits.json` can select a restricted organization Admin key:

```json
{"openai": {"service": "openai-platform", "account": "owner"}}
```

A non-secret USD seed and timestamp come from `codex.json`, or `balance_seed_usd` / `balance_seed_at` in the configuration. Refresh is manual. The app reconciles organization Costs and Completions Usage, taking the larger total against the seed and preserving the existing pinned tariff. Unknown models/tiers fail closed. This is an estimate of API credits, separate from Codex subscription quota. Top-ups require updating the seed; the billing page is authoritative.

## Boundaries

All credential access is read-only. Swift calls macOS's existing `/usr/bin/security` tool for credential reads, and the independent Codex CLI for its official app-server integration. No app-owned interpreter or script runs. Account credentials and caches are not distributed with the repository.
