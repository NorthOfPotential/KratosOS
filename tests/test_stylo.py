"""Tests for the stylometry normalizer."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "stylo", os.path.join(HERE, "..", "config", "includes.chroot", "usr", "local",
                          "lib", "kratos", "stylo.py"))
stylo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stylo)


class NormalizeTest(unittest.TestCase):
    def test_strips_zero_width_characters(self):
        dirty = "he​llo‍ wor﻿ld"
        self.assertEqual(stylo.normalize(dirty).strip(), "hello world")

    def test_smart_quotes_and_dashes_to_ascii(self):
        dirty = "“fancy” — it’s … done"
        self.assertEqual(stylo.normalize(dirty).strip(), '"fancy" - it\'s ... done')

    def test_two_spaces_after_period_collapse(self):
        self.assertEqual(stylo.normalize("One.  Two.  Three.").strip(), "One. Two. Three.")

    def test_unicode_and_nbsp_spaces_become_plain(self):
        self.assertEqual(stylo.normalize("a b c").strip(), "a b c")

    def test_homoglyphs_folded_to_ascii(self):
        # Cyrillic а е о  ->  Latin a e o
        self.assertEqual(stylo.normalize("cаfе").strip(), "cafe".replace("f", "f"))

    def test_trailing_whitespace_removed(self):
        self.assertEqual(stylo.normalize("line one   \nline two\t\n").strip(), "line one\nline two")

    def test_idempotent(self):
        dirty = "“weird”​  text here.  Again."
        once = stylo.normalize(dirty)
        self.assertEqual(once, stylo.normalize(once))

    def test_clean_text_unchanged_except_final_newline(self):
        clean = 'Plain text. No tricks here.'
        self.assertEqual(stylo.normalize(clean), clean + "\n")


class ScanTest(unittest.TestCase):
    def test_flags_email(self):
        found = dict(stylo.scan("reach me at bob.smith@example.com ok"))
        self.assertIn("email address", found)

    def test_flags_handle_and_url(self):
        labels = {l for l, _ in stylo.scan("see @realname and https://site.example/x")}
        self.assertIn("@handle", labels)
        self.assertIn("URL", labels)

    def test_flags_phone(self):
        labels = {l for l, _ in stylo.scan("call +1 415 555 2671 today")}
        self.assertIn("phone number", labels)

    def test_detects_invisible_fingerprint(self):
        labels = {l for l, _ in stylo.scan("hi​there")}
        self.assertIn("invisible character", labels)

    def test_clean_text_no_findings(self):
        self.assertEqual(stylo.scan("just a normal sentence about cats"), [])


class CliTest(unittest.TestCase):
    def test_scan_exit_code(self):
        # normalize removes invisibles, so scanning the normalized output passes
        self.assertEqual(stylo.scan(stylo.normalize("hi​there")), [])


if __name__ == "__main__":
    unittest.main()
