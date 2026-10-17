import unittest

from scripts import release_smoke


class ReleaseSmokeOutputTests(unittest.TestCase):
    def test_success_message_is_ascii_for_legacy_console_encodings(self):
        self.assertTrue(release_smoke.success_message("java").isascii())


if __name__ == "__main__":
    unittest.main()
