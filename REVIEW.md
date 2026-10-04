# Usage HUD — round 3 review and local fixes

## Summary
Reviewed the three Desktop handoffs in listed order (review-0, review-1, review-2), then the local Swift sources, scripts, docs and tests at `c4e9de6`.
Implemented bounded fixes on `review/codex-round3`; 81 core checks and the AppKit self-test pass.
Provider live-account correctness, visual acceptance and deferred architecture work remain unverified.

## Findings
Line references point to the resulting working tree. All rows below are fixed locally.

| # | Severity | File:line | What is wrong | Concrete failure (input → wrong result) | Fix |
|---|---|---|---|---|---|
| 1 | major | Sources/UsageHUDCore/Balances.swift:274 | LiteLLM URL and key were discovered independently across sources | URL in `.zshrc` + unrelated key in environment → key sent to that URL | Require a complete URL/key pair in the same environment or file; preserve environment precedence |
| 2 | major | Sources/UsageHUDCore/Transport.swift:166 | General HTTP transport followed redirects; size check ran only after full buffering | Redirect → another request outside original endpoint; oversized/chunked body → memory grows before rejection | Reject all redirects, cap body during receipt and reject declared oversized bodies; tested with synthetic loopback HTTP. This does not assert that Foundation forwarded Authorization on every cross-host redirect |
| 3 | major | Sources/UsageHUDCore/Engine.swift:42 | Prompt pause expired automatically after a day | Deny Keychain prompt → background asks again after 24h | Persist pause until explicit manual refresh; regression ages the status by two days |
| 4 | major | Sources/UsageHUDCore/Core.swift:31 | Finite numbers can still exceed Int range | `balance=1e30`, huge reset count/window duration → trapping integer conversion | Format money/counts without Int; bound countdown and validate durations before conversion; safe Antigravity reset grouping |
| 5 | minor | Sources/UsageHUDCore/Engine.swift:76 | Failed reads marked menu windows stale but left hover cells fresh; stale balance could generate a new low-balance pulse | Outage + cached `$0.25 left` → Balance low pulse | Mark cells stale too; require a fresh balance window before generating balance warnings |
| 6 | minor | Sources/UsageHUD/main.swift:350 | Currency stripping also removed negative sign | `$-26 left` → battery digits `26` | Preserve minus; AppKit regression compares positive/negative rendered icons |
| 7 | minor | Sources/UsageHUDCore/Transport.swift:32 | SignIn indexed words before checking allowlist | `SignIn.start("")` → out-of-range crash | Validate allowlist first; empty/whitespace checks |
| 8 | minor | Sources/UsageHUD/main.swift:620 | Self-test assumed output folder already existed | Fresh USAGE_HUD_HOME → try! crash saving preview | Create private output folder and report creation failure |
| 9 | minor | PAID_PLANS.md; PROVIDERS.md | Current docs contradicted implemented prepaid read and Antigravity pool display | User reads “not included” despite prepaid adapter; expects individual models despite pooling | Update current behavior; add LiteLLM pairing/redirect boundaries |

## Round-0 weak spots

| # | Verdict | Evidence / limit |
|---|---|---|
| 1 | unclear | Readers are still fixture-only. Public xAI docs establish billing endpoints; LiteLLM docs establish budget fields. This review does not independently verify every new reader field/unit against a live account |
| 2 | unclear | Code divides xAI amount fields by 100 and negates prepaid ledger; postpaid missing-ledger fallback already exists. Current retrieved docs did not establish all unit/sign assumptions |
| 3 | unclear | Account underscores already accepted; parser uses whole USD. No sufficient official evidence obtained to certify header and quota units |
| 4 | confirmed, qualified | Dynamic 401/403/404/405 hosts are suppressed for run lifetime; HUDProblem failures back off one hour. Plain HTTP is restricted by isLocalHost. Added pairing and redirect rejection. 429/5xx do not receive the hourly backoff; no claim of full retry-policy coverage |
| 5 | confirmed in code | Grok header is present; expired token prevents request. Provider acceptance remains unverified |
| 6 | confirmed | GLM duplicates key-provider mechanics; refactor is deferred, not a correctness fix |
| 7 | confirmed | Providers independently call KeyFinder.places hourly; redundant walks remain deferred |
| 8 | confirmed | Cache.quota retains missing windows indefinitely as stale; no TTL added |
| 9 | confirmed | Engine refreshes sequentially; HTTP wait bounded at 30s per call, not per full pass |
| 10 | confirmed | Hook settings use read/modify/atomic-write without coordination with Claude Code; advisory lock alone cannot coordinate a writer that ignores it. Deferred |
| 11 | refuted as a bug | Spend rows are intentionally excluded from low-balance alarms. Added fresh-only balance gating |

