# Your plan, your battery

You don’t need a separate Pro build. The same macOS app follows the windows returned by your account. When you change plans, refresh the provider from its menu.

| Account | What the battery shows |
| --- | --- |
| Codex Plus | Remaining 5h quota, with the weekly reading behind it when supplied |
| Codex Pro | Remaining weekly quota; the menu identifies the reported plan |
| Claude Pro or Max | Remaining 5h quota, with the weekly reading behind it when supplied |
| Other plans | The quota windows actually reported by the provider |

As of October 3, 2026, [OpenAI’s pricing documentation](https://learn.chatgpt.com/docs/pricing) says Codex Pro plans have no five-hour limit. [Claude’s paid-plan guidance](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans) still describes five-hour windows for Pro and Max. A higher plan doesn’t mean the same thing across both services.

Usage HUD reads the window duration rather than assuming the first window is always 5h. It also hides any old 5h reading when Codex reports a Pro plan. When there is only a weekly window, the number and fill both describe that week; there is no second fill. The menu and tooltip identify the window you’re looking at.

Missing data stays unknown or explicitly cached. An absent limit is never drawn as a fresh 100% allowance. If the service reports purchased Codex credits, those appear separately in the menu, in **credits**, not dollars. OpenAI API credits remain a different account and a separate estimate.

## Getting started

1. Install the official standalone [Codex CLI](https://developers.openai.com/codex/cli) and [Claude Code](https://code.claude.com/docs/en/setup) for whichever accounts you use.
2. Sign in with `codex login` and `claude auth login` respectively. Use your subscription account rather than an API key when you want subscription quota readings.
3. Install Usage HUD:

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh --launch
```

Building requires macOS 12+ and Xcode Command Line Tools. Codex CLI is found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or the app’s environment PATH. If your CLI lives elsewhere, set its absolute location when installing:

```bash
USAGE_HUD_CODEX_CLI="/your/path/to/codex" ./install.sh --launch
```

The installer saves this path in your local app bundle so later Finder launches can find the CLI too. Run the installer again if you move it.

Your Codex and Claude desktop apps are optional. Quota retrieval uses the independent CLI/sign-in sources. Removing a desktop app won’t break this arrangement as long as those separate tools and credentials remain available. Nothing from the repository contains another user’s account configuration or credentials.

## Claude credits

Claude’s extra usage spending cap and amount spent are different from its prepaid balance. Live prepaid-balance integration is **not included in this update**; the existing credits adapter is unchanged. Don’t interpret a monthly cap as money left. Manage and check the actual balance in [Claude Settings → Usage](https://claude.ai/settings/usage).

## What has been checked

Weekly-only Pro responses, older 5h cache entries, weekly primary windows, and purchased-credit responses have native Swift regression checks. These cases use fixtures; this release has not been verified against a live Codex Pro account. Ordinary Codex/Claude quota refreshes are also checked on the maintainer’s existing accounts.
