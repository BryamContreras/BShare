import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bshare_prepare_adb', ROOT / 'packaging/prepare_adb.py')
adb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adb)


class PrepareAdbTest(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / 'build/adb-helper-tests'
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='case-', dir=temporary_root)
        self.work = Path(self.temporary.name).resolve()
        self.assertTrue(self.work.is_relative_to(temporary_root.resolve()))
        self.addCleanup(self.temporary.cleanup)
        self.manifest = json.loads(adb.MANIFEST.read_text(encoding='utf8'))
        self.files = {name: (f'Pinned upstream fixture: {name}\n').encode()
                      for name in adb.ALLOWLIST['windows']}
        self.files['source.properties'] = b'Pkg.UserSrc=false\nPkg.Revision=37.0.0\n'
        self.archive = self.work / 'upstream.zip'
        with zipfile.ZipFile(self.archive, 'w') as source:
            for name, data in self.files.items():
                source.writestr('platform-tools/' + name, data)
            source.writestr('platform-tools/fastboot.exe', b'Not part of BShare')
            source.writestr('../outside.txt', b'Never extract arbitrary paths')
        target = self.manifest['targets']['windows']
        target['sha256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        target['bytes'] = self.archive.stat().st_size
        target['files'] = {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                           for name, data in self.files.items()}
        self.destination = self.work / 'bundle/tools/platform-tools'

    def prepare(self, **options):
        return adb.prepare('windows', self.destination, manifest=self.manifest,
                           archive=self.archive, **options)

    def test_only_allowlisted_client_and_complete_licenses_are_staged(self):
        self.prepare()
        names = {path.name for path in self.destination.iterdir()}
        self.assertEqual(names, adb.ALLOWLIST['windows'] | {
            'LICENSE.adb.txt', 'BSHARE-ADB.txt', adb.OWNER_FILE})
        self.assertEqual((self.destination / 'NOTICE.txt').read_bytes(), self.files['NOTICE.txt'])
        self.assertEqual((self.destination / 'LICENSE.adb.txt').read_bytes(),
                         (adb.DATA / 'LICENSE.adb.txt').read_bytes())
        self.assertFalse((self.work / 'bundle/tools/outside.txt').exists())

    def test_corrupt_archive_fails_before_modifying_an_output(self):
        self.archive.write_bytes(self.archive.read_bytes() + b'corrupt')
        with self.assertRaisesRegex(ValueError, 'size|SHA-256'):
            self.prepare()
        self.assertFalse(self.destination.exists())

    def test_unowned_directory_is_not_replaced(self):
        self.destination.mkdir(parents=True)
        valuable = self.destination / 'my-adb.exe'
        valuable.write_bytes(b'User supplied client')
        with self.assertRaisesRegex(ValueError, 'unowned'):
            self.prepare()
        self.assertEqual(valuable.read_bytes(), b'User supplied client')
        self.assertEqual(list(self.destination.iterdir()), [valuable])

    def test_owned_modified_binary_is_not_silently_overwritten(self):
        self.prepare()
        binary = self.destination / 'adb.exe'
        binary.write_bytes(b'User modified the old executable')
        with self.assertRaisesRegex(ValueError, 'size|SHA-256'):
            self.prepare()
        self.assertEqual(binary.read_bytes(), b'User modified the old executable')

    def test_identical_repeat_preserves_binary_and_resumes_a_missing_file(self):
        self.prepare()
        binary = self.destination / 'adb.exe'
        before = binary.stat().st_mtime_ns
        self.prepare()
        self.assertEqual(binary.stat().st_mtime_ns, before)
        (self.destination / 'NOTICE.txt').unlink()
        self.prepare()
        self.assertEqual((self.destination / 'NOTICE.txt').read_bytes(), self.files['NOTICE.txt'])

    def test_sdk_mismatch_never_downloads_or_falls_back(self):
        sdk = self.work / 'sdk/platform-tools'
        sdk.mkdir(parents=True)
        for name, data in self.files.items():
            (sdk / name).write_bytes(data)
        (sdk / 'adb.exe').write_bytes(b'Different SDK revision')
        with mock.patch.object(adb.urllib.request, 'urlopen') as download:
            with self.assertRaisesRegex(ValueError, 'size|SHA-256'):
                adb.prepare('windows', self.destination, manifest=self.manifest,
                            sdk_directory=sdk.parent)
            download.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_owned_provenance_upgrade_preserves_the_verified_binary(self):
        self.prepare()
        binary = self.destination / 'adb.exe'
        before = binary.stat().st_mtime_ns
        note = self.destination / 'BSHARE-ADB.txt'
        note.write_bytes(b'An older BShare-generated provenance note')
        marker = self.destination / adb.OWNER_FILE
        previous = json.loads(marker.read_text())
        previous['files'][note.name] = {'bytes': note.stat().st_size,
                                       'sha256': hashlib.sha256(note.read_bytes()).hexdigest()}
        marker.write_text(json.dumps(previous))
        self.prepare()
        self.assertEqual(binary.stat().st_mtime_ns, before)
        self.assertIn(b'pinned upstream archive', note.read_bytes())
        updated = json.loads(marker.read_text())
        self.assertEqual(updated['files'][note.name]['sha256'], hashlib.sha256(note.read_bytes()).hexdigest())

    def test_unsupported_architecture_fails_before_staging(self):
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            self.prepare(architecture='arm64')
        self.assertFalse(self.destination.exists())

    def test_unexpected_manifest_members_are_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['targets']['windows']['files']['../outside'] = {'bytes': 0, 'sha256': ''}
        with self.assertRaisesRegex(ValueError, 'allowlist'):
            adb.prepare('windows', self.destination, manifest=manifest, archive=self.archive)
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
