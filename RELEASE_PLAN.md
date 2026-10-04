# Product completion and release plan

Owner direction recorded 2026-10-05. This is a roadmap, not a declaration that the product is finished or an authorization to publish storefront listings/community posts now.

## Working identity and open source

The public GitHub repository stays Usage HUD/uhud with the current temporary logo. The source is MIT licensed. Contributors should be able to extend adapters and send upstream changes. Provider-specific discovery, requests, timestamps, caps and resets belong behind the normalized collector/cache boundary; UI reads normalized panels without provider credentials. Keep optional fields absent when the API cannot supply them.

## Build → review → test → land

For each candidate, record its commit, changes and source review, debug/release builds, native checks, and applicable product-test evidence. Use isolated synthetic signals for unavailable accounts, then track actual account/console comparison separately. Check cache failure/recovery, window changes, currency, long names/overflow, menu-bar layout, accessibility and normal install/update/uninstall behavior.

The current iteration has bounded native interactive simulation evidence in `PRODUCT_TEST.md`; live coverage remains explicitly incomplete. Model-only logo hover is still a visual study. Completion needs owner visual acceptance and real installed-app validation, including menu-bar anchoring, light/dark appearance and a crowded/notched bar. A green parser test or merged PR cannot replace those checks.

After landing a complete candidate, write its final product post-mortem: expected vs observed behavior, defects and causes, what escaped review, fixes/evidence, unresolved limitations, release/rollback instructions and support ownership. `POSTMORTEM_2026-10-05.md` records this review iteration only.

## Final identity and distribution

After product completion and the final post-mortem, choose the commercial name/logo and update bundle identity, artwork, documentation and release assets together. First establish signed/notarized distribution and a working update/rollback path. Evaluate App Store, Gumroad and Lemon Squeezy against the actual package/support model; decide pricing later. Add Ko-fi or GitHub Sponsors once the support destination and ownership are chosen.

App Store is a separate feasibility checkpoint: Apple requires App Sandbox for Mac App Store distribution. The current local CLI/session discovery and Claude-hook integration need a sandbox feasibility review; the existing installer is not evidence of App Store readiness. [Apple App Sandbox documentation](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

## Debut

Prepare final real screenshots, a short demo, supported-source coverage, privacy/authentication explanation, install instructions and known limitations. The first moodboard under `docs/marketing/` helps explain the product while identity is still temporary. Replace simulated marketing examples with approved release captures where appropriate.

Owner candidates: r/macapps, r/ClaudeAI and Show HN; start with organic distribution and zero advertising spend. Verify each community's current posting rules at launch time. Record feedback, installation failures, conversion/support effort and follow-up fixes before considering a small advertising budget. No listings or launch posts have been published by this iteration.
