# Usage HUD

**macOS only.** Compact native menu-bar batteries for Codex, Claude and OpenRouter.

The native Swift/AppKit interface draws one battery per provider. A solid brand fill shows remaining 5-hour quota, a lighter fill behind it shows remaining 7-day quota, and neutral grey fills the empty space. The two fills occupy the same battery body. No separate bars or floating note window.

Codex is teal, Claude terracotta and OpenRouter violet. The number is remaining quota in the displayed window. If 5-hour data is unavailable or has reset, the most recent weekly reading replaces it. Cached weekly data is dimmed and identified in the menu. Click for every quota window, reset countdowns and manual refresh.

OpenRouter shows a USD balance rather than a fabricated quota percentage. Its body is neutral grey and its number is violet. OpenAI API credits are a separate cached estimate in the Codex menu, with a manual refresh action.

## Architecture

This is **Swift UI + Python data adapters**, not a pure Swift app. Python uses the standard library only; there is no Tkinter dependency.

- `MenuBar.swift`: drawing, native menus, application lifecycle and single-instance lock.
- `collector.py`: refresh dispatch and failure isolation.
- `plugins/`: Codex, Claude and OpenRouter adapters.
- `usage_hud.py`: cache normalization, read-only credential access, existing credit accounting and Claude Code hook compatibility.

Codex reads the documented `account/rateLimits/read` method through standalone `~/.local/bin/codex app-server`. No agent thread or inference is created. Claude reads Claude Code's existing Keychain OAuth credential and queries the provider-specific `/api/oauth/usage` endpoint with GET. The HUD never refreshes OAuth tokens or writes credentials. Expired Claude credentials require signing in through Claude Code. This endpoint can change independently of the app.

Subscription quota refresh runs every five minutes. OpenRouter and OpenAI Admin-key credit refreshes stay manual. Errors remain isolated, and partial quota responses preserve previous missing windows as cached readings. No telemetry is sent by Usage HUD; provider requests necessarily transmit their authentication credentials to the corresponding provider.

Deleting Codex or Claude desktop app bundles does not affect these independent CLI paths. Removing the CLI installations, deleting login data or revoking credentials does affect them.

## Install

Requires macOS 12+, Xcode Command Line Tools (Swift compiler) and Python 3.9+. The default Python path is `/usr/bin/python3`. Sign in with standalone Codex CLI and Claude Code first.

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh
```

Installs the native **Usage HUD.app** in `~/Applications` and the adapters in `~/.usage-hud`. Existing caches, provider configuration and Claude Code settings are preserved. The executable is bundled inside the app so Finder can launch and reopen it normally. Reopening a running app shows its menu.

```bash
./install.sh --dest "$HOME/Desktop" --launch
./install.sh --python /absolute/path/to/python3
```

Optional `USAGE_HUD_HOME` selects another data directory at installation time. OpenRouter requires your own Keychain selector configuration; see [PROVIDERS.md](PROVIDERS.md). No personal credentials or cache files are distributed.

## Command line and checks

```bash
python3 usage_hud.py --json
python3 usage_hud.py --probe-claude
python3 usage_hud.py --probe-openrouter
python3 usage_hud.py --probe-openai-credits
python3 collector.py --refresh automatic
python3 test_usage_hud.py
python3 test_plugins.py
xcrun swiftc MenuBar.swift -o /tmp/usage-hud-check
/tmp/usage-hud-check --self-test
```

Existing `--claude-statusline` and `--probe-if-stale` integrations remain compatible. Installation does not replace another statusline or change Claude settings.

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --purge
```

Purge removes the installed adapters and cache, not provider credentials. Remove any Usage HUD commands from Claude Code settings before purging to avoid dangling hooks. MIT license; see [LICENSE](LICENSE).
