import hashlib
import tempfile
import unittest
from pathlib import Path

from prepare_release_assets import prepare, release_files


class PrepareReleaseAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'build-output'
        self.source.mkdir()
        self.output = self.root / 'release-assets'
        self.notes = self.root / 'release-notes.md'
        self.changelog = self.root / 'CHANGELOG.md'
        self.changelog.write_text('## 1.0.3\n\n- Release note.\n\n## 1.0.2\n', encoding='utf-8')
        for name in (
            'BShare-1.0.3-android-armv7a.apk',
            'BShare-1.0.3-android-arm64-v8a.apk',
            'BShare-1.0.3+47-windows-x64-setup.exe',
            'bshare_1.0.3-47_amd64.deb',
            'bshare-1.0.3-47.x86_64.rpm',
            'BShare-1.0.3-macos-arm64.pkg',
            'BShare-1.0.3-macos-x64.pkg',
        ):
            (self.source / name).write_bytes(name.encode())

    def tearDown(self):
        self.temp.cleanup()

    def test_collects_seven_separate_native_installers_and_checksums(self):
        assets = prepare(self.source, self.output, '1.0.3', self.changelog, self.notes)
        self.assertEqual(len(assets), 8)
        self.assertEqual(sum(path.suffix in {'.apk', '.exe', '.deb', '.rpm', '.pkg'} for path in assets), 7)
        self.assertFalse(any(path.suffix == '.zip' for path in assets))
        lines = (self.output / 'SHA256SUMS.txt').read_text().splitlines()
        self.assertEqual(len(lines), 7)
        for path in assets[:-1]:
            self.assertIn(hashlib.sha256(path.read_bytes()).hexdigest(), (self.output / 'SHA256SUMS.txt').read_text())
        self.assertIn('Release note.', self.notes.read_text())
        self.assertIn('BShare-1.0.3-macos-arm64.pkg', self.notes.read_text())

    def test_rejects_old_dmg_delivery_after_switching_to_pkg(self):
        (self.source / 'BShare-1.0.3-macos-arm64.pkg').rename(self.source / 'BShare-1.0.3-macos-arm64.dmg')
        with self.assertRaisesRegex(ValueError, 'Unexpected installer set'):
            release_files(self.source, '1.0.3')

    def test_rejects_universal_or_missing_architecture_apks(self):
        (self.source / 'BShare-1.0.3-android-armv7a.apk').unlink()
        (self.source / 'BShare-1.0.3-android-universal.apk').write_bytes(b'universal')
        with self.assertRaisesRegex(ValueError, 'Unexpected installer set'):
            release_files(self.source, '1.0.3')

    def test_rejects_missing_platform_installer(self):
        (self.source / 'bshare-1.0.3-47.x86_64.rpm').unlink()
        with self.assertRaisesRegex(ValueError, 'correctly named .rpm'):
            release_files(self.source, '1.0.3')

    def test_rejects_zip_delivery_files(self):
        (self.source / 'BShare-1.0.3-source.zip').write_bytes(b'zip')
        with self.assertRaisesRegex(ValueError, 'ZIP or tarball'):
            release_files(self.source, '1.0.3')

    def test_rejects_inconsistent_platform_build_numbers(self):
        (self.source / 'bshare-1.0.3-47.x86_64.rpm').rename(self.source / 'bshare-1.0.3-48.x86_64.rpm')
        with self.assertRaisesRegex(ValueError, 'inconsistent build numbers'):
            release_files(self.source, '1.0.3')


if __name__ == '__main__':
    unittest.main()
