#!/usr/bin/env python3
"""Static brand check for the ImpulseM iOS tree.

Stdlib only. The check fails when the tree still holds a value that the ImpulseM rebrand removed:
the upstream bundle id, team id and API hash, the old day and dark palette values, a visible
Telegram word in the bundled .strings files, or a generated https://t.me/ link outside the
protected lists below.

Files come from git (tracked and untracked, not ignored) when the root is a repository, and from
a directory walk otherwise. Test sources and the brand tooling itself are not scanned for links,
and the brand tooling is not scanned at all.

Modes:
  check_ios_brand.py [--root DIR]   scan DIR (default: the iOS tree) and exit 1 on any violation
"""

import argparse
import os
import re
import subprocess
import sys
from typing import List, NamedTuple, Optional, Pattern, Sequence, Tuple


# The strings rules are shared with the rebrand script. The -I flag drops the script directory from
# sys.path, so it is added here explicitly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rebrand_strings  # noqa: E402


UPSTREAM_IDENTIFIERS: List[Tuple[str, Pattern[str]]] = [
    ("upstream-bundle-id", re.compile(r"ph\.telegra\.Telegraph")),
    ("upstream-team-id", re.compile(r"C67CF9S4VU")),
    ("upstream-api-hash", re.compile(r"7245de8e747a0d6fbe11f7cc14fcc0bb")),
]

PALETTE_DIRECTORIES: Tuple[str, ...] = (
    "submodules/TelegramPresentationData/Sources",
    "submodules/TelegramUIPreferences/Sources",
    "submodules/SettingsUI/Sources/Themes",
    "submodules/TelegramUI/Components/Settings/ThemeAccentColorScreen/Sources",
)

OLD_PALETTE_PATTERN: Pattern[str] = re.compile(
    r"0x(?:0088ff|3e88f7|2ea6ff|1c1c1d|545458)(?![0-9a-fA-F])",
    re.IGNORECASE,
)

STRINGS_DIRECTORIES: Tuple[str, ...] = (
    "Telegram/Telegram-iOS",
    "Telegram/Share",
    "Telegram/WidgetKitWidget",
)

STRINGS_FILE_NAMES: Tuple[str, ...] = (
    "Localizable.strings",
    "InfoPlist.strings",
)

OUTBOUND_LINK_PATTERN: Pattern[str] = re.compile(r"https://t\.me/", re.IGNORECASE)

# Lines that keep an upstream link on purpose: Gifts, Fragment and Ads entries are not rebranded.
PROTECTED_LINK_TOKENS: Tuple[str, ...] = (
    "t.me/nft/",
    "t.me/auction/",
    "t.me/giftcode/",
    "t.me/cocoon",
    "fragment.com",
)

# The brand tooling holds the rules themselves, so it is not scanned.
EXEMPT_DIRECTORY: Tuple[str, ...] = (
    "build-system",
    "brand",
)

# Vendored upstream sources hold no ImpulseM strings or identifiers. Scanning them only adds time.
VENDORED_DIRECTORIES: Tuple[str, ...] = (
    "third-party",
    "submodules/ffmpeg",
    "submodules/libphonenumber",
)

SKIPPED_DIRECTORY_NAMES: Tuple[str, ...] = (
    ".git",
    "__pycache__",
    "node_modules",
)

BINARY_PROBE_SIZE: int = 8192

REPORTED_TEXT_LIMIT: int = 200


class Violation(NamedTuple):
    path: str
    line: int
    rule: str
    text: str


def default_root() -> str:
    directory: str = os.path.dirname(os.path.abspath(__file__))

    return os.path.abspath(os.path.join(directory, os.pardir, os.pardir))


