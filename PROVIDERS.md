# Providers

`UsageProvider` in `Sources/UsageHUDCore/Providers.swift` is the plugin boundary: stable `id`, display `name`, automatic/manual refresh policy, `refresh()` and `panel()`. Register another adapter in `Engine`. Provider failures are isolated. UI consumes normalized `Panel`/`Window` models and contains no provider-auth or HTTP logic.

Quota adapters persist `used_percentage`, `window_minutes` where applicable, `resets_at` and a capture timestamp per window. Missing windows retain their previous reading as stale. The battery displays remaining percentage; no reset is interpreted as a fresh zero.

## OpenRouter

**Nothing to set up:** OpenRouter has no sign-in file, but its keys (`sk-or-v1-` and 64 hex characters) are unmistakable. When `providers.json` is absent, the app looks for them in `OPENROUTER_API_KEY`, your shell profiles (`.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`, `.env`, fish `config.fish`) common AI tool configs (opencode, aider, crush, Continue, Zed) and `.sh` scripts within three levels of your home folder (at most 500; hidden folders, `Library`, and the Desktop, Documents and Downloads folders macOS guards with a permission prompt are skipped). A key assigned to a named variable takes its name from it (`ALICE_OPENROUTER_KEY` shows as "alice"); otherwise it is named after its file (`boot-alice.sh` shows as "boot-alice"). Keys are sent only to openrouter.ai and are never written to disk. To choose keys yourself, create `providers.json` as below; it replaces the search.

**Team or many keys:** create a management key at openrouter.ai (Settings › Management keys) and add it once:

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

## GLM, Gemini and Grok

These three stay out of the menu bar until their first successful read, so people who don't use them never see an empty battery. They refresh in the background with Codex and Claude.

| Provider | What it reads | Setup |
| --- | --- | --- |
| GLM Coding Plan | 5h and weekly credit windows from `/api/monitor/usage/quota/limit` | Nothing, if Claude Code already points at Z.ai or Zhipu; otherwise store the key in the Keychain (below) |
| Gemini | Daily per-model pools (Pro, Flash, Flash Lite) from the Gemini CLI quota endpoint | Install [Gemini CLI](https://github.com/google-gemini/gemini-cli) and sign in with Google |
| Grok | Monthly spend against the plan limit, via `grok agent stdio` | Install Grok CLI and run `grok login` |

**GLM.** The HUD reads the key Z.ai's setup puts in `~/.claude/settings.json` (`ANTHROPIC_BASE_URL` on `z.ai` or `bigmodel.cn`, with `ANTHROPIC_AUTH_TOKEN`) and sends it only to that provider's own quota host. To use a different key, store it with `api.z.ai` as the account for Z.ai, or `open.bigmodel.cn` for Zhipu; a stored key wins:

```bash
security add-generic-password -s "Usage HUD GLM" -a api.z.ai -w
```

macOS asks for the key without echoing it. Z.ai reports credit windows (`CREDIT_LIMIT`, unit 3 = hours, unit 6 = weeks) and older plans report `TOKENS_LIMIT` for the 5h window; the monthly MCP allowance (`TIME_LIMIT`) is not shown.

**Gemini.** The app reads `~/.gemini/oauth_creds.json` and never renews or rewrites it. Google access tokens are short-lived, so when the token has expired the battery keeps its last reading as cached until you next use `gemini`. API-key and Vertex sign-ins are not supported.

**Grok.** Set `USAGE_HUD_GROK_CLI` to an absolute path if `grok` is not in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, an nvm Node version or the app's PATH. Codex is found the same way.

The Gemini quota endpoint, the Z.ai monitor endpoint and Grok's billing RPC are not documented public APIs. Field handling is defensive, and these adapters were written from fixtures rather than live accounts.

## Vercel AI Gateway, DeepSeek and Kimi balances

Like OpenRouter, these show **money left** rather than a percentage. Each stays hidden until its first successful read and then refreshes in the background. All three use the provider's documented balance endpoint.

| Battery | Endpoint | Keychain account |
| --- | --- | --- |
| Vercel | `GET https://ai-gateway.vercel.sh/v1/credits` (USD) | `ai-gateway.vercel.sh` |
| DeepSeek | `GET https://api.deepseek.com/user/balance` (USD, or CNY shown as ¥) | `api.deepseek.com` |
| Kimi (Moonshot) | `GET https://api.moonshot.ai/v1/users/me/balance` (USD) or `api.moonshot.cn` (CNY) | `api.moonshot.ai` or `api.moonshot.cn` |

Store the API key once; macOS asks for it without echoing:

```bash
security add-generic-password -s "Usage HUD Vercel" -a ai-gateway.vercel.sh -w
security add-generic-password -s "Usage HUD DeepSeek" -a api.deepseek.com -w
security add-generic-password -s "Usage HUD Kimi" -a api.moonshot.ai -w
```

## OpenAI API credit estimate

`~/.usage-hud/credits.json` can select a restricted organization Admin key:

```json
{"openai": {"service": "openai-platform", "account": "owner"}}
```

A non-secret USD seed and timestamp come from `codex.json`, or `balance_seed_usd` / `balance_seed_at` in the configuration. Refresh is manual. The app reconciles organization Costs and Completions Usage, taking the larger total against the seed and preserving the existing pinned tariff. Unknown models/tiers fail closed. This is an estimate of API credits, separate from Codex subscription quota. Top-ups require updating the seed; the billing page is authoritative.

## Boundaries

All credential access is read-only. Swift calls macOS's existing `/usr/bin/security` tool for credential reads, and the independent Codex CLI for its official app-server integration. No app-owned interpreter or script runs. Account credentials and caches are not distributed with the repository.
