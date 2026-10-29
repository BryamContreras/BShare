import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from github_release import check_tag_lease, installer_hashes, publish, stage, validate_tag


OLD = 'a' * 40
NEW = 'b' * 40
ANNOTATED = 'c' * 40


class FakeGitHub:
    def __init__(self):
        self.events = []
        self.reference = {'object': {'type': 'commit', 'sha': OLD}}
        self.releases = {
            'v1.0.4': {'id': 1, 'draft': False, 'assets': [{'id': 8, 'name': 'old.dmg'}]},
            'staging-v1.0.4-20-1': {'id': 2, 'draft': True, 'target_commitish': NEW, 'assets': []},
        }

    def api(self, method, endpoint, data=None, *, missing_ok=False):
        self.events.append((method, endpoint, copy.deepcopy(data)))
        if method == 'GET' and endpoint.startswith('releases/tags/'):
            return copy.deepcopy(self.releases.get(endpoint.removeprefix('releases/tags/')))
        if method == 'GET' and endpoint == 'git/ref/tags/v1.0.4':
            return copy.deepcopy(self.reference)
        if method == 'GET' and endpoint.startswith('git/ref/tags/staging-'):
            return None
        if method == 'POST' and endpoint == 'git/tags':
            return {'sha': ANNOTATED}
        if method == 'PATCH' and endpoint == 'git/refs/tags/v1.0.4':
            self.reference = {'object': {'type': 'tag', 'sha': data['sha']}}
            return self.reference
        if endpoint == 'releases/1':
            if method == 'PATCH':
                self.releases['v1.0.4'].update(data)
            return copy.deepcopy(self.releases['v1.0.4'])
        if method == 'DELETE' and endpoint == 'releases/assets/8':
            self.releases['v1.0.4']['assets'] = [a for a in self.releases['v1.0.4']['assets'] if a['id'] != 8]
            return None
        if method == 'DELETE' and endpoint == 'releases/2':
            self.releases.pop('staging-v1.0.4-20-1')
            return None
        if method == 'POST' and endpoint == 'releases':
            self.releases[data['tag_name']] = dict(data, id=3, assets=[])
            return self.releases[data['tag_name']]
        raise AssertionError(f'Unexpected request: {method} {endpoint}')

    def upload(self, tag, files):
        assert self.releases[tag]['draft']
        self.events.append(('UPLOAD', tag, [p.name for p in files]))
        self.releases[tag]['assets'] += [{'id': 10 + i, 'name': path.name} for i, path in enumerate(files)]


class GitHubReleaseTest(unittest.TestCase):
    def test_tag_validation_and_lease_prevent_overwriting_an_unrelated_change(self):
        self.assertEqual(validate_tag('v1.0.4'), '1.0.4')
        with self.assertRaises(ValueError):
            validate_tag('BShare 1.0.4')
        reference = {'object': {'sha': NEW}}
        with self.assertRaisesRegex(ValueError, 'changed during'):
            check_tag_lease(reference, OLD, ANNOTATED, NEW)
        check_tag_lease(reference, OLD, NEW, NEW)  # Retry after the intended tag move.

    def test_staging_preserves_the_existing_published_release_and_assets(self):
        github = FakeGitHub()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / 'CHANGELOG.md'
            changelog.write_text('## 1.0.4\n\n- Correct LAN selection.\n')
            values = stage(github, 'v1.0.4', '1.0.4', NEW, '21', '1', changelog, root / 'notes.md')
        self.assertEqual(values['upload_tag'], 'staging-v1.0.4-21-1')
        self.assertFalse(github.releases['v1.0.4']['draft'])
        self.assertEqual(github.releases['v1.0.4']['assets'], [{'id': 8, 'name': 'old.dmg'}])
        self.assertFalse(any(method in ['PATCH', 'DELETE'] for method, _, _ in github.events))

    def test_replacement_publishes_only_a_complete_verified_installer_set(self):
        github = FakeGitHub()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = ['BShare-1.0.4-android-armv7a.apk', 'BShare-1.0.4-android-arm64-v8a.apk',
                     'BShare-1.0.4+42-windows-x64-setup.exe', 'bshare_1.0.4-42_amd64.deb',
                     'bshare-1.0.4-42.x86_64.rpm', 'BShare-1.0.4-macos-arm64.pkg', 'BShare-1.0.4-macos-x64.pkg']
            for name in names:
                (root / name).write_bytes(name.encode())
            checksums = root / 'SHA256SUMS.txt'
            checksums.write_text(''.join(f'{hashlib.sha256(name.encode()).hexdigest()}  {name}\n' for name in names))
            notes = root / 'notes.md'
            notes.write_text('Correct LAN selection.')
            values = publish(github, 'v1.0.4', 'staging-v1.0.4-20-1', NEW, OLD, root, notes)
        final = github.releases['v1.0.4']
        self.assertTrue(values['published'])
        self.assertEqual(final['name'], 'v1.0.4')
        self.assertFalse(final['draft'])
        self.assertEqual({a['name'] for a in final['assets']}, {*names, 'SHA256SUMS.txt'})
        self.assertNotIn('staging-v1.0.4-20-1', github.releases)
        self.assertLess(next(i for i, e in enumerate(github.events) if e[0] == 'UPLOAD'),
                        next(i for i, e in enumerate(github.events) if e[:2] == ('POST', 'git/tags')))

    def test_checksums_reject_tampered_payload_before_publishing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / 'installer.pkg'
            payload.write_bytes(b'tampered')
            checksums = root / 'SHA256SUMS.txt'
            checksums.write_text(f'{hashlib.sha256(b"original").hexdigest()}  installer.pkg\n')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                installer_hashes([payload], checksums)


if __name__ == '__main__':
    unittest.main()
