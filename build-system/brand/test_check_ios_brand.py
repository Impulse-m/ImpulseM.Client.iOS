#!/usr/bin/env python3
"""Fixture test for the static brand check. Stdlib only; no network and no clock."""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from typing import Dict, List


# -I drops the script directory from sys.path, so it is added here explicitly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_ios_brand  # noqa: E402


CLEAN_FILES: Dict[str, str] = {
    "Telegram/Telegram-iOS/en.lproj/Localizable.strings": '"Hello" = "Welcome to ImpulseM";\n',
    "submodules/TelegramPresentationData/Sources/DefaultDayPresentationTheme.swift": "let accent = UIColor(rgb: 0x2085DF)\n",
    "submodules/SettingsUI/Sources/Link.swift": 'let link = "https://o.impulsem.net/addlist/abc"\n',
    "submodules/SettingsUI/Sources/Gift.swift": 'let gift = "https://t.me/nft/abc"\n',
    "submodules/SettingsUI/Tests/LinkTests.swift": 'let fixture = "https://t.me/addlist/abc"\n',
    "build-system/brand/fixture.txt": "ph.telegra.Telegraph 0x0088ff\n",
    "Telegram/WidgetKitWidget/en.lproj/Localizable.strings": '"Widget.Title" = "Open ImpulseM";\n',
    "submodules/TelegramUI/Components/Settings/ThemeAccentColorScreen/Sources/Accent.swift": "let base = UIColor(rgb: 0x2085DF)\n",
}

DIRTY_FILES: Dict[str, str] = {
    "Telegram/Telegram-iOS/de.lproj/InfoPlist.strings": '"NSContactsUsageDescription" = "Telegram needs contacts";\n',
    "Telegram/Share/en.lproj/Localizable.strings": '"Share.AuthTitle" = "Log in to Telegram";\n',
    "submodules/TelegramPresentationData/Sources/DefaultDarkPresentationTheme.swift": "let accent = UIColor(rgb: 0x3e88f7)\n",
    "submodules/TelegramUI/Components/Settings/ThemeAccentColorScreen/Sources/ThemeAccentColorController.swift": "let colors: [Int32] = [0x0088ff]\n",
    "submodules/SettingsUI/Sources/Share.swift": 'let link = "https://t.me/addlist/abc"\n',
    "build-system/configuration.json": '{"bundle_id": "ph.telegra.Telegraph", "team_id": "C67CF9S4VU"}\n',
}

EXPECTED_CLEAN_SCANNED: int = 7

EXPECTED_DIRTY_RULES: List[str] = [
    "old-palette",
    "outbound-link",
    "upstream-bundle-id",
    "upstream-team-id",
    "visible-brand-word",
]


def write_tree(root: str, files: Dict[str, str]) -> None:
    for relative, content in files.items():
        absolute: str = os.path.join(root, relative.replace("/", os.sep))

        os.makedirs(os.path.dirname(absolute), exist_ok=True)

        with open(absolute, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)


class BrandCheckTests(unittest.TestCase):
    def test_clean_tree_has_no_violations(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            write_tree(root, CLEAN_FILES)

            violations: List[check_ios_brand.Violation]
            scanned: int
            violations, scanned = check_ios_brand.check_tree(root)

            self.assertEqual(violations, [])
            self.assertEqual(scanned, EXPECTED_CLEAN_SCANNED)

    def test_dirty_tree_reports_each_rule(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            write_tree(root, DIRTY_FILES)

            violations: List[check_ios_brand.Violation]
            violations, _ = check_ios_brand.check_tree(root)

            rules: List[str] = sorted({violation.rule for violation in violations})

            self.assertEqual(rules, EXPECTED_DIRTY_RULES)

    def test_extension_strings_are_checked_for_brand_word(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            write_tree(root, {"Telegram/Share/en.lproj/Localizable.strings": '"Share.AuthTitle" = "Log in to Telegram";\n'})

            violations: List[check_ios_brand.Violation]
            violations, _ = check_ios_brand.check_tree(root)

            self.assertEqual(
                [(violation.path, violation.rule) for violation in violations],
                [("Telegram/Share/en.lproj/Localizable.strings", "visible-brand-word")],
            )

    def test_test_sources_and_brand_tooling_are_not_link_checked(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            write_tree(root, CLEAN_FILES)

            violations: List[check_ios_brand.Violation]
            violations, _ = check_ios_brand.check_tree(root)

            flagged_paths: List[str] = [violation.path for violation in violations]

            self.assertNotIn("submodules/SettingsUI/Tests/LinkTests.swift", flagged_paths)
            self.assertNotIn("build-system/brand/fixture.txt", flagged_paths)

    def test_main_returns_zero_on_clean_and_one_on_dirty(self) -> None:
        with tempfile.TemporaryDirectory() as clean_root:
            write_tree(clean_root, CLEAN_FILES)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(check_ios_brand.main(["--root", clean_root]), 0)

        with tempfile.TemporaryDirectory() as dirty_root:
            write_tree(dirty_root, DIRTY_FILES)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(check_ios_brand.main(["--root", dirty_root]), 1)


if __name__ == "__main__":
    unittest.main()
