# Review-iteration post-mortem — 2026-10-05

Scope: provider/cache/display review and the first product simulation/marketing studies. This is not the final product-completion post-mortem.

## What failed or misled

- Reading project documents and parser fixtures was initially too weak to satisfy a request to use the product. Menu-bar-only Computer Use repeatedly timed out; that failure did not establish a visual test.
- The first logo preview used a square application icon and a two-window panel for Claude. This obscured the owner's intended behavior: preserve the existing 5h-to-7d battery transition and add only a model identifier. Aggregator/infra and Antigravity keep their hover tables.
- OpenRouter reset dates derived from viewing time could make old spend appear current in a new period. Failed key reads could discard known spend. Stale/expired state was inconsistently described across custom rows, menus and accessibility.
- Documentation palette/overflow descriptions drifted from the renderer.

## Corrections and evidence

`e52eab6` hardens credential routing, bounded transport and retained failure behavior. `8f7e8ec` unifies cached display, accessibility and provider-specific reset/model-budget behavior; it adds a disposable native product-test mode. Native controls and production menus were actually exercised through Computer Use with simulated data, with limits recorded in `PRODUCT_TEST.md`. The installer and live accounts were not replaced by those fixtures.

The revised previews use real menu-bar templates from installed Claude/OpenAI bundles and the official Kimi Code DMG. Antigravity's template was also found. Missing or unrelated app icons do not become invented provider marks. The long-provider moodboard uses native battery rendering and explicitly labels its simulated readings. Documentation now records temporary identity and release stages.

## Prevention and remaining work

Keep native scenario testing, parser regressions and actual-account comparison as separate evidence. Freshness clears only on a valid new measurement; advertised reset passing alone is insufficient. Do not infer identical billing windows from similar looking batteries. Regenerate previews after palette/layout changes and compare with owner references.

Remaining: owner visual acceptance of the new studies; production implementation/installed UI verification of model-logo hover; live console comparisons for the untested adapters; a complete signed distribution/update cycle; App Store sandbox feasibility; final commercial identity and product-completion post-mortem. No claim of independent external-model review or production release readiness is made.
