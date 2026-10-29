#!/usr/bin/env python3
"""Collect native installers as separate, checksum-verified release assets."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil


def changelog_section(path: Path, version: str) -> str:
    lines = path.read_text(encoding='utf-8').splitlines()
    heading = f'## {version}'
    try:
        start = lines.index(heading) + 1
    except ValueError:
        raise ValueError(f'Missing changelog section: {heading}') from None
    end = next((index for index in range(start, len(lines)) if lines[index].startswith('## ')), len(lines))
    section = '\n'.join(lines[start:end]).strip()
    if not section:
        raise ValueError(f'Empty changelog section: {heading}')
    return section


def release_files(source: Path, version: str) -> list[Path]:
    archives = [
        path.name for path in source.rglob('*')
        if path.is_file() and (path.suffix.lower() == '.zip' or path.name.lower().endswith('.tar.gz'))
    ]
    if archives:
        raise ValueError(f'ZIP or tarball assets are not allowed: {sorted(archives)}')
    files = [
        path for path in source.rglob('*')
        if path.is_file() and path.suffix.lower() in {'.apk', '.exe', '.deb', '.rpm', '.pkg', '.dmg'}
    ]
    names = [path.name for path in files]
    if len(names) != len(set(names)):
        raise ValueError('Build outputs contain duplicate release filenames')

    expected = {
        f'BShare-{version}-android-armv7a.apk',
        f'BShare-{version}-android-arm64-v8a.apk',
        f'BShare-{version}-macos-arm64.pkg',
        f'BShare-{version}-macos-x64.pkg',
    }
    patterns = {
        '.exe': re.compile(rf'^BShare-{re.escape(version)}\+(\d+)-windows-x64-setup\.exe$'),
        '.deb': re.compile(rf'^bshare_{re.escape(version)}-(\d+)_amd64\.deb$'),
        '.rpm': re.compile(rf'^bshare-{re.escape(version)}-(\d+)\.x86_64\.rpm$'),
    }
    build_numbers = set()
    for suffix, pattern in patterns.items():
        matches = [name for name in names if name.endswith(suffix) and pattern.fullmatch(name)]
        if len(matches) != 1:
            raise ValueError(f'Expected one correctly named {suffix} installer; found {matches}')
        build_numbers.add(pattern.fullmatch(matches[0]).group(1))
        expected.add(matches[0])

    if len(build_numbers) != 1:
        raise ValueError(f'Platform installers have inconsistent build numbers: {sorted(build_numbers)}')
    if set(names) != expected:
        missing = sorted(expected - set(names))
        unexpected = sorted(set(names) - expected)
        raise ValueError(f'Unexpected installer set; missing={missing}, unexpected={unexpected}')
    return sorted(files, key=lambda path: path.name)


def prepare(source: Path, output: Path, version: str, changelog: Path, notes_path: Path) -> list[Path]:
    files = release_files(source, version)
    output.mkdir(parents=True, exist_ok=True)
    assets = []
    for source_file in files:
        destination = output / source_file.name
        shutil.copy2(source_file, destination)
        assets.append(destination)

    checksums = [f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}' for path in assets]
    checksum_path = output / 'SHA256SUMS.txt'
    checksum_path.write_text('\n'.join(checksums) + '\n', encoding='utf-8')
    assets.append(checksum_path)

    notes = changelog_section(changelog, version)
    notes += '\n\n## Downloads\n\n'
    notes += '\n'.join(f'- `{path.name}`' for path in assets)
    notes += '\n\n## Support\n\n[Support development on Ko-fi](https://ko-fi.com/SoyBryam06c)'
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(notes + '\n', encoding='utf-8')
    return assets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--notes-output', type=Path, required=True)
    args = parser.parse_args()
    assets = prepare(args.input, args.output, args.version, args.changelog, args.notes_output)
    for asset in assets:
        print(asset)


if __name__ == '__main__':
    main()
