# Usage HUD

**macOS only. Pure Swift.** A compact native menu-bar app for Codex, Claude and OpenRouter usage. No Python, Tkinter, JavaScript runtime, web view or third-party packages.

One battery per provider: teal Codex, terracotta Claude, violet OpenRouter. Inside the same battery body, solid brand color shows remaining 5-hour quota, lighter color behind it shows remaining 7-day quota, and neutral grey fills the empty space. There are no separate bars or floating notes.

If 5-hour data is missing or has reset, the most recent weekly reading replaces it. Cached weekly data is dimmed and identified in the menu. Click for all windows, reset countdowns and refresh. OpenRouter is a dollar balance, not a quota percentage: its number is violet on a neutral grey battery. OpenAI API credits remain a separate manual estimate in the Codex menu.

## Install

Requires macOS 12+ and Xcode Command Line Tools to build. Sign in through standalone Codex CLI (`~/.local/bin/codex`) and Claude Code. Their desktop apps are not required. CLI availability and authenticated credentials are still required for retrieving subscription quotas.

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh --launch
```

The app contains its complete executable; `~/.usage-hud` holds private cache and provider settings. There are no installed runtime source files. A `usagehud` symlink provides a stable CLI path. You can delete the checkout after installing.

```bash
./install.sh --dest "$HOME/Desktop" --launch
```

Optional `USAGE_HUD_HOME` selects a different cache directory. Existing quota caches, credit seeds and Keychain selectors are read without a reset. Installation migrates only this HUD's retired Python hook/statusline commands in Claude Code settings, preserving unrelated commands and making a private local backup. Runtime credentials are never copied or changed.

## Code

- `Sources/UsageHUD`: AppKit batteries, menus and lifecycle.
- `Sources/UsageHUDCore`: shared models, private atomic cache, provider protocol, CLI, native networking and bounded subprocess transport.
- `Providers.swift`: Codex, Claude and OpenRouter adapters.
- `OpenAICredits.swift`: retained Decimal accounting, isolated from subscription quotas.
- `Tests`: native Swift checks without third-party test frameworks or a full Xcode dependency.

One background refresh at a time. Subscription usage refreshes every five minutes; cached displays redraw every 30 seconds. There is no Python collector subprocess, file-system session scan or activity watcher. The provider registry isolates failures, and partial responses preserve missing windows with their original timestamps. Cache writes share a file lock so statusline and refresh writes do not lose each other's fields.

Codex uses the documented `account/rateLimits/read` method through its standalone app-server, without creating a thread or running inference. Claude uses GET `/api/oauth/usage` with Claude Code's existing OAuth token; this provider-specific endpoint can change. Tokens are read through macOS's existing Keychain tool, kept only in memory and sent only in the corresponding provider request. The app does not refresh OAuth tokens or write Keychain credentials. Expired Claude authentication requires Claude Code sign-in.

OpenRouter and OpenAI Admin-key requests stay manual. Supported credit tariffs are pinned; unknown models or service tiers fail closed. Credit estimates use the greater of settled costs and metered token spend rather than adding both. The billing page remains authoritative. No app telemetry is sent.

See [PROVIDERS.md](PROVIDERS.md) for configuration and the plugin contract.

## CLI and checks

```bash
~/.usage-hud/usagehud --json
~/.usage-hud/usagehud --refresh automatic
~/.usage-hud/usagehud --refresh openrouter
~/.usage-hud/usagehud --refresh openai-credits
swift run usagehud-tests
swift run usagehud --self-test
swift build --configuration release --product usagehud
```

`--claude-statusline` preserves the context cache used by existing Claude burn guards. `--probe-if-stale` preserves the existing hook behavior, now in Swift.

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --purge
```

Remove the app's Claude Code hooks if no longer needed. Purging deletes HUD cache/config, not provider credentials. MIT license: [LICENSE](LICENSE).