## Verification

Baseline: 77 native Swift core checks passed at c4e9de6. Final output follows verbatim.

### swift run usagehud-tests
```text
Building for debugging...
[0/4] Write sources
[1/4] Write swift-version--1AB21518FC5DEDBE.txt
[3/6] Emitting module UsageHUDCore
[4/6] Compiling UsageHUDCore Engine.swift
[4/8] Write sources
[6/10] Compiling UsageHUDTests CoreTests.swift
[7/10] Emitting module UsageHUDTests
[7/10] Write Objects.LinkFileList
[8/10] Linking usagehud-tests
[9/10] Applying usagehud-tests
Build of product 'usagehud-tests' complete! (3.12s)
81 native Swift core checks passed
```

### swift build --product usagehud; USAGE_HUD_HOME=/tmp/usagehud-round3-selftest .build/debug/usagehud --self-test
```text
Building for debugging...
[0/3] Write swift-version--1AB21518FC5DEDBE.txt
[1/4] Write Objects.LinkFileList
[2/4] Linking usagehud
[3/4] Applying usagehud
Build of product 'usagehud' complete! (0.69s)
Battery drawing and note-free menus passed; fonts: /tmp/usagehud-round3-selftest/font-preview.png
```

Additional synthetic loopback integration exercised the current HTTP transport implementation (extracted without modification into a temporary harness):
```text
Loopback transport: JSON, redirect rejection, declared and streamed size bounds passed
```
The redirect destination was never contacted. Bodies with Content-Length and without declared length both failed at a 32-byte bound. No real credentials or provider calls were used.
`git diff --check` passed. Debug builds only; no install, launch of normal app, push or merge.

The first isolated self-test failed because its new output directory did not exist (finding 8); after fixing folder creation it passed. The first standalone transport harness hit Swift's type-check timeout in the pre-existing CLI path expression; the transport-only harness compiled and passed. Neither failed attempt is counted as successful verification.

## Source checks and scope

- [xAI billing management](https://docs.x.ai/developers/rest-api-reference/management/billing): supports the invoice-preview endpoint; does not prove every parser assumption.
- [LiteLLM spend tracking](https://docs.litellm.ai/docs/proxy/cost_tracking) and [budgets](https://docs.litellm.ai/docs/proxy/users): support spend/budget fields and nullable budgets. A key-level budget is not an exhaustive description of team/model/multiple-window enforcement.
- Antigravity already rejects redirects and limits relaxed TLS trust to the discovered loopback port. Its completion-handler body limit still occurs after download; no shared transport refactor was attempted here.
- install/uninstall scripts were inspected, not executed. Hook races, symlink/TCC edge cases, full-disk behavior and two live app instances were not experimentally certified.
- No re-addition of Claude free resets or spoofed User-Agent. Owner palette and freer-of-5h/7d policy preserved.
- Review-1 assertions that all public specs match were treated as historical claims, not proof. Review-2 is the baseline; its earlier fixes were not re-applied.

## Out of scope / remaining work

Parallel refresh, shared discovery walks, stale-window eviction, GLM consolidation and hook-write coordination remain deferred. Generic per-currency balance thresholds remain a design choice. Real menu-bar animation, dark-bar palette acceptance, paid Antigravity and live new-provider readings still require owner/account validation. No claim of production acceptance is made.
