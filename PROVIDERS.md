# Usage HUD provider slots

`providers.json` defines stable logical people (`guy1`, `guy2`) separately
from the API/credential plumbing used to measure them.

Each slot has an ordered `sources` array. The first source that probes
successfully wins. To add a fallback, append it. To replace a provider, put the
new source first or remove the old source. Keep the slot `id` unchanged so UI
and cache identity remain stable.

Current source shape:

```json
{
  "provider": "openrouter",
  "service": "com.example.openrouter",
  "account": "primary"
}
```

`service` and `account` are Keychain selectors, never secrets.

## Subscription and API credits

Codex/Claude usage is handled by plugins/codex.py and plugins/claude.py; normalized caches contain no credentials. Subscription quota refresh is automatic every five minutes. The code never refreshes Claude credentials or writes Keychain items.

Codex's menu retains manual OpenAI API-credit refresh, separate from the ChatGPT subscription quota. Existing accounting, manual seed and restricted Admin-key configuration remain unchanged. OpenRouter refresh stays manual. Provider failures preserve stale data and do not terminate other providers.

## Adding another provider

1. Add a probe function to `usage_hud.py` that accepts one source dictionary.
2. Retrieve its credential from Keychain inside that function. Never accept a
   key in `providers.json`, argv, logs, or cache state.
3. Return normalized cumulative values:

   ```python
   {"usage": 12.5, "limit": 50.0, "credits_remaining": 37.5}
   ```

   Only `usage` is required. Never return credentials or response bodies.
4. Register the function in `PROVIDERS` under the source's `provider`
   name.
5. Add the source to a slot and run `test_usage_hud.py`.

The cache records a non-secret `source_id`. When the winning API pipe changes,
the daily baseline resets instead of subtracting values reported under two
different provider semantics. A failed fallback chain persists an explicit
stale/error row; prior successful values are never presented as a fresh check.
