#!/usr/bin/env python3
"""Stage the pinned, minimal ADB client beside a BShare desktop executable.

Downloads only an official, SHA-256-pinned archive, or checks an existing SDK
against the same per-file hashes. Never runs device/server commands, installs
drivers, or modifies PATH. This module is independent of Flutter.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import stat
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DATA = Path(__file__).resolve().parent / 'adb'
MANIFEST = DATA / 'manifest.json'
OWNER_FILE = 'bshare-adb-manifest.json'
ALLOWLIST = {
    'windows': {'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll', 'NOTICE.txt', 'source.properties'},
    'linux': {'adb', 'NOTICE.txt', 'source.properties'},
    'macos': {'adb', 'NOTICE.txt', 'source.properties'},
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checked_bytes(path: Path, expected: dict) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Expected a regular file: {path}')
    if path.stat().st_size != expected['bytes']:
        raise ValueError(f'Unexpected size: {path.name}')
    value = path.read_bytes()
    if sha256(value) != expected['sha256']:
        raise ValueError(f'SHA-256 mismatch: {path.name}')
    return value


def acquire_archive(target: dict, cache: Path) -> Path:
    """Fetch one fixed official URL; a corrupt cache fails closed."""
    name = target['url'].rsplit('/', 1)[-1]
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / name
    if archive.exists():
        checked_bytes(archive, target)
        return archive
    temporary = cache / f'.{name}.{secrets.token_hex(8)}.part'
    try:
        with urllib.request.urlopen(target['url'], timeout=30) as source:
            with temporary.open('xb') as output:
                total = 0
                while chunk := source.read(1024 * 1024):
                    total += len(chunk)
                    if total > target['bytes']:
                        raise ValueError('ADB archive exceeded its pinned size')
                    output.write(chunk)
        checked_bytes(temporary, target)
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def archive_files(archive: Path, target: dict) -> dict[str, bytes]:
    checked_bytes(archive, target)
    files = {}
    with zipfile.ZipFile(archive) as source:
        members = source.namelist()
        for name, expected in target['files'].items():
            member = f'platform-tools/{name}'
            if members.count(member) != 1:
                raise ValueError(f'Missing or duplicate ADB archive member: {name}')
            info = source.getinfo(member)
            if stat.S_ISLNK(info.external_attr >> 16) or info.file_size != expected['bytes']:
                raise ValueError(f'Invalid ADB archive member: {name}')
            value = source.read(info)
            if sha256(value) != expected['sha256']:
                raise ValueError(f'ADB member SHA-256 mismatch: {name}')
            files[name] = value
    return files


def sdk_files(directory: Path, target: dict) -> dict[str, bytes]:
    if not (directory / 'source.properties').is_file():
        directory = directory / 'platform-tools'
    return {name: checked_bytes(directory / name, expected)
            for name, expected in target['files'].items()}


def atomic_write(path: Path, value: bytes) -> None:
    temporary = path.parent / f'.bshare-adb-{secrets.token_hex(8)}.tmp'
    try:
        with temporary.open('xb') as output:
            output.write(value)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def stage_files(destination: Path, files: dict[str, bytes], metadata: dict, target_platform: str) -> dict:
    """Own one dedicated directory. Never replace an unmarked/nonmatching tree."""
    if destination.is_symlink():
        raise ValueError('ADB destination must not be a symlink')
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / OWNER_FILE
    desired = {name: {'bytes': len(value), 'sha256': sha256(value)}
               for name, value in files.items()}
    owner = {'owner': 'BShare bundled ADB', 'schema': 1, **metadata, 'files': desired}
    entries = list(destination.iterdir())
    previous = None
    if entries:
        if marker.is_symlink() or not marker.is_file():
            raise ValueError('Refusing to overwrite an unowned ADB directory')
        previous = json.loads(marker.read_text(encoding='utf8'))
        if any(previous.get(key) != value for key, value in owner.items() if key != 'files'):
            raise ValueError('Existing ADB payload does not match this pinned target')
        old_files = previous.get('files', {})
        if set(old_files) != set(desired) or any(
            old_files[name] != desired[name]
            for name in desired if name not in ['BSHARE-ADB.txt', 'LICENSE.adb.txt']
        ):
            raise ValueError('Existing ADB executable files differ from the pinned source')
        for entry in entries:
            if entry == marker:
                continue
            if entry.name not in desired:
                raise ValueError(f'Unexpected file in owned ADB directory: {entry.name}')
            checked_bytes(entry, old_files[entry.name])
    else:
        # Mark ownership first so an interrupted write can resume safely. Every
        # existing file must still match its desired hash on the next run.
        atomic_write(marker, (json.dumps(owner, indent=2) + '\n').encode())
    for name, value in files.items():
        path = destination / name
        if not path.exists() or (previous is not None and previous['files'][name] != desired[name]):
            atomic_write(path, value)
        path.chmod(0o755 if name in ['adb', 'adb.exe'] else 0o644)
    if previous is not None and previous != owner:
        atomic_write(marker, (json.dumps(owner, indent=2) + '\n').encode())
    return {'destination': str(destination), **metadata,
            'payloadFiles': sorted(files), 'targetPlatform': target_platform}


def prepare(target_platform: str, destination: Path, *, archive: Path | None = None,
            sdk_directory: Path | None = None, cache_directory: Path | None = None,
            architecture: str | None = None, manifest: dict | None = None) -> dict:
    manifest = manifest or json.loads(MANIFEST.read_text(encoding='utf8'))
    target = manifest['targets'][target_platform]
    if set(target['files']) != ALLOWLIST[target_platform]:
        raise ValueError('ADB manifest files differ from the minimal client allowlist')
    if architecture and architecture not in target['architectures']:
        raise ValueError(f'ADB is unavailable for {target_platform}/{architecture}')
    if archive is not None and sdk_directory is not None:
        raise ValueError('Choose an archive or an installed SDK, not both')
    if sdk_directory is not None:
        files = sdk_files(sdk_directory, target)
    else:
        archive = archive or acquire_archive(target, cache_directory or ROOT / 'build/cache/adb')
        files = archive_files(archive, target)
    properties = files['source.properties'].decode('utf8')
    if f'Pkg.Revision={manifest["revision"]}' not in properties.splitlines():
        raise ValueError('ADB source.properties does not match the pinned revision')
    license_path = DATA / manifest['license']['file']
    license_bytes = license_path.read_bytes()
    if sha256(license_bytes) != manifest['license']['sha256']:
        raise ValueError('ADB source license SHA-256 mismatch')
    files['LICENSE.adb.txt'] = license_bytes
    files['BSHARE-ADB.txt'] = (
        f'BShare bundles Android Debug Bridge from the pinned upstream archive.\n'
        f'Platform-Tools revision: {manifest["revision"]}\n'
        f'Upstream archive: {target["url"]}\n'
        f'Archive SHA-256: {target["sha256"]}\n'
        'ADB source: https://android.googlesource.com/platform/packages/modules/adb/\n'
        'The complete upstream NOTICE.txt and ADB Apache license are retained.\n'
        'Other Platform-Tools executables, SDK APIs and USB drivers are not included.\n'
    ).encode('utf8')
    return stage_files(destination, files, {
        'revision': manifest['revision'], 'archiveUrl': target['url'],
        'archiveSha256': target['sha256'], 'architectures': target['architectures'],
    }, target_platform)


def verify_executable(destination: Path, target_platform: str, revision: str) -> None:
    host = {'Windows': 'windows', 'Linux': 'linux', 'Darwin': 'macos'}.get(platform.system())
    if host != target_platform:
        raise ValueError('ADB executable verification requires its native OS')
    binary = destination.resolve() / ('adb.exe' if target_platform == 'windows' else 'adb')
    # `adb version` does not start/contact a server or interact with any device.
    output = subprocess.run([str(binary), 'version'], cwd=binary.parent,
                            check=True, capture_output=True, text=True, timeout=10).stdout
    if 'Android Debug Bridge version ' not in output or f'Version {revision}-' not in output:
        raise ValueError('Staged ADB did not report its pinned revision')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=sorted(ALLOWLIST), required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--architecture', choices=['x64', 'arm64'])
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--archive', type=Path)
    source.add_argument('--sdk-directory', type=Path)
    parser.add_argument('--cache-directory', type=Path)
    parser.add_argument('--verify-executable', action='store_true')
    args = parser.parse_args()
    result = prepare(args.platform, args.destination, archive=args.archive,
                     sdk_directory=args.sdk_directory, cache_directory=args.cache_directory,
                     architecture=args.architecture)
    if args.verify_executable:
        verify_executable(args.destination, args.platform, result['revision'])
        result['nativeVersionVerified'] = True
    print(json.dumps(result))


if __name__ == '__main__':
    main()
