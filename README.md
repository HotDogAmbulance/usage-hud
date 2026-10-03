# Usage HUD

A little room for your AI usage, right in the Mac menu bar.

I wanted to see how much Codex and Claude I had left without opening another window. Usage HUD puts that information inside a few small batteries, borrowing the familiar shape of the Mac’s own battery icon. OpenRouter sits beside them with its dollar balance.

Built for macOS, entirely in Swift. Small enough to stay out of the way.

## Reading the batteries

Using Codex Pro or Claude Pro/Max? [Here’s how your plan is displayed and how to set it up](PAID_PLANS.md). The same app adapts to your account’s reported windows.

Each provider has its own color: teal for Codex, terracotta for Claude, poison green for OpenRouter, white for GLM (Z.ai's mark), Google's four colours for Gemini, silver for Grok, warm grey for Vercel, DeepSeek's whale blue and Kimi's azure.

For Codex and Claude, the number is the **percentage remaining** in your 5-hour window. The stronger color follows that reading. Behind it, a lighter shade shows what remains for the week. Grey is the unused part of the battery. The digits are cut out of the fill, so your menu-bar background shows through, just like the reference Mac battery. When the week has less left than the 5-hour window, the 5-hour fill covers it: hover over a battery to see the weekly reading on its own, in that same lighter shade. It returns to the 5-hour view when the pointer moves away.

If the 5-hour reading is unavailable or its window has reset, the battery falls back to the latest 7-day reading. Older readings look dimmer, and the menu tells you when you’re seeing cached information. Click any battery to see the individual windows, reset times, and refresh controls.

OpenRouter shows **dollars left**. Its pale green body gives the balance a readable home; the fill doesn’t represent a percentage. Whole amounts keep the standard battery size; cents stretch the body to fit. Any OpenAI API credit estimate lives separately in the Codex menu.

## Make it at home on your Mac

You’ll need macOS 12 or later and Xcode Command Line Tools to build the app. For subscription usage, sign in through the standalone Codex CLI (`~/.local/bin/codex`) and Claude Code. You can use Usage HUD without the Codex or Claude desktop apps; their CLI tools and sign-ins still need to be available.

```bash
git clone https://github.com/HotDogAmbulance/usage-hud.git
cd usage-hud
./install.sh --launch
```

That installs the app in `~/Applications`. If you prefer keeping it on your Desktop:

```bash
./install.sh --dest "$HOME/Desktop" --launch
```

The installed app carries its own executable, so you can remove the source checkout afterwards. Your settings and cached readings stay in the private `~/.usage-hud` folder. Set `USAGE_HUD_HOME` if you’d like to keep them somewhere else.

If you’re coming from the older Python version, the installer keeps your existing configuration and readings. It also moves Usage HUD’s own Claude hook and statusline commands to the Swift executable, with a local backup of the settings file. Other Claude commands stay as they were.

## A few things to know

Codex and Claude refresh in the background every five minutes. OpenRouter balances and OpenAI API credit estimates refresh when you ask for them from the menu. The display checks its local cache every 30 seconds, including readings supplied by Claude’s statusline.

Credentials stay in your existing macOS Keychain. Usage HUD reads them when needed and keeps tokens in memory for the corresponding requests. It doesn’t change your Keychain entries, renew your Claude sign-in, or send app telemetry. If Claude’s authentication expires, sign in again through Claude Code.

The Claude usage endpoint can change, and an API credit estimate may differ from your final bill. The estimate supports a pinned set of tariffs and stops when it encounters an unsupported model or service tier. Your provider’s billing page is the place to check the final amount.

## If you’d like to work on it

The app has no third-party packages or interpreter to install. The code is split into a small AppKit interface and a shared Swift core, with a provider protocol so another service can have its own adapter.

| Where | What lives there |
| --- | --- |
| `Sources/UsageHUD` | Battery drawing, menus, and app lifecycle |
| `Sources/UsageHUDCore` | Models, cache, provider protocol, networking, and CLI |
| `Providers.swift` | Codex, Claude, and OpenRouter adapters |
| `CodingPlans.swift` | Optional GLM, Gemini and Grok adapters, shown once signed in |
| `Balances.swift` | Optional Vercel AI Gateway, DeepSeek and Kimi money balances |
| `OpenAICredits.swift` | Separate API credit accounting |
| `Tests` | Native Swift checks |

Only one refresh runs at a time. Missing windows retain their previous readings and timestamps, and shared cache writes use a lock so the app and Claude hooks can work together. Codex reads quota through `account/rateLimits/read` in its standalone app-server, without starting an inference session. Claude reads its usage endpoint with the existing Claude Code OAuth token.

[PROVIDERS.md](PROVIDERS.md) explains provider configuration and how to add an adapter.

These commands are handy for checking readings or working on the app:

```bash
~/.usage-hud/usagehud --json
~/.usage-hud/usagehud --refresh automatic
~/.usage-hud/usagehud --refresh openrouter
~/.usage-hud/usagehud --refresh openai-credits
swift run usagehud-tests
swift run usagehud --self-test
swift build --configuration release --product usagehud
```

The `--claude-statusline` command also keeps the context cache used by existing Claude burn guards. `--probe-if-stale` lets the Claude hook refresh a reading when it’s getting old.

## When you want to remove it

```bash
./uninstall.sh
```

To remove the cached readings and provider configuration as well:

```bash
./uninstall.sh --purge
```

If you added Usage HUD hooks to Claude Code, remove those entries from Claude’s settings too. Your provider credentials stay in the Keychain.

Usage HUD is available under the [MIT license](LICENSE). Make it your own.
