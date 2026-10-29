import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from github_release import check_tag_lease, installer_hashes, publish, release_for_tag, stage, validate_tag


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
            release = self.releases.get(endpoint.removeprefix('releases/tags/'))
            return copy.deepcopy(release) if release and not release['draft'] else None
        if method == 'GET' and endpoint == 'releases?per_page=100&page=1':
            return [dict(copy.deepcopy(release), tag_name=tag) for tag, release in self.releases.items()]
        if method == 'GET' and endpoint == 'git/ref/tags/v1.0.4':
            return copy.deepcopy(self.reference)
        if method == 'GET' and endpoint.startswith('git/ref/tags/staging-'):
            return None
        if method == 'POST' and endpoint == 'git/tags':
            return {'sha': ANNOTATED}
        if method == 'PATCH' and endpoint == 'git/refs/tags/v1.0.4':
            self.reference = {'object': {'type': 'tag', 'sha': data['sha']}}
            return self.reference
        if endpoint in ['releases/1', 'releases/2'] and method in ['GET', 'PATCH']:
            release = next(release for release in self.releases.values() if release['id'] == int(endpoint.split('/')[1]))
            if method == 'PATCH':
                release.update(data)
            return copy.deepcopy(release)
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
    def test_drafts_are_found_after_the_published_tag_endpoint_returns_not_found(self):
        github = FakeGitHub()
        draft = release_for_tag(github, 'staging-v1.0.4-20-1')
        self.assertTrue(draft['draft'])
        self.assertEqual(draft['id'], 2)
        self.assertIn(('GET', 'releases?per_page=100&page=1', None), github.events)
        self.assertIsNone(release_for_tag(github, 'v9.0.0', missing_ok=True))
        with self.assertRaisesRegex(ValueError, 'Release not found'):
            release_for_tag(github, 'v9.0.0')

    def test_draft_lookup_checks_additional_release_pages(self):
        class PaginatedGitHub(FakeGitHub):
            def api(self, method, endpoint, data=None, *, missing_ok=False):
                if endpoint == 'releases?per_page=100&page=1':
                    return [{'tag_name': f'v0.0.{index}'} for index in range(100)]
                if endpoint == 'releases?per_page=100&page=2':
                    return [{'tag_name': 'staging-v1.0.4-20-1', 'id': 2, 'draft': True}]
                return super().api(method, endpoint, data, missing_ok=missing_ok)
        self.assertEqual(release_for_tag(PaginatedGitHub(), 'staging-v1.0.4-20-1')['id'], 2)

    def test_stage_retry_reuses_the_existing_draft(self):
        github = FakeGitHub()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / 'CHANGELOG.md'
            changelog.write_text('## 1.0.4\n\n- Correct LAN selection.\n')
            values = stage(github, 'v1.0.4', '1.0.4', NEW, '20', '1', changelog, root / 'notes.md')
        self.assertEqual(values['upload_tag'], 'staging-v1.0.4-20-1')
        self.assertEqual(len(github.releases), 2)
        self.assertTrue(any(event[:2] == ('PATCH', 'releases/2') for event in github.events))

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
