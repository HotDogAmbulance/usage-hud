# Native product test and display changes — 2026-10-05

The installed app was not replaced. Changes are on `review/codex-round3`, after `e52eab6`. The normal 5h/7d warning policy and balance-gauge meaning are retained. Logo-only hover remains a proposal.

## What actually ran

Computer Use still returned `-10005 timeoutReached` for the installed menu-bar-only `local.usage-hud` app. A temporary native bundle, Usage HUD Test, successfully exposed a normal window to Computer Use. This hosts the production `CellsView`, status-item drawing, menus, and overflow submenu. Native menus were anchored to buttons in the test window so the tool could observe them. Test Refresh is intercepted by `FixtureHUD.load`; it supplies fresh readings instead of reading credentials or making network calls. The test mode does not register login items, connect Claude hooks, or write the user's cache/defaults.

I used Computer Use to select providers and click Cached, Partial, Recovered, Cycles, Many keys, 11 models, and Low quota. The returned accessibility trees/screenshots confirmed:

- Cached readings retain their values and dim the small batteries. Recovery removes cached from visible content and accessibility descriptions.
- Partial Antigravity failure marks only the affected pool. The other pool retains its fresh appearance.
- The count preview can display 14 or 11 models. A separate native core test verifies the real Antigravity parser replaces removed models and includes newly returned models.
- OpenRouter can show daily, weekly, monthly, capped without reset, and uncapped usage. An uncapped row has no invented percentage.
- A 12-key preview truncates long labels and reports the remaining entries. The production All keys submenu exposes all 12 full names.
- Production menus and the simulated OpenAI-credit Refresh action work. The recovered menu removes cached. Overflow exposes the hidden providers and their menus, including LiteLLM All budgets.
- Balance rendering supports USD and CNY; quota and money remain distinct. Grok and Kimi Code, and xAI/Fireworks/LiteLLM, were selected interactively. Final fixtures model Grok's weekly quota, account monthly budgets, and LiteLLM key/model budgets rather than assuming they are all 5h plans or multi-key aggregators.
- Accessibility rows contain the provider/window, remaining percentage, currency, reset information, and cached state. Currency is spoken as US dollars or Chinese yuan. No VoiceOver speech session was started.

This is a native interactive test with synthetic signals, not live account validation. Actual pointer hover/popover anchoring on the global menu bar and an installed-app restart remain unverified by Computer Use. The test session was closed afterwards.

## Bugs and display changes

- One shared cached definition covers stale readings and windows whose advertised reset has passed. Hover marks all-old cells once in the summary, or marks individual old rows. Menu, tooltip, full-detail list and accessibility also carry the state; a fresh balance is not labeled cached just because another row is old. A visible hover view updates after refresh.
- OpenRouter previously calculated the next reset relative to the viewing time, allowing yesterday's usage to appear fresh against tomorrow's reset. Reset now derives from the successful reading time. Crossing it retains the last value with cached/waiting for reset, suppresses a new cap alarm, and clears after a valid new reading. Capped key readings age after ten minutes; balances still age after six hours.
- Failed OpenRouter keys preserve known usage rather than replacing it with an unavailable value. Unknown usage still remains unavailable. No duplicate cached suffix is stored in the provider's raw reading text.
- A numeric zero budget is distinct from null/unlimited, with no divide by zero. This applies to OpenRouter and LiteLLM.
- LiteLLM hover now carries the returned absolute key-budget reset and budget duration. Its `/key/info` model usage is displayed when `model_max_budget_usage` supplies both spend and a budget; configured models without reported usage are omitted. A period without an absolute reset does not become an invented countdown. Removing optional model usage clears those detail rows.
- LiteLLM's main battery uses one gradient with #0117BE and #5B3FD1. The two colours are brand colours, not two separate quota windows. Existing warning colours still take priority.
- Overflow replaces +N with two copies of the installed ControlCenter battery artwork. Hidden count and names remain in its tooltip/accessibility/menu. The individual provider status items remain separate. Overflow menu entries use provider names and balances rather than long tooltip instructions.
- Custom hover views expose individual accessibility children with complete untruncated names. Status buttons expose reading values and refresh/help context. The visual top bar gets no extra accessibility text.

## Freshness and autonomous limits

Cached clears when that reading receives fresh valid data for its current window. Merely opening the menu, changing the clock, or clearing an error does not create a new measurement. Sources need different age limits: quota/budget percentages and the OpenAI API estimate use ten minutes; general money balances use six hours. Failed refresh marks retained values immediately. A passed reset still needs a new source reading.

The actual local OpenAI API cache had no recorded error and was about 34 hours old. It is a manual-refresh estimate, so the screenshot is expected under the current design; it does not prove a stuck request. Use the installed Codex menu's **Refresh OpenAI API credits** before spending more money. This code derives a balance estimate from a seed and organization accounting; its retained usage tariff only accepts `gpt-6-astra` and supported tiers. It is not a universal live wallet-balance reader. Unsupported priced usage fails closed rather than silently subtracting a guessed price.

