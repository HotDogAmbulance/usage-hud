# Providers

`UsageProvider` in `Sources/UsageHUDCore/Providers.swift` is the plugin boundary: stable `id`, display `name`, automatic/manual refresh policy, `refresh()` and `panel()`. Register another adapter in `Engine`. Provider failures are isolated. UI consumes normalized `Panel`/`Window` models and contains no provider-auth or HTTP logic.

Quota adapters persist `used_percentage`, `window_minutes` where applicable, `resets_at` and a capture timestamp per window. Missing windows retain their previous reading as stale. The battery displays remaining percentage; no reset is interpreted as a fresh zero.

## OpenRouter

**Nothing to set up:** OpenRouter has no sign-in file, but its keys (`sk-or-v1-` and 64 hex characters) are unmistakable. The app looks for them in `OPENROUTER_API_KEY`, your shell profiles (`.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`, `.env`, fish `config.fish`) common AI tool configs (opencode, aider, crush, Continue, Zed). Scripts elsewhere are not searched: drop a script or folder onto the battery (**Add source…**) and it is read, and its keys are named after the file (`ox3.sh` shows as "Ox3"). A key in a profile takes its name from its variable (`ALICE_OPENROUTER_KEY` shows as "alice"). A dropped boot that runs OpenCode Zen's free models and holds no key shows as "Free · Zen"; Zen publishes no usage, so it can't be measured. Keys are sent only to openrouter.ai and are never written to disk. `providers.json` (below) is read as well, and a key that appears in both shows once.

