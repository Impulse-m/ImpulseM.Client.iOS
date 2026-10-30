import unittest

from GenerateStrings import make_impulsem_token_values, substitute_impulsem_strings, substitute_impulsem_tokens


class NormalizeImpulsemTokenValuesTests(unittest.TestCase):
    def test_link_host_drops_scheme_case_and_slashes(self) -> None:
        values = make_impulsem_token_values(site_url='', link_host=' HTTPS://O.Example.org// ', web_url='')
        self.assertEqual(values['IMPULSEM_LINK_HOST'], 'o.example.org')

    def test_base_urls_keep_scheme_and_lose_trailing_slashes(self) -> None:
        values = make_impulsem_token_values(site_url='https://example.org/', link_host='', web_url=' https://web.example.org/ ')
        self.assertEqual(values['IMPULSEM_SITE_URL'], 'https://example.org')
        self.assertEqual(values['IMPULSEM_WEB_URL'], 'https://web.example.org')

    def test_whitespace_only_values_are_empty(self) -> None:
        values = make_impulsem_token_values(site_url='  ', link_host='/', web_url='')
        self.assertEqual(values['IMPULSEM_SITE_URL'], '')
        self.assertEqual(values['IMPULSEM_LINK_HOST'], '')
        self.assertEqual(values['IMPULSEM_WEB_URL'], '')


class SubstituteImpulsemTokensSetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = make_impulsem_token_values(site_url='https://example.org', link_host='o.example.org', web_url='https://web.example.org')

    def test_url_only_value_gets_site_base(self) -> None:
        self.assertEqual(substitute_impulsem_tokens('{IMPULSEM_SITE_URL}/faq#general', self.values), 'https://example.org/faq#general')

    def test_markdown_link_keeps_label_and_target(self) -> None:
        self.assertEqual(
            substitute_impulsem_tokens('[Learn more]({IMPULSEM_SITE_URL}/privacy#x)', self.values),
            '[Learn more](https://example.org/privacy#x)'
        )

    def test_markdown_label_with_empty_target_is_substituted(self) -> None:
        self.assertEqual(
            substitute_impulsem_tokens('[{IMPULSEM_SITE_URL}/dl]()', self.values),
            '[https://example.org/dl]()'
        )

    def test_link_host_token_is_substituted_in_path(self) -> None:
        self.assertEqual(
            substitute_impulsem_tokens('Reserve links [{IMPULSEM_LINK_HOST}/name]()', self.values),
            'Reserve links [o.example.org/name]()'
        )

    def test_value_without_tokens_is_unchanged(self) -> None:
        self.assertEqual(substitute_impulsem_tokens('Plain text, [label](https://other.example)', self.values), 'Plain text, [label](https://other.example)')


class SubstituteImpulsemTokensEmptyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = make_impulsem_token_values(site_url='', link_host='', web_url='')

    def test_url_only_value_becomes_empty(self) -> None:
        self.assertEqual(substitute_impulsem_tokens('{IMPULSEM_SITE_URL}/faq#general', self.values), '')

    def test_markdown_link_becomes_its_label(self) -> None:
        self.assertEqual(
            substitute_impulsem_tokens('By sending Stars you agree to the [Terms of Service]({IMPULSEM_SITE_URL}/tos/stars)', self.values),
            'By sending Stars you agree to the Terms of Service'
        )

    def test_markdown_link_with_token_label_becomes_empty(self) -> None:
        self.assertEqual(substitute_impulsem_tokens('[{IMPULSEM_SITE_URL}/dl]({IMPULSEM_SITE_URL}/dl)', self.values), '')

    def test_plain_text_loses_the_host_fragment(self) -> None:
        self.assertEqual(substitute_impulsem_tokens('Learn more at {IMPULSEM_SITE_URL}', self.values), 'Learn more at')

    def test_bracketed_link_host_with_escaped_newline_is_removed(self) -> None:
        value = r'This link opens a chat with you in ImpulseM:[\nhttps://{IMPULSEM_LINK_HOST}/%@]'
        self.assertEqual(substitute_impulsem_tokens(value, self.values), 'This link opens a chat with you in ImpulseM:')

    def test_set_token_stays_when_another_token_is_empty(self) -> None:
        values = make_impulsem_token_values(site_url='', link_host='o.example.org', web_url='')
        self.assertEqual(
            substitute_impulsem_tokens('Public links such as {IMPULSEM_LINK_HOST}/title or {IMPULSEM_SITE_URL}/x', values),
            'Public links such as o.example.org/title or'
        )


class SubstituteImpulsemStringsTests(unittest.TestCase):
    def test_file_content_is_substituted_per_value(self) -> None:
        content = '\n'.join([
            '/* FAQ */',
            '"Settings.FAQ_URL" = "{IMPULSEM_SITE_URL}/faq#general";',
            '"Plain.Key" = "Unchanged text";',
            '"Terms.Line" = "Agree to the [terms]({IMPULSEM_SITE_URL}/tos).";',
            ''
        ])
        expected = '\n'.join([
            '/* FAQ */',
            '"Settings.FAQ_URL" = "";',
            '"Plain.Key" = "Unchanged text";',
            '"Terms.Line" = "Agree to the terms.";',
            ''
        ])
        values = make_impulsem_token_values(site_url='', link_host='', web_url='')
        self.assertEqual(substitute_impulsem_strings(content, values), expected)

    def test_file_content_with_set_values(self) -> None:
        content = '"Settings.FAQ_URL" = "{IMPULSEM_SITE_URL}/faq#general";\n'
        values = make_impulsem_token_values(site_url='https://example.org', link_host='', web_url='')
        self.assertEqual(substitute_impulsem_strings(content, values), '"Settings.FAQ_URL" = "https://example.org/faq#general";\n')


if __name__ == '__main__':
    unittest.main()
