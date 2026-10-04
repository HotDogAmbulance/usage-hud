# First visual study — 2026-10-05

Usage HUD and its current identity remain temporary. These are AppKit renderings from `DesignPreview.swift`, not screenshots of live provider accounts or final sales assets. The long row illustrates 13 adapter palettes; it does not promise that every adapter has passed live-account validation. The smaller bar shows the default three-battery layout and overflow. Numerical examples are simulated.

- `provider-moodboard.png`: buyer-facing first moodboard, built from the application's battery renderer and existing detailed hover view.
- `logo-hover-demo.png`: revised model-only hover proposal. The existing battery still switches from 5h to 7d. A small vendor glyph appears underneath it without shifting status items. No extra quota table for Codex/Claude. Aggregator/infra and Antigravity retain their detail tables. Not applied to production yet.
- `tray-logo-samples.png`: actual monochrome template samples, not recolored square app icons. Vendor marks belong to their respective owners; their inclusion in these reference previews does not grant the project's MIT license over them. Raw vendor assets are not bundled or committed.

## Asset audit

Inspected installed bundles and official read-only DMGs on 2026-10-05. No downloaded app was installed, launched, or signed into. A DMG is a container: it does not guarantee a monochrome menu-bar template.

| HUD source | Evidence / suitable menu-bar sample |
| --- | --- |
| Claude | Installed `/Applications/Claude.app`, `Contents/Resources/TrayIconTemplate@2x.png`: the star in the owner's screenshot. |
| Codex / OpenAI | Installed `/Applications/ChatGPT.app` (bundle ID `com.openai.codex`, version 26.930.31730), `Contents/Resources/chatgptTemplate@2x.png`: the OpenAI knot in the screenshot. OpenAI family identifier, not a claim that it is a distinct Codex-specific mark. |
| Antigravity | Installed bundle, `app.asar` contains `trayTemplate.png` and `trayTemplate@2x.png`. Sample available; its hover remains the existing quota table. |
| Kimi Code | Official `KimiCode-mac-arm64.dmg`, app `com.kimi.code.desktop`, version 1.0.4, `Contents/Resources/build/trayTemplate@2x.png`. Suitable template found. [Official installation guide](https://www.kimi.com/code/docs/kimi-code-desktop/getting-started.html). |
| Kimi API | [Official Kimi desktop download](https://www.kimi.com/products/download) exists, but that separate package was not inspected. Do not substitute the Code mark for an API account silently. |
| DeepSeek API | Official DeepSeek Harness DMG, `com.deepseek.dsh`, version 0.2.0-rc.2. Found ordinary app icons and frontend favicons, no separately identifiable tray/template image in the loose resources and ASAR filenames inspected. Not evidence that no glyph can exist in generated code. Harness branding does not prove API wallet behavior. [Official download](https://www.deepseek.com/en/download/). |
| Grok / xAI | Official Grok Bot DMG, `com.anysphere.sand`, version 0.66.0. Ordinary app icon found, no separately identifiable tray/template image in inspected resource filenames. Grok Bot is a different product from the Grok CLI subscription and xAI API balance adapters; do not borrow its icon blindly. [Official downloads](https://x.ai/bot). |
| GLM | No official macOS installer/template identified in the official sources checked. Keep the name fallback until a verified glyph is available. |
| OpenRouter / Vercel / Fireworks / LiteLLM | No provider-owned DMG/template identified in the official sources checked. These HUD entries represent API/gateway/proxy accounts and retain their detail tables. Logo availability is a separate question from API coverage. |

Installer SHA-256 evidence (not a vendor-signature verification):

```
Kimi Code: ba61afaecd1c8b029c5a0d3a967b6fef24a1190fc225f46c89e5ac2a601f7ce1
DeepSeek:  7c32c459c403d8a035ac60600f240ed2025312f0a7afde283f454f30ec4ed96e
Grok Bot:  3da5e4a564b8f4292a6fcbbe651bed3a01630d01f959232b037b9f0acbdf5de6
```

To regenerate, set a disposable `USAGE_HUD_HOME`, run `swift run usagehud --self-test`, and copy the selected PNGs here. Claude/OpenAI samples resolve installed app resources. For the other audit samples, set `USAGE_HUD_LOGO_AUDIT_DIR` to a directory containing `kimi-code-trayTemplate@2x.png` and `trayTemplate@2x.png` extracted from the verified bundles. Missing assets are omitted; no replacement monogram is invented. Preview asset resolution is isolated from quota collection.