**Team or many keys:** create a management key at openrouter.ai (Settings › Management keys). Keep it where your other keys live, for example `export OPENROUTER_MANAGEMENT_KEY=sk-or-v1-…` in `~/.zshrc` or a script; the HUD recognises it (by OpenRouter's flag, its variable name, or because it can list keys but not read one) and shows the team instead of a row for it. Or add it to the Keychain once:

```bash
security add-generic-password -U -s "Usage HUD OpenRouter Team" -a openrouter.ai -w
```

Every enabled key on the account then appears in the hover panel, closest to its cap first, under a summary such as "23 keys · $41.20 today · 3 near cap". Teammates reaching their caps never make the battery pulse; a rejected management key or a low account balance does.

**Your own keys:** Create `~/.usage-hud/providers.json` with your own Keychain selectors:

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

Ordered sources provide fallbacks. Keep slot IDs stable. Failed sources preserve prior readings as stale. Credentials never belong in config, cache or logs. A key within 10% of its cap makes the battery pulse.

OpenRouter reads `/api/v1/key` (today's spend, cap, remaining and reset period), `/api/v1/keys` with a management key, and `/api/v1/credits` for the account's USD balance. Days and caps follow OpenRouter's UTC calendar. It refreshes in the background once a key is configured. A money balance has no percentage denominator.

## GLM, Antigravity and Grok

These three stay out of the menu bar until their first successful read, so people who don't use them never see an empty battery. They refresh in the background with Codex and Claude.

| Provider | What it reads | Setup |
| --- | --- | --- |
| GLM Coding Plan | 5h and weekly credit windows from `/api/monitor/usage/quota/limit` | Nothing, if Claude Code already points at Z.ai or Zhipu; otherwise store the key in the Keychain (below) |
| Antigravity | Remaining quota and reset time for each available model | Sign in to the Antigravity macOS app and keep it running |
| Grok | Credit usage this period (weekly on current plans) and the plan name, from `cli-chat-proxy.grok.com/v1/billing` | Install Grok CLI and run `grok login` |

**GLM.** The HUD reads the key Z.ai's setup puts in `~/.claude/settings.json` (`ANTHROPIC_BASE_URL` on `z.ai` or `bigmodel.cn`, with `ANTHROPIC_AUTH_TOKEN`) and sends it only to that provider's own quota host. To use a different key, store it with `api.z.ai` as the account for Z.ai, or `open.bigmodel.cn` for Zhipu; a stored key wins:

```bash
security add-generic-password -s "Usage HUD GLM" -a api.z.ai -w
```

macOS asks for the key without echoing it. Z.ai reports credit windows (`CREDIT_LIMIT`, unit 3 = hours, unit 6 = weeks) and older plans report `TOKENS_LIMIT` for the 5h window; the monthly MCP allowance (`TIME_LIMIT`) is not shown.

**Antigravity.** The HUD reads the running macOS app’s local `GetUserStatus` service. Antigravity owns Google authentication and token renewal; the HUD never reads or changes its Google token, Keychain entry or credential file. It discovers the app’s language-server process and loopback listener on every refresh, keeps the local CSRF token only in memory, forbids redirects and stores only model percentages and reset times. The battery leads with the pool used most recently, falling back to the tightest pool; hover shows grouped quota pools. A missing model quota is not treated as 100% remaining.

This is an internal integration verified with Antigravity 2.19.1, not a public Google quota API. It requires the app to remain running and may need updating when its local protocol changes. If unavailable, the HUD preserves the last reading with its error/stale state. Google credentials are never copied into the HUD. Gemini CLI integration has been removed. Gemini API / AI Studio usage is a separate planned integration and is not enabled by this adapter. Purchased credit balances are not inferred from legacy plan fields.

**Grok.** The HUD reads the sign-in Grok CLI saved in `~/.grok/auth.json` (or `$GROK_HOME`) and sends its token only to the CLI's own billing endpoint. It never renews the sign-in: once it is past its expiry the battery dims and says it updates when you next use Grok CLI, which renews it itself. Grok CLI's `x.ai/billing` RPC answers "method not found" in current versions, so it is no longer used. Field names follow CodexBar's live fixtures; **not yet checked against a real account by us.**

The Z.ai monitor endpoint and Grok’s billing RPC are not documented public APIs; their parsers use fixtures. Antigravity model quota has also been checked against a live local session.

## Vercel AI Gateway, DeepSeek and Kimi balances

Like OpenRouter, these show **money left** rather than a percentage. Each stays hidden until its first successful read and then refreshes in the background. All three use the provider's documented balance endpoint.

| Battery | Endpoint | Keychain account |
| --- | --- | --- |
| Vercel | `GET https://ai-gateway.vercel.sh/v1/credits` (USD) | `ai-gateway.vercel.sh` |
| DeepSeek | `GET https://api.deepseek.com/user/balance` (USD, or CNY shown as ¥) | `api.deepseek.com` |
| Kimi (Moonshot) | `GET https://api.moonshot.ai/v1/users/me/balance` (USD) or `api.moonshot.cn` (CNY) | `api.moonshot.ai` or `api.moonshot.cn` |

Usually there is nothing to set up: the HUD uses the key you already keep in `AI_GATEWAY_API_KEY`, `DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY` or `KIMI_API_KEY` (in the environment, a shell profile, an AI tool's config or a script you dropped), or the one Claude Code uses when it points at DeepSeek's or Moonshot's Anthropic-compatible endpoint. Each key goes only to its own provider's balance host and stays in memory; the search runs at most hourly. A found key that stops working dims the battery instead of pulsing.

To use a different key, store it once (a stored key wins); macOS asks for it without echoing:

```bash
security add-generic-password -s "Usage HUD Vercel" -a ai-gateway.vercel.sh -w
security add-generic-password -s "Usage HUD DeepSeek" -a api.deepseek.com -w
security add-generic-password -s "Usage HUD Kimi" -a api.moonshot.ai -w
```

## Kimi Code, xAI API, Fireworks and LiteLLM

These were built from each provider's documentation and other open-source readers, with test fixtures only: **none has been checked against a real account yet.** Each stays hidden until its first good read, and a key found on the Mac that doesn't work stays quiet.

| Battery | What it shows | Key, found automatically | Keychain account |
| --- | --- | --- | --- |
| Kimi Code (Kimi For Coding) | 5h, weekly and monthly windows, plan name, from `GET https://api.kimi.com/coding/v1/usages` | Claude Code pointed at `api.kimi.com/coding`, kimi-cli's `~/.kimi/config.toml`, `KIMI_CODE_API_KEY`, or a `sk-kimi-` key in `KIMI_API_KEY` | `api.kimi.com` or `api.kimi.ai` |
| xAI | Prepaid balance (`/v1/billing/teams/{team}/prepaid/balance`), or this month's spend against the spending limit for teams billed afterwards | A **management key** (xAI Console › Settings › Management keys) in `XAI_MANAGEMENT_API_KEY` or `XAI_MANAGEMENT_KEY`; the key names its own team. Ordinary API keys can't read billing | `management-api.x.ai` |
| Fireworks | This month's spend against the `monthly-spend-usd` limit (Fireworks has no balance API) | `FIREWORKS_API_KEY`, or the key firectl saved in `~/.fireworks/auth.ini`; the account comes from `FIREWORKS_ACCOUNT_ID`, firectl, or the key itself (`/verifyApiKey`) | `api.fireworks.ai` |
| LiteLLM | The virtual key's spend/budget/reset, plus per-model budgets when `/key/info` reports `model_max_budget_usage` | `LITELLM_PROXY_API_BASE` or `LITELLM_BASE_URL` with `LITELLM_PROXY_API_KEY` or `LITELLM_API_KEY`, or the gateway Claude Code is pointed at | none (the address varies) |

xAI's prepaid ledger posts spend when a billing cycle closes, so mid-cycle it can show more than the Console. LiteLLM’s address and key must be in the same environment or file. Its key goes back only to that address, with redirects rejected; an address that answers like something other than LiteLLM is left alone until the app restarts.

To store a key instead (a stored key wins), for example:

```bash
security add-generic-password -s "Usage HUD xAI" -a management-api.x.ai -w
security add-generic-password -s "Usage HUD Fireworks" -a api.fireworks.ai -w
security add-generic-password -s "Usage HUD Kimi Code" -a api.kimi.com -w
```

## OpenAI API credit estimate

`~/.usage-hud/credits.json` can select a restricted organization Admin key:

```json
{"openai": {"service": "openai-platform", "account": "owner"}}
```

A non-secret USD seed and timestamp come from `codex.json`, or `balance_seed_usd` / `balance_seed_at` in the configuration. Refresh is manual. The app reconciles organization Costs and Completions Usage, taking the larger total against the seed and preserving the existing pinned tariff. Unknown models/tiers fail closed. This is an estimate of API credits, separate from Codex subscription quota. Top-ups require updating the seed; the billing page is authoritative.

## Boundaries

All credential access is read-only. Swift calls macOS's existing `/usr/bin/security` tool for credential reads, and the independent Codex CLI for its official app-server integration. No app-owned interpreter or script runs. Account credentials and caches are not distributed with the repository.

Quota and budget readings are marked cached after ten minutes or on a failed read; money balances use six hours. A passed reset retains the old reading until a fresh response arrives. LiteLLM null budget is unlimited; zero is a zero-dollar cap. Durations/absolute resets follow the proxy; no calendar reset is guessed from a per-model duration alone. See [PRODUCT_TEST.md](PRODUCT_TEST.md) for the native simulation and live-account coverage limits, and [docs/SITUATIONS.md](docs/SITUATIONS.md) for what every reader does when its source fails.
