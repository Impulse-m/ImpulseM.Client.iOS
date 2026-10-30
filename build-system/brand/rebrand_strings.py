#!/usr/bin/env python3
"""Rebrand the values of bundled Apple .strings files from Telegram to ImpulseM.

Stdlib only. The word rule follows the Android build-time rule (BrandText), and the host rule
follows the server language pack rule: Telegram hosts map to ImpulseM hosts, with subdomains kept.
Only the values of "key" = "value"; lines change. Keys, comments, line endings and every other
byte of the file are kept. The target hosts come from IMPULSEM_LINK_HOST and IMPULSEM_SITE_URL
(reserved example hosts when unset).

Modes:
  --apply FILE   rewrite the file in place
  --check FILE   exit 1 when a value still holds an unprotected brand word or host
"""

import argparse
import os
import re
import sys
from typing import Dict, List, Tuple


BRAND_NAME: str = "ImpulseM"
BRAND_UPPER: str = "IMPULSEM"

LINK_HOST_ENVIRONMENT: str = "IMPULSEM_LINK_HOST"
SITE_URL_ENVIRONMENT: str = "IMPULSEM_SITE_URL"

# Used when IMPULSEM_LINK_HOST and IMPULSEM_SITE_URL are not set, so that a checkout without
# configuration rebrands to reserved example hosts and never to an owner host.
PLACEHOLDER_LINK_HOST: str = "o.example.org"
PLACEHOLDER_SITE_HOST: str = "example.org"


def host_replacements(link_host: str, site_host: str) -> Dict[str, str]:
    return {
        "t.me": link_host,
        "telegram.me": link_host,
        "telegram.dog": link_host,
        "telesco.pe": link_host,
        "telegram.org": site_host,
    }


def site_host_from_url(site_url: str) -> str:
    host: str = site_url.strip()

    for scheme in ("https://", "http://"):
        if host.lower().startswith(scheme):
            host = host[len(scheme):]

    return host.rstrip("/")


def configured_host_replacements() -> Dict[str, str]:
    link_host: str = os.environ.get(LINK_HOST_ENVIRONMENT, "").strip().lower() or PLACEHOLDER_LINK_HOST
    site_url: str = os.environ.get(SITE_URL_ENVIRONMENT, "").strip()
    site_host: str = site_host_from_url(site_url) or PLACEHOLDER_SITE_HOST

    return host_replacements(link_host, site_host)


DEFAULT_HOST_REPLACEMENTS: Dict[str, str] = host_replacements(PLACEHOLDER_LINK_HOST, PLACEHOLDER_SITE_HOST)

NATIVE_SPELLINGS: List[str] = [
    "تيليجرام",
    "تليجرام",
    "텔레그램",
]

HOLD_OPEN: str = ""
HOLD_CLOSE: str = ""

HOLD_PATTERN: re.Pattern[str] = re.compile("([0-9]+)")

# Spans that are parked before the rules run and put back afterwards. Escape sequences are parked
# first, so that a brand word after "\n" still sees a non-letter before it.
EXCLUSION_PATTERNS: List[re.Pattern[str]] = [
    re.compile(r"\\."),
    re.compile(r"(?<!\w)(?:tg|ton|tc)://[^\s\"'<>)]*", re.IGNORECASE),
    re.compile(r"\{telegram\}", re.IGNORECASE),
    re.compile(r"\]\(telegram\)", re.IGNORECASE),
    re.compile(r"telegramdesktop", re.IGNORECASE),
    re.compile(r"TelegramTips\w*"),
    re.compile(r"org\.telegram[\w.\-]*", re.IGNORECASE),
    re.compile(r"(?<!\w)www\.[^\s\"'<>)]*", re.IGNORECASE),
    re.compile(r"(?<!%)@[\w.]+"),
    re.compile(r"#\w+"),
]

HOST_PATTERN: re.Pattern[str] = re.compile(
    r"(?<![a-z0-9\-])(t\.me|telegram\.me|telegram\.dog|telesco\.pe|telegram\.org)(?![a-z0-9\-])",
    re.IGNORECASE,
)

WORD_START: str = r"(?<![@/=])(?<![^\W_])(?<![^\W_]_)"

BRAND_WORD: re.Pattern[str] = re.compile(WORD_START + "Telegram")

BRAND_UPPER_WORD: re.Pattern[str] = re.compile(WORD_START + r"TELEGRAM(?!\w)(?!\.[^\W\d_])")