Antigravity counts distinct model labels that contain valid quota data in its local response. It is not an announced catalogue count. After a successful response with three fewer valid models, 14 becomes 11; an unavailable/stale local session keeps the old count with cached state. No external model-removal announcement was independently verified here.

OpenRouter's reported reset type supports daily/weekly/monthly/null. Its UTC calendar rule belongs to that adapter. LiteLLM arbitrary durations use returned timestamps rather than borrowing OpenRouter's rule. Other providers must supply their own normalized cap/window/reset. Autonomous discovery cannot grant a missing management permission or manufacture an API field.

Known coverage limits:

| Source | Current HUD reading | What this test does not prove |
| --- | --- | --- |
| Grok CLI | Plan credit quota/window from the CLI billing endpoint | Own live-account compatibility; schema originated from upstream fixtures |
| xAI API | Prepaid ledger / monthly postpaid budget using a management key | Mid-cycle prepaid ledger equals spend visible in the Console |
| Vercel AI Gateway | Team credit balance | Newer key-budget management APIs are not covered by the current adapter |
| DeepSeek / Kimi API | Available currency balance | Every regional/account variant or its live authentication |
| Kimi Code | Coding-plan quota windows | Every subscription variant behaves like fixture examples |
| Fireworks | Monthly spend / spend limit | A live prepaid-wallet balance; this reader is a spend-quota reader |
| LiteLLM proxy | Own key budget + optionally reported model budgets | Every proxy version, Enterprise capability, team budget, or concurrent budget-window schema |

No new subscriptions, API keys or paid model requests are required to test presentation. Parser fixtures and interactive native tests verify those layers; live read-only reads on existing authorized accounts are the next layer, followed by comparison with each provider's console. This work does not claim those missing live checks passed.

## Verification and previews

`swift build`, 86 native core checks, native AppKit self-test, and `git diff --check` pass. Regression checks include model-list changes, cache expiry/recovery, partial cache display, currency/accessibility wording, retained failed key usage, crossing a reset, zero versus null caps, and LiteLLM model-budget usage/removal. A native self-test ensures all-old menus say cached only once.

`--product-test` is a development mode; it opens the disposable native controls. `--self-test` exports `native-stack-litellm.png` and `logo-hover-demo.png` alongside the battery/font previews. These images are AppKit render previews, not Computer Use screenshots. The revised logo sample uses actual installed Claude/OpenAI menu-bar templates, preserving the existing 5h-to-7d hover. It adds only a small identifier below that battery; aggregator/infra and Antigravity retain their detailed hover tables. This is a visual proposal, not an implemented hover change. The previous comparison using a square application icon was superseded. `provider-moodboard.png` and `tray-logo-samples.png` are also exported; see `docs/marketing/README.md` for asset provenance.

References for API capability context: [OpenRouter current key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key), [LiteLLM budgets](https://docs.litellm.ai/docs/proxy/users), [Vercel key budgets](https://vercel.com/docs/ai-gateway/observability-and-spend/budgets), [Vercel credits](https://vercel.com/docs/ai-gateway/pricing). No prices from these pages are embedded as new HUD tariffs.

## Overflow quota cells — 2026-10-05

The same `CellsView` now renders provider detail at the top of its native menu, including the submenu reached through overflow. Providers with key/pool/budget data no longer fall back to disabled textual rows in overflow. A fresh menu is constructed for each placement: AppKit copies attached menu views using NSCoding, which is unsuitable for this programmatic view. Refresh/sign-in/update actions and complete-name lists remain ordinary native menu items. Overflow's existing hover-to-open behavior and model 5h-to-7d switching remain unchanged.

Healthy detail-cell fill uses the native label color (white in dark appearance, dark in light appearance) throughout hover, menu and fixture views. Yellow/red warning thresholds, cached dimming and menu-bar provider palettes are retained. More-row instructions refer to All keys/All budgets below when already inside a menu. Sources that return only a currency balance receive no invented quota rows.

Computer Use opened the real overflow menu in a disposable native test bundle, selected OpenRouter, and visually confirmed its two white quota batteries, monetary amounts and resets. The accessibility tree also exposed LiteLLM key/model budgets, 12-key complete-name lists and the contextual overflow footer. Cached fixtures kept their marks; activating Refresh through the native submenu produced Recovered. These signals are synthetic, with no credential reads or API calls. The normal-window menus were exercised; actual pointer hover on the installed global menu bar was not tested. The test window was closed afterwards.

Debug/release builds, the 86 native core checks, AppKit self-test and diff checks pass. Additional AppKit regression checks verify distinct visible/overflow views, retained Refresh actions, complete key lists and the contextual footer. `quota-cells-preview.png` is an AppKit render preview, not a captured live-account screenshot. Test bundles use the production bundle-info writer plus a separate test identifier and the `UsageHUDProductTest` flag; a minimal handwritten bundle metadata file was rejected by Computer Use.
