# Recorded answers

One file per answer a real account gave. `testRecordedAnswersStillParse` feeds each back through the real reader.

```json
{
  "provider": "deepseek",
  "synthetic": false,
  "answers": { "/user/balance": { "status": 200, "body": { "...": "as recorded" } } },
  "expect": { "windows": [{ "label": "DeepSeek", "right": "$7 left" }], "alert": null }
}
```

- `provider` is a reader's id (see `worlds()` in `SituationTests.swift`): claude, openrouter, glm, vercel, deepseek, kimi, kimi-code, xai, fireworks, litellm, grok.
- `answers` maps a URL path (or its ending) to what the server said: `status` (200 when left out) and the `body`, byte for byte except for what you redact.
- `expect` is what the provider's **own dashboard** showed at that moment, written by hand, never copied from what the reader printed. `windows` lists the first rows (`label`, `pct`, `right`); `alert` and `note` are optional; `"hidden": true` means the battery must stay out of the bar (a key that was refused on a first run, for instance).
- Take four recordings per account when you can: healthy, close to empty or at its limit, a key refused (change one character), and a brand-new account that has never been used. Redact emails, account and team ids, and anything that looks like a key before the file goes into the repository.
- `synthetic: true` marks a file written by hand to prove the folder works; replace it when a real one exists.
