#!/usr/bin/env python3
"""Fails when a tracked file holds characters that can make code read differently from how it runs.

- Anywhere: invisible format characters (zero-width spaces and joiners, bidirectional controls as in "Trojan Source",
  CVE-2021-42574), unusual spaces and line separators. A presentation selector (U+FE0E/U+FE0F) is allowed right after a
  symbol, as in the warning sign shown in menus.
- Anywhere: letters from scripts other than Latin (a Cyrillic or Greek letter can pass for a Latin one). Latin letters
  with accents, such as the Vietnamese captions in DesignPreview.swift, are fine.
- In code (Swift, shell, YAML, Python): letters outside ASCII only inside a string literal or a comment, so an identifier
  can never hide a look-alike letter.

Run `python3 scripts/check_characters.py` from the repository root; `--self-test` checks the checker.
"""
import subprocess
import sys
import unicodedata

CODE = (".swift", ".sh", ".yml", ".yaml", ".py")
SKIP = (".png", ".icns", ".jpg", ".jpeg", ".gif", ".pdf")
SELECTORS = {"\ufe0e", "\ufe0f"}


def invisible(ch, before):
    category = unicodedata.category(ch)
    if ch in SELECTORS:
        return before is None or unicodedata.category(before) != "So"
    if category == "Cf":
        return True
    if category in ("Zl", "Zp"):
        return True
    return category == "Zs" and ch != " "


def letters_outside_literals(text, hash_comments):
    """Positions (line, column, char) of non-ASCII letters that sit in code rather than a string or comment (Swift-like)."""
    found, line, column, i = [], 1, 0, 0
    state = "code"  # code, line-comment, block-comment, string, block-string
    while i < len(text):
        ch = text[i]
        ahead = text[i:i + 3]
        if state == "code":
            if ahead == '"""':
                state, i, column = "block-string", i + 3, column + 3
                continue
            if text[i:i + 2] == "//" or hash_comments and ch == "#" and text[i - 1:i] in ("", "\n", " ", "\t"):
                state = "line-comment"
            elif text[i:i + 2] == "/*":
                state = "block-comment"
            elif ch == '"':
                state = "string"
            elif ord(ch) > 127 and ch.isalpha():
                found.append((line, column + 1, ch))
        elif state == "line-comment" and ch == "\n":
            state = "code"
        elif state == "block-comment" and text[i:i + 2] == "*/":
            state, i, column = "code", i + 2, column + 2
            continue
        elif state == "string":
            if ch == "\\":
                i, column = i + 2, column + 2
                continue
            if ch in ('"', "\n"):
                state = "code"
        elif state == "block-string":
            if ch == "\\":
                i, column = i + 2, column + 2
                continue
            if ahead == '"""':
                state, i, column = "code", i + 3, column + 3
                continue
        if ch == "\n":
            line, column = line + 1, 0
        else:
            column += 1
        i += 1
    return found


def problems(path, text):
    found, line, column, before = [], 1, 0, None
    for ch in text:
        column += 1
        if invisible(ch, before):
            found.append(f"{path}:{line}:{column}: invisible or unusual character U+{ord(ch):04X} "
                         f"{unicodedata.name(ch, '?')}")
        elif ord(ch) > 127 and ch.isalpha() and not unicodedata.name(ch, "").startswith("LATIN"):
            found.append(f"{path}:{line}:{column}: non-Latin letter U+{ord(ch):04X} {unicodedata.name(ch, '?')}")
        if ch == "\n":
            line, column = line + 1, 0
        before = ch
    if path.endswith(CODE):
        for line, column, ch in letters_outside_literals(text, not path.endswith(".swift")):
            found.append(f"{path}:{line}:{column}: letter U+{ord(ch):04X} {unicodedata.name(ch, '?')} outside a string "
                         "or comment")
    return found


def self_test():
    bad = {
        "a.swift": "let tok\u0435n = 1\n",                       # Cyrillic e in an identifier
        "b.swift": "let ok = \"x\" // \u202egnirts\u202c\n",     # bidirectional override
        "c.md": "zero\u200bwidth\n",                              # zero-width space
        "d.swift": "let caf\u00e9 = 1\n",                         # Latin, but in an identifier
        "e.sh": "echo hi\u00a0there\n",                           # no-break space
    }
    good = {
        "f.swift": "let s = \"K\u00edch th\u01b0\u1edbc\" // \u2192 \u00b7 \u21bb\nlet w = \"\u26a0\ufe0e \" + \"\\\"\u00e9\"\n",
        "g.swift": "let block = \"\"\"\n  Ph\u00f3ng to\n  \"\"\"\nlet x = 1\n",
        "h.md": "Usage HUD \u2014 \u201cquoted\u201d \u00a5 \u2026\n",
    }
    for path, text in bad.items():
        assert problems(path, text), path
    for path, text in good.items():
        assert not problems(path, text), (path, problems(path, text))
    print("character checker self-test passed")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    files = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
    found = []
    for path in files:
        if not path or path.lower().endswith(SKIP):
            continue
        with open(path, "rb") as handle:
            data = handle.read()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            found.append(f"{path}: not UTF-8")
            continue
        found.extend(problems(path, text))
    for line in found:
        print(line)
    if found:
        sys.exit(f"{len(found)} suspicious character(s); see above")
    print(f"checked {len([p for p in files if p])} files: no hidden or look-alike characters")


if __name__ == "__main__":
    main()
