#!/usr/bin/env python3
"""Stylometry guard: reduce the authorship fingerprint in persona text.

People are routinely de-anonymized by *how* they write, not what they say.
Some of the strongest markers are invisible and completely stable across a
person's writing:

  * zero-width / invisible Unicode characters (some editors and phones insert
    them; some people paste them without knowing)
  * "smart" quotes, em/en dashes, ellipsis characters vs ASCII
  * one vs two spaces after a full stop
  * trailing whitespace, non-breaking spaces, exotic Unicode spaces
  * homoglyphs (Cyrillic 'а' for Latin 'a', etc.)

`normalize` flattens all of those to a single plain form, so persona text
looks like everyone else's. `scan` additionally flags tokens that can directly
de-anonymize you (emails, phone numbers, @handles, URLs, long digit strings).

This is a *preprocessor*, not a disguise for your vocabulary or grammar — those
need conscious effort (see docs/OPSEC.md). It removes the covert, mechanical
tells that discipline can't catch.
"""
import argparse
import re
import sys
import unicodedata

# Invisible / zero-width characters that act as a hidden watermark.
INVISIBLE = {
    "​", "‌", "‍", "⁠", "﻿",  # zero-width family + BOM
    "‎", "‏", "‪", "‫", "‬", "‭", "‮",  # bidi
    "­",  # soft hyphen
}
# Unicode spaces that should become a plain space.
UNICODE_SPACES = "          " \
                 "     　"
PUNCT_MAP = {
    "‘": "'", "’": "'", "‚": "'", "‛": "'",
    "“": '"', "”": '"', "„": '"', "‟": '"',
    "–": "-", "—": "-", "‒": "-", "―": "-", "−": "-",
    "…": "...",
    "´": "'", "`": "'",
}
# Common confusable (homoglyph) letters → ASCII.
HOMOGLYPHS = {
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c",
    "х": "x", "у": "y", "і": "i", "ј": "j", "һ": "h",
    "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H",
    "Ο": "O", "Ρ": "P", "Τ": "T", "Χ": "X",
    "⁄": "/",
}

DEANON = [
    ("email address", re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")),
    ("phone number", re.compile(r"(?<!\d)(?:\+?\d[\d ().-]{7,}\d)(?!\d)")),
    ("@handle", re.compile(r"(?<!\w)@[A-Za-z0-9_]{2,}")),
    ("URL", re.compile(r"\bhttps?://\S+", re.I)),
    ("long digit string", re.compile(r"\b\d{9,}\b")),
]


def normalize(text):
    # Canonical compatibility form folds homoglyph-ish compatibility chars and
    # normalizes width; then we handle the rest explicitly.
    text = unicodedata.normalize("NFKC", text)
    text = "".join(HOMOGLYPHS.get(ch, ch) for ch in text)
    text = "".join("" if ch in INVISIBLE else ch for ch in text)
    text = "".join(" " if ch in UNICODE_SPACES else ch for ch in text)
    for k, v in PUNCT_MAP.items():
        text = text.replace(k, v)
    # One space after sentence punctuation (kills the "two spaces" tell).
    text = re.sub(r"([.!?])  +", r"\1 ", text)
    # Collapse any other run of spaces/tabs; strip trailing whitespace per line.
    text = re.sub(r"[ \t]+", " ", text)
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    # Normalize line endings and trim at most one trailing blank line.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.strip("\n") + "\n"


def scan(text):
    findings = []
    for ch in text:
        if ch in INVISIBLE:
            findings.append(("invisible character", f"U+{ord(ch):04X}"))
            break
    for ch in text:
        if ch in HOMOGLYPHS:
            findings.append(("homoglyph", f"U+{ord(ch):04X} looks like {HOMOGLYPHS[ch]!r}"))
            break
    for label, rx in DEANON:
        for m in rx.finditer(text):
            findings.append((label, m.group(0)))
    return findings


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("file", nargs="?", help="input file (default: stdin)")
    p.add_argument("--scan", action="store_true",
                   help="only report fingerprints and de-anonymizing tokens; don't rewrite")
    a = p.parse_args(argv)
    raw = open(a.file, encoding="utf-8").read() if a.file else sys.stdin.read()

    if a.scan:
        found = scan(raw)
        if not found:
            print("stylo: no invisible fingerprints or obvious de-anonymizers found", file=sys.stderr)
            return 0
        for label, detail in found:
            print(f"  {label}: {detail}", file=sys.stderr)
        return 1

    out = normalize(raw)
    sys.stdout.write(out)
    # Warn (on stderr, so piping stays clean) about anything that survived.
    leftover = scan(out)
    if leftover:
        print("stylo: WARNING, these could identify you — remove them yourself:", file=sys.stderr)
        for label, detail in leftover:
            print(f"  {label}: {detail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
