import os
import sys
import tempfile
import unittest
from typing import List


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rebrand_strings  # noqa: E402


SAMPLE_STRINGS: str = (
    "/* Localized strings */\r\n"
    "\r\n"
    "\"Premium.Title\" = \"Telegram Premium\";\r\n"
    "\"Premium.Protected\" = \"{Telegram} and @Telegram\";\r\n"
    "\"org.telegram.key\" = \"Plain text\";\r\n"
    "\"Menu.Escaped\" = \"Say \\\"Telegram\\\"\\nTelegram is here\";\r\n"
    "\"Menu.Link\" = \"Open https://t.me/Telegram or telegram.org/blog\";\r\n"
    "\"Menu.Multi\" = \"Optimizing Telegram...\r\n"
    "This is Telegram.\";\r\n"
)


def write_temp(content: str) -> str:
    handle = tempfile.NamedTemporaryFile(mode="wb", suffix=".strings", delete=False)
    handle.write(content.encode("utf-8"))
    handle.close()

    return handle.name


class RebrandTextTest(unittest.TestCase):

    def test_plain_brand_word(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("Telegram Premium"), "ImpulseM Premium")

    def test_uppercase_brand_word(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("INVITE TO TELEGRAM"), "INVITE TO IMPULSEM")

    def test_compound_brand_word(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text("Controleer je Telegramberichten"),
            "Controleer je ImpulseMberichten"
        )

    def test_template_key_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("{Telegram}"), "{Telegram}")

    def test_repository_name_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("TelegramDesktop"), "TelegramDesktop")

    def test_handle_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("@Telegram"), "@Telegram")

    def test_channel_handle_prefix_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("TelegramTipsBot"), "TelegramTipsBot")

    def test_hashtag_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("#Telegram"), "#Telegram")

    def test_markdown_link_target_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("[Telegram](telegram)"), "[ImpulseM](telegram)")

    def test_scheme_url_is_protected(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text("tg://resolve?domain=Telegram"),
            "tg://resolve?domain=Telegram"
        )

    def test_ton_scheme_is_protected_and_text_after_it_is_rebranded(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text("ton://transfer/x Telegram"),
            "ton://transfer/x ImpulseM"
        )

    def test_www_host_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("www.telegram.org"), "www.telegram.org")

    def test_identifier_is_protected(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text("org.telegram.Telegram-iOS"),
            "org.telegram.Telegram-iOS"
        )

    def test_snake_case_identifier_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("my_Telegram"), "my_Telegram")

    def test_markdown_emphasis_is_rebranded(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("__Telegram__"), "__ImpulseM__")

    def test_escaped_quote_and_newline_are_rebranded(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text(r'Say \"Telegram\"\nTelegram'),
            r'Say \"ImpulseM\"\nImpulseM'
        )

    def test_short_link_host_is_rebranded(self) -> None:
        self.assertEqual(
            rebrand_strings.rebrand_text("https://t.me/Telegram"),
            "https://o.impulsem.net/Telegram"
        )

    def test_subdomain_of_telegram_org_is_kept(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("core.telegram.org/api"), "core.impulsem.net/api")

    def test_telegram_org_host_is_rebranded(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("telegram.org/blog"), "impulsem.net/blog")

    def test_telesco_host_is_rebranded(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("telesco.pe/x"), "p.impulsem.net/x")

    def test_host_inside_longer_word_is_kept(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("product.media"), "product.media")

    def test_native_spelling_is_rebranded(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("텔레그램"), "ImpulseM")

    def test_email_address_is_protected(self) -> None:
        self.assertEqual(rebrand_strings.rebrand_text("recover@telegram.org"), "recover@telegram.org")

    def test_rebrand_is_idempotent(self) -> None:
        once: str = rebrand_strings.rebrand_text("Telegram Premium, INVITE TO TELEGRAM, t.me/Telegram")
        self.assertEqual(rebrand_strings.rebrand_text(once), once)


class RebrandFileTest(unittest.TestCase):

    def setUp(self) -> None:
        self.path: str = write_temp(SAMPLE_STRINGS)

    def tearDown(self) -> None:
        os.remove(self.path)

    def read_lines(self) -> List[str]:
        with open(self.path, "rb") as handle:
            return handle.read().decode("utf-8").split("\r\n")

    def test_apply_changes_only_values(self) -> None:
        before: List[str] = self.read_lines()
        self.assertEqual(rebrand_strings.apply_file(self.path), 0)
        after: List[str] = self.read_lines()

        self.assertEqual(len(before), len(after))
        self.assertEqual(after[0], before[0])
        self.assertEqual(after[1], before[1])
        self.assertEqual(after[2], "\"Premium.Title\" = \"ImpulseM Premium\";")
        self.assertEqual(after[3], "\"Premium.Protected\" = \"{Telegram} and @Telegram\";")
        self.assertEqual(after[4], "\"org.telegram.key\" = \"Plain text\";")
        self.assertEqual(after[5], "\"Menu.Escaped\" = \"Say \\\"ImpulseM\\\"\\nImpulseM is here\";")
        self.assertEqual(after[6], "\"Menu.Link\" = \"Open https://o.impulsem.net/Telegram or impulsem.net/blog\";")
        self.assertEqual(after[7], "\"Menu.Multi\" = \"Optimizing ImpulseM...")
        self.assertEqual(after[8], "This is ImpulseM.\";")

    def test_apply_keeps_crlf_line_endings(self) -> None:
        rebrand_strings.apply_file(self.path)

        with open(self.path, "rb") as handle:
            raw: bytes = handle.read()

        self.assertEqual(raw.count(b"\r\n"), raw.count(b"\n"))

    def test_check_fails_before_apply(self) -> None:
        self.assertEqual(rebrand_strings.check_file(self.path), 1)

    def test_check_passes_after_apply(self) -> None:
        rebrand_strings.apply_file(self.path)

        self.assertEqual(rebrand_strings.check_file(self.path), 0)

    def test_second_apply_changes_nothing(self) -> None:
        rebrand_strings.apply_file(self.path)
        first: List[str] = self.read_lines()
        rebrand_strings.apply_file(self.path)

        self.assertEqual(self.read_lines(), first)

    def test_check_reports_clean_file(self) -> None:
        clean_path: str = write_temp("\"Key\" = \"ImpulseM Premium\";\r\n")

        try:
            self.assertEqual(rebrand_strings.check_file(clean_path), 0)
        finally:
            os.remove(clean_path)

    def test_byte_order_mark_is_kept(self) -> None:
        bom_path: str = write_temp("﻿\"Key\" = \"Telegram\";\n")

        try:
            self.assertEqual(rebrand_strings.apply_file(bom_path), 0)

            with open(bom_path, "rb") as handle:
                raw: bytes = handle.read()

            self.assertEqual(raw, "﻿\"Key\" = \"ImpulseM\";\n".encode("utf-8"))
        finally:
            os.remove(bom_path)


if __name__ == "__main__":
    unittest.main()