# A value may span physical lines (escaped newlines are literal line breaks in some upstream entries),
# so entries are matched over the whole text. Group 2 is the value; only that span is rewritten.
ENTRY_PATTERN: re.Pattern[str] = re.compile(
    r"^([ \t]*\"(?:[^\"\\]|\\.)*\"[ \t]*=[ \t]*\")((?:[^\"\\]|\\.)*)(\"[ \t]*;)",
    re.MULTILINE | re.DOTALL
)

BYTE_ORDER_MARK: str = "﻿"


def park(
    held: List[str],
    text: str
) -> str:
    held.append(text)

    return f"{HOLD_OPEN}{len(held) - 1}{HOLD_CLOSE}"


def rebrand_text(value: str, replacements: Dict[str, str] = DEFAULT_HOST_REPLACEMENTS) -> str:
    held: List[str] = []
    working: str = value

    for pattern in EXCLUSION_PATTERNS:
        working = pattern.sub(lambda match: park(held, match.group(0)), working)

    working = HOST_PATTERN.sub(lambda match: replacements[match.group(1).lower()], working)

    for spelling in NATIVE_SPELLINGS:
        working = working.replace(spelling, BRAND_NAME)

    working = BRAND_UPPER_WORD.sub(BRAND_UPPER, working)
    working = BRAND_WORD.sub(BRAND_NAME, working)

    while True:
        restored: str = HOLD_PATTERN.sub(lambda match: held[int(match.group(1))], working)

        if restored == working:
            return working

        working = restored


def split_byte_order_mark(text: str) -> Tuple[str, str]:
    if text.startswith(BYTE_ORDER_MARK):
        return BYTE_ORDER_MARK, text[len(BYTE_ORDER_MARK):]

    return "", text


def rebrand_file_text(text: str, replacements: Dict[str, str] = DEFAULT_HOST_REPLACEMENTS) -> Tuple[str, int]:
    prefix: str
    body: str
    prefix, body = split_byte_order_mark(text)

    pieces: List[str] = []
    position: int = 0
    changed: int = 0

    for match in ENTRY_PATTERN.finditer(body):
        value: str = match.group(2)
        rebranded: str = rebrand_text(value, replacements)

        pieces.append(body[position:match.start(2)])
        pieces.append(rebranded)
        position = match.end(2)

        if rebranded != value:
            changed += 1

    pieces.append(body[position:])

    return prefix + "".join(pieces), changed


def find_violations(text: str, replacements: Dict[str, str] = DEFAULT_HOST_REPLACEMENTS) -> List[Tuple[int, str]]:
    prefix: str
    body: str
    prefix, body = split_byte_order_mark(text)

    violations: List[Tuple[int, str]] = []

    for match in ENTRY_PATTERN.finditer(body):
        value: str = match.group(2)

        if rebrand_text(value, replacements) != value:
            number: int = body.count("\n", 0, match.start(2)) + 1
            violations.append((number, value))

    return violations


def read_text(path: str) -> str:
    with open(path, "rb") as handle:
        raw: bytes = handle.read()

    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        raise ValueError(f"{path}: UTF-16 .strings files are not handled, convert the file to UTF-8 first")

    return raw.decode("utf-8")


def apply_file(path: str, replacements: Dict[str, str] = DEFAULT_HOST_REPLACEMENTS) -> int:
    text: str = read_text(path)
    rewritten: str
    changed: int
    rewritten, changed = rebrand_file_text(text, replacements)

    if changed > 0:
        with open(path, "wb") as handle:
            handle.write(rewritten.encode("utf-8"))

    print(f"{path}: {changed} values rebranded")

    return 0


def check_file(path: str, replacements: Dict[str, str] = DEFAULT_HOST_REPLACEMENTS) -> int:
    violations: List[Tuple[int, str]] = find_violations(read_text(path), replacements)

    if len(violations) > 0:
        for number, value in violations:
            shown: str = value.replace("\n", "\\n")
            print(f"{path}:{number}: brand word or host left in value: {shown}", file=sys.stderr)

        return 1

    print(f"{path}: ok")

    return 0


def main(argv: List[str]) -> int:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        description="Rebrand Telegram to ImpulseM in the values of a .strings file."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--apply", metavar="FILE", default=None)
    group.add_argument("--check", metavar="FILE", default=None)

    args: argparse.Namespace = parser.parse_args(argv)

    try:
        replacements: Dict[str, str] = configured_host_replacements()

        if args.apply is not None:
            return apply_file(args.apply, replacements)

        return check_file(args.check, replacements)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)

        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