def list_git_files(root: str) -> Optional[List[str]]:
    try:
        completed: subprocess.CompletedProcess[bytes] = subprocess.run(
            [
                "git",
                "-C",
                root,
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
            capture_output=True,
            check=False,
        )
    except OSError:
        return None

    if completed.returncode != 0:
        return None

    names: List[str] = completed.stdout.decode("utf-8", errors="replace").split("\0")

    return sorted({name for name in names if name != ""})


def walk_files(root: str) -> List[str]:
    found: List[str] = []

    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = [
            name
            for name in subdirectories
            if name not in SKIPPED_DIRECTORY_NAMES and not name.startswith("bazel-")
        ]

        for name in names:
            absolute: str = os.path.join(directory, name)
            relative: str = os.path.relpath(absolute, root).replace(os.sep, "/")

            found.append(relative)

    return sorted(found)


def list_files(root: str) -> List[str]:
    tracked: Optional[List[str]] = list_git_files(root)

    if tracked is not None:
        return tracked

    return walk_files(root)


def is_exempt(relative: str) -> bool:
    parts: List[str] = relative.split("/")

    if tuple(parts[:len(EXEMPT_DIRECTORY)]) == EXEMPT_DIRECTORY:
        return True

    for directory in VENDORED_DIRECTORIES:
        if relative.startswith(directory + "/"):
            return True

    return False


def is_test_path(relative: str) -> bool:
    directories: List[str] = relative.split("/")[:-1]

    for directory in directories:
        lowered: str = directory.lower()

        if lowered == "tests" or lowered.endswith("tests") or lowered.endswith("test"):
            return True

    return False


def is_palette_path(relative: str) -> bool:
    for directory in PALETTE_DIRECTORIES:
        if relative.startswith(directory + "/"):
            return True

    return False


def is_strings_path(relative: str) -> bool:
    for directory in STRINGS_DIRECTORIES:
        if relative.startswith(directory + "/") and os.path.basename(relative) in STRINGS_FILE_NAMES:
            return True

    return False


def read_text_file(absolute: str) -> Optional[str]:
    with open(absolute, "rb") as handle:
        raw: bytes = handle.read()

    if b"\x00" in raw[:BINARY_PROBE_SIZE]:
        return None

    return raw.decode("utf-8", errors="replace")


def printable(text: str) -> str:
    return text.encode("ascii", errors="backslashreplace").decode("ascii")


def check_identifiers(relative: str, lines: Sequence[str]) -> List[Violation]:
    found: List[Violation] = []

    for number, line in enumerate(lines, start=1):
        for rule, pattern in UPSTREAM_IDENTIFIERS:
            if pattern.search(line) is not None:
                found.append(Violation(relative, number, rule, line.strip()))

    return found


def check_palette(relative: str, lines: Sequence[str]) -> List[Violation]:
    found: List[Violation] = []

    if not is_palette_path(relative):
        return found

    for number, line in enumerate(lines, start=1):
        if OLD_PALETTE_PATTERN.search(line) is not None:
            found.append(Violation(relative, number, "old-palette", line.strip()))

    return found


def check_links(relative: str, lines: Sequence[str]) -> List[Violation]:
    found: List[Violation] = []

    if is_test_path(relative):
        return found

    for number, line in enumerate(lines, start=1):
        if OUTBOUND_LINK_PATTERN.search(line) is None:
            continue

        lowered: str = line.lower()

        if any(token in lowered for token in PROTECTED_LINK_TOKENS):
            continue

        found.append(Violation(relative, number, "outbound-link", line.strip()))

    return found


def check_strings(relative: str, text: str) -> List[Violation]:
    found: List[Violation] = []

    for number, value in rebrand_strings.find_violations(text):
        shown: str = value.replace("\n", "\\n")

        found.append(Violation(relative, number, "visible-brand-word", shown))

    return found


def check_file(relative: str, absolute: str) -> Tuple[Optional[List[str]], List[Violation]]:
    text: Optional[str] = None
    violations: List[Violation] = []

    if is_strings_path(relative):
        try:
            text = rebrand_strings.read_text(absolute)
        except ValueError as error:
            return None, [Violation(relative, 0, "unreadable-strings", str(error))]

        violations.extend(check_strings(relative, text))
    else:
        text = read_text_file(absolute)

    if text is None:
        return None, violations

    lines: List[str] = text.split("\n")

    violations.extend(check_identifiers(relative, lines))
    violations.extend(check_palette(relative, lines))
    violations.extend(check_links(relative, lines))

    return lines, violations


def check_tree(root: str) -> Tuple[List[Violation], int]:
    violations: List[Violation] = []
    scanned: int = 0

    for relative in list_files(root):
        if is_exempt(relative):
            continue

        absolute: str = os.path.join(root, relative.replace("/", os.sep))

        if not os.path.isfile(absolute):
            continue

        lines: Optional[List[str]]
        found: List[Violation]
        lines, found = check_file(relative, absolute)

        violations.extend(found)

        if lines is not None:
            scanned += 1

    ordered: List[Violation] = sorted(violations, key=lambda item: (item.path, item.line, item.rule))

    return ordered, scanned


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        description="Static brand check for the ImpulseM iOS tree."
    )

    parser.add_argument("--root", metavar="DIR", default=default_root())

    return parser.parse_args(list(argv))


def main(argv: Sequence[str]) -> int:
    arguments: argparse.Namespace = parse_arguments(argv)
    root: str = os.path.abspath(arguments.root)

    try:
        violations: List[Violation]
        scanned: int
        violations, scanned = check_tree(root)
    except OSError as error:
        print(str(error), file=sys.stderr)

        return 2

    for violation in violations:
        shown: str = printable(violation.text)[:REPORTED_TEXT_LIMIT]

        print(f"{violation.path}:{violation.line}: [{violation.rule}] {shown}", file=sys.stderr)

    if len(violations) > 0:
        print(f"brand check failed: {len(violations)} violation(s) in {scanned} files", file=sys.stderr)

        return 1

    print(f"brand check ok: {scanned} files")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
