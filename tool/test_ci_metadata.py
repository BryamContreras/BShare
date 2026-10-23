import tempfile
import unittest
from pathlib import Path

from ci_metadata import metadata


class CiMetadataTest(unittest.TestCase):
    def resolve(self, text, run=0):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pubspec.yaml"
            path.write_text(text)
            return metadata(path, run)

    def test_shared_version_advances_from_pubspec_build(self):
        self.assertEqual(
            self.resolve("name: bshare\nversion: 1.0.3+3\n", 1),
            {"version": "1.0.3", "build-number": "4"},
        )

    def test_quoted_version(self):
        self.assertEqual(self.resolve('version: "1.0.3+3"\n')["version"], "1.0.3")

    def test_missing_base_build_can_use_ci_run(self):
        self.assertEqual(self.resolve("version: 1.0.3\n", 5)["build-number"], "5")

    def test_rejects_unsupported_version(self):
        for text in ["version: custom\n", "version: 1.0.3; echo hello\n"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.resolve(text, 1)

    def test_rejects_windows_version_overflow(self):
        for text, run in [("version: 1.0.3+65535\n", 1), ("version: 65536.0.0+1\n", 0)]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.resolve(text, run)

    def test_rejects_negative_ci_run(self):
        with self.assertRaises(ValueError):
            self.resolve("version: 1.0.3+3\n", -1)


if __name__ == "__main__":
    unittest.main()
