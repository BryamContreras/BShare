#!/usr/bin/env python3
"""Stage complete installers before replacing a published version release."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode

from prepare_release_assets import changelog_section, release_files


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
            raise ValueError('Invalid repository name')
        self.repository = repository

    def api(self, method, endpoint, data=None, *, missing_ok=False):
        command = ['gh', 'api', '--method', method, f'repos/{self.repository}/{endpoint}']
        if data is not None:
            command += ['--input', '-']
        result = subprocess.run(command, input=None if data is None else json.dumps(data),
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            if missing_ok and 'HTTP 404' in result.stderr:
                return None
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout) if result.stdout.strip() else None

    def upload(self, release_id, files):
        # Drafts can exist before their tag ref does. Use the resolved release
        # ID throughout instead of asking `gh release upload` to find the tag.
        if type(release_id) is not int or release_id <= 0:
            raise ValueError('Expected a positive release ID')
        files = [Path(path) for path in files]
        if len({path.name for path in files}) != len(files):
            raise ValueError('Duplicate release asset filenames')
        for path in files:
            if not path.is_file():
                raise ValueError(f'Missing release asset: {path.name}')
        existing = []
        page = 1
        while True:
            assets = self.api('GET', f'releases/{release_id}/assets?per_page=100&page={page}')
            existing.extend(assets)
            if len(assets) < 100:
                break
            page += 1
        for path in files:
            # Preserve --clobber behavior, including empty `starter` assets
            # left by an interrupted upload. Never delete unrelated assets.
            for asset in existing:
                if asset['name'] == path.name:
                    self.api('DELETE', f"releases/assets/{asset['id']}")
            query = urlencode({'name': path.name})
            endpoint = (f'https://uploads.github.com/repos/{self.repository}'
                        f'/releases/{release_id}/assets?{query}')
            size = path.stat().st_size
            result = subprocess.run(
                ['gh', 'api', '--method', 'POST', endpoint,
                 '--header', 'Content-Type: application/octet-stream',
                 '--header', f'Content-Length: {size}', '--input', str(path)],
                capture_output=True, text=True, timeout=900)
            if result.returncode:
                raise RuntimeError(f'Release asset upload failed ({path.name}): {result.stderr.strip()}')
            uploaded = json.loads(result.stdout)
            if (uploaded.get('name') != path.name or uploaded.get('size') != size
                    or uploaded.get('state') != 'uploaded'):
                raise ValueError(f'GitHub did not confirm the uploaded asset: {path.name}')


def validate_tag(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Release tag must be vMAJOR.MINOR.PATCH')
    return tag[1:]


def release_for_tag(github, tag, *, missing_ok=False):
    # GitHub's by-tag endpoint only returns published releases. Drafts, even
    # those with uploaded installers, must be found through the release list.
    published = github.api('GET', f'releases/tags/{tag}', missing_ok=True)
    if published is not None:
        return published
    page = 1
    while True:
        releases = github.api('GET', f'releases?per_page=100&page={page}')
        for release in releases:
            if release['tag_name'] == tag:
                return release
        if len(releases) < 100:
            break
        page += 1
    if not missing_ok:
        raise ValueError(f'Release not found: {tag}')
    return None


def tag_commit(github, reference):
    if reference is None:
        return None
    value = reference['object']
    for _ in range(8):
        if value['type'] == 'commit':
            return value['sha']
        if value['type'] != 'tag':
            break
        value = github.api('GET', f"git/tags/{value['sha']}")['object']
    raise ValueError('Release tag must point to a commit')


def check_tag_lease(reference, expected_sha, commit, resolved_commit):
    current = reference['object']['sha'] if reference else ''
    # A retry after a successful tag move can safely finish publishing assets.
    if current != expected_sha and resolved_commit != commit:
        raise ValueError('Release tag changed during the build; refusing to replace it')


def installer_hashes(files, checksum_path):
    hashes = {}
    for line in checksum_path.read_text(encoding='utf-8').splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not re.fullmatch(r'[0-9a-f]{64}', fields[0]) or fields[1] in hashes:
            raise ValueError('Invalid installer checksum manifest')
        hashes[fields[1]] = fields[0]
    if set(hashes) != {path.name for path in files}:
        raise ValueError('Installer checksum manifest does not match the release files')
    for path in files:
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[path.name]:
            raise ValueError(f'Installer checksum mismatch: {path.name}')
    return hashes


def stage(github, tag, version, commit, run_id, attempt, changelog, notes_path):
    if validate_tag(tag) != version:
        raise ValueError('Release tag must match the version in pubspec.yaml')
    if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
        raise ValueError('Expected an immutable source commit SHA')
    if not str(run_id).isdigit() or not str(attempt).isdigit():
        raise ValueError('Expected numeric workflow run identifiers')
    existing = release_for_tag(github, tag, missing_ok=True)
    if existing and existing.get('immutable'):
        raise ValueError('GitHub marks this release immutable; it cannot be replaced')
    reference = github.api('GET', f'git/ref/tags/{tag}', missing_ok=True)
    upload_tag = f'staging-{tag}-{run_id}-{attempt}' if existing else tag
    notes = changelog_section(changelog, version)
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(notes + '\n', encoding='utf-8')
    draft = release_for_tag(github, upload_tag, missing_ok=True)
    if draft and (not draft['draft'] or draft['target_commitish'] != commit):
        raise ValueError('The staging release belongs to another source or is published')
    data = {'tag_name': upload_tag, 'target_commitish': commit, 'name': tag,
            'body': notes, 'draft': True, 'prerelease': False}
    if draft:
        github.api('PATCH', f"releases/{draft['id']}", data)
    else:
        github.api('POST', 'releases', data)
    return {'release_tag': tag, 'upload_tag': upload_tag,
            'expected_tag_sha': reference['object']['sha'] if reference else ''}


def publish(github, tag, upload_tag, commit, expected_tag_sha, assets, notes_path):
    version = validate_tag(tag)
    files = release_files(assets, version)
    checksums = assets / 'SHA256SUMS.txt'
    if not checksums.is_file():
        raise ValueError('Missing verified installer checksums')
    hashes = installer_hashes(files, checksums)
    files = [*files, checksums]
    notes = notes_path.read_text(encoding='utf-8')
    staging = release_for_tag(github, upload_tag)
    if not staging['draft'] or staging['target_commitish'] != commit:
        raise ValueError('Expected a draft containing installers for the source commit')
    reference = github.api('GET', f'git/ref/tags/{tag}', missing_ok=True)
    resolved = tag_commit(github, reference)
    check_tag_lease(reference, expected_tag_sha, commit, resolved)
    canonical = release_for_tag(github, tag, missing_ok=True)
    if canonical is None:
        canonical = github.api('POST', 'releases', {
            'tag_name': tag, 'target_commitish': commit, 'name': tag,
            'draft': True, 'prerelease': False,
        })
    # The old public release is untouched until all seven installers are ready.
    # Preserve explicit tag/source metadata when converting to a draft: a draft
    # without an existing Git ref must not become an `untagged-*` release.
    github.api('PATCH', f"releases/{canonical['id']}", {
        'tag_name': tag, 'target_commitish': commit, 'draft': True,
    })
    if upload_tag != tag:
        github.upload(canonical['id'], files)
    else:
        github.upload(canonical['id'], [checksums])
    desired = {path.name for path in files}
    current = github.api('GET', f"releases/{canonical['id']}")
    for asset in current['assets']:
        if asset['name'] not in desired:
            github.api('DELETE', f"releases/assets/{asset['id']}")
    current_names = {asset['name'] for asset in current['assets'] if asset['name'] in desired}
    if current_names != desired:
        raise ValueError('Published installer set is incomplete; keeping the release in draft')
    for asset in current['assets']:
        if asset['name'] in hashes and asset.get('digest') not in (None, f"sha256:{hashes[asset['name']]}"):
            raise ValueError('GitHub reports an installer digest mismatch; keeping the release in draft')
    # Recheck the lease immediately before the intentional version-tag update.
    reference = github.api('GET', f'git/ref/tags/{tag}', missing_ok=True)
    resolved = tag_commit(github, reference)
    check_tag_lease(reference, expected_tag_sha, commit, resolved)
    if resolved != commit:
        annotated = github.api('POST', 'git/tags', {
            'tag': tag, 'object': commit, 'type': 'commit', 'message': tag,
        })
        if reference:
            github.api('PATCH', f'git/refs/tags/{tag}', {'sha': annotated['sha'], 'force': True})
        else:
            github.api('POST', 'git/refs', {'ref': f'refs/tags/{tag}', 'sha': annotated['sha']})
    github.api('PATCH', f"releases/{canonical['id']}", {
        'name': tag, 'tag_name': tag, 'target_commitish': commit,
        'body': notes, 'draft': False, 'prerelease': False, 'make_latest': 'true',
    })
    if upload_tag != tag:
        github.api('DELETE', f"releases/{staging['id']}")
        staged_ref = github.api('GET', f'git/ref/tags/{upload_tag}', missing_ok=True)
        if staged_ref and tag_commit(github, staged_ref) == commit:
            github.api('DELETE', f'git/refs/tags/{upload_tag}')
    return {'tag': tag, 'commit': commit, 'assets': sorted(desired), 'published': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='operation', required=True)
    for name in ['stage', 'publish']:
        sub = subparsers.add_parser(name)
        sub.add_argument('--repo', required=True)
        sub.add_argument('--tag', required=True)
        sub.add_argument('--commit', required=True)
        sub.add_argument('--notes', type=Path, required=True)
        if name == 'stage':
            sub.add_argument('--version', required=True)
            sub.add_argument('--run-id', required=True)
            sub.add_argument('--attempt', default='1')
            sub.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
            sub.add_argument('--github-output', type=Path)
        else:
            sub.add_argument('--upload-tag', required=True)
            sub.add_argument('--expected-tag-sha', default='')
            sub.add_argument('--assets', type=Path, required=True)
    args = parser.parse_args()
    github = GitHub(args.repo)
    if args.operation == 'stage':
        values = stage(github, args.tag, args.version, args.commit, args.run_id,
                       args.attempt, args.changelog, args.notes)
        if args.github_output:
            with args.github_output.open('a', encoding='utf-8') as output:
                for key, value in values.items():
                    output.write(f'{key}={value}\n')
    else:
        values = publish(github, args.tag, args.upload_tag, args.commit,
                         args.expected_tag_sha, args.assets, args.notes)
    print(json.dumps(values))


if __name__ == '__main__':
    main()
