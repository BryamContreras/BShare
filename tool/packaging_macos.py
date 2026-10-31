#!/usr/bin/env python3
"""Build a native macOS installer and verify its /Applications payload."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ARCHITECTURES = {'arm64': 'arm64', 'x64': 'x86_64'}
APP_NAME = 'BShare.app'
ROOT = Path(__file__).resolve().parents[1]
ADB_EXECUTABLE = Path('Contents/MacOS/adb')
ADB_RESOURCES = Path('Contents/Resources/tools/platform-tools')


def run(arguments):
    try:
        result = subprocess.run([str(value) for value in arguments], check=True,
                                capture_output=True, text=True, timeout=300)
    except subprocess.SubprocessError as error:
        # Keep the native tool's reason (especially codesign's subcomponent)
        # visible while preserving its failure and all strict verification.
        for name, stream in [('stdout', sys.stdout), ('stderr', sys.stderr)]:
            detail = getattr(error, name, None)
            if isinstance(detail, bytes):
                detail = detail.decode('utf8', errors='replace')
            if detail:
                print(detail, file=stream, end='' if detail.endswith('\n') else '\n')
        raise
    return result.stdout.strip()


def stage_usb_adb(app, architecture, *, app_signing_identity='-'):
    """Pin upstream bytes, sign the child for sandbox inheritance, then seal app."""
    directory = app / ADB_RESOURCES
    binary = app / ADB_EXECUTABLE
    if binary.exists() or directory.exists():
        raise ValueError('Refusing to overwrite an existing ADB bundle payload')
    # Apple's nested-code locations contain signed code only. A tools tree with
    # NOTICE/JSON files under Contents/MacOS is not a supported bundle layout.
    # Verify upstream in an owned staging directory, then separate code/data.
    with tempfile.TemporaryDirectory(prefix='bshare-macos-adb-') as temporary:
        prepared = Path(temporary) / 'platform-tools'
        run([sys.executable, ROOT / 'packaging/prepare_adb.py',
             '--platform', 'macos', '--architecture', architecture,
             '--destination', prepared, '--verify-executable'])
        directory.mkdir(parents=True)
        binary.parent.mkdir(parents=True, exist_ok=True)
        for source in prepared.iterdir():
            shutil.copy2(source, binary if source.name == 'adb' else directory / source.name)
    upstream_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    run(['codesign', '--force', '--sign', app_signing_identity,
         '--entitlements', ROOT / 'packaging/adb/macos-inherit.entitlements', binary])
    run(['codesign', '--verify', '--strict', binary])
    signed_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    # Code signing intentionally changes the upstream executable's signature.
    # Record both hashes and describe that change beside the retained notices.
    note = directory / 'MACOS-CODESIGN.txt'
    note.write_text(
        'BShare reapplied the macOS code signature for App Sandbox inheritance.\n'
        'No ADB source changes were made. The original archive is SHA-256 pinned.\n'
        f'Upstream adb SHA-256: {upstream_hash}\n'
        f'Packaged signed adb SHA-256: {signed_hash}\n', encoding='utf8')
    marker = directory / 'bshare-adb-manifest.json'
    record = json.loads(marker.read_text(encoding='utf8'))
    record['files']['adb'] = {'bytes': binary.stat().st_size, 'sha256': signed_hash,
                            'bundlePath': ADB_EXECUTABLE.as_posix()}
    record['files'][note.name] = {'bytes': note.stat().st_size,
                                'sha256': hashlib.sha256(note.read_bytes()).hexdigest()}
    record['codeSigning'] = {'reason': 'macOS App Sandbox inheritance',
                            'upstreamAdbSha256': upstream_hash, 'signedAdbSha256': signed_hash}
    marker.write_text(json.dumps(record, indent=2) + '\n', encoding='utf8')
    # Reseal only the outer bundle, retaining its sandbox and other metadata.
    # --deep would unnecessarily re-sign frameworks and the already signed adb.
    run(['codesign', '--force', '--sign', app_signing_identity,
         '--preserve-metadata=identifier,entitlements,flags,runtime', app])
    return {'revision': record['revision'], 'executable': ADB_EXECUTABLE.as_posix(),
            'resources': ADB_RESOURCES.as_posix(), **record['codeSigning']}


def app_info(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    executable = info.get('CFBundleExecutable', '')
    identifier = info.get('CFBundleIdentifier', '')
    if not executable or Path(executable).name != executable:
        raise ValueError('Invalid bundle executable')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', identifier):
        raise ValueError('Invalid bundle identifier')
    return info


def validate_version(version, build):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Expected a numeric major.minor.patch version')
    if not str(build).isdigit() or not 1 <= int(build) <= 65535:
        raise ValueError('Expected a build number between 1 and 65535')
    return f'{version}.{int(build)}'


def verify_app(app, architecture, version, build):
    info = app_info(app)
    if info.get('CFBundleShortVersionString') != version:
        raise ValueError('The app version does not match the installer version')
    if str(info.get('CFBundleVersion')) != str(build):
        raise ValueError('The app build number does not match the installer build')
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    found = run(['lipo', '-archs', binary]).split()
    if found != [ARCHITECTURES[architecture]]:
        raise ValueError(f'Expected only {ARCHITECTURES[architecture]}, found {found}')
    run(['codesign', '--verify', '--deep', '--strict', app])
    return binary


def configure_components(path):
    with path.open('rb') as source:
        components = plistlib.load(source)
    if len(components) != 1 or components[0].get('RootRelativeBundlePath') != f'Applications/{APP_NAME}':
        raise ValueError('The package must contain exactly Applications/BShare.app')
    # A renamed or moved old copy must not redirect installation away from /Applications.
    components[0]['BundleIsRelocatable'] = False
    components[0]['BundleIsVersionChecked'] = True
    components[0]['BundleOverwriteAction'] = 'upgrade'
    with path.open('wb') as target:
        plistlib.dump(components, target)


def configure_distribution(path, architecture, version, minimum_os):
    tree = ET.parse(path)
    root = tree.getroot()
    title = root.find('title')
    if title is None:
        title = ET.SubElement(root, 'title')
    title.text = f'BShare v{version}'
    options = root.find('options')
    if options is None:
        options = ET.SubElement(root, 'options')
    options.set('customize', 'never')
    options.set('require-scripts', 'false')
    options.set('hostArchitectures', ARCHITECTURES[architecture])
    domains = root.find('domains')
    if domains is None:
        domains = ET.SubElement(root, 'domains')
    domains.attrib.update(enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
    if minimum_os:
        if not re.fullmatch(r'\d+(?:\.\d+){0,2}', minimum_os):
            raise ValueError('Invalid minimum macOS version in the app bundle')
        check = root.find('volume-check')
        if check is None:
            check = ET.SubElement(root, 'volume-check', script='true')
        allowed = check.find('allowed-os-versions')
        if allowed is None:
            allowed = ET.SubElement(check, 'allowed-os-versions')
        allowed.clear()
        ET.SubElement(allowed, 'os-version', min=minimum_os)
    tree.write(path, encoding='utf-8', xml_declaration=True)


def package(app, output, architecture, version, build, *, verify_install=False,
            signing_identity=None, app_signing_identity='-'):
    if platform.system() != 'Darwin':
        raise RuntimeError('Native PKG packaging requires macOS')
    package_version = validate_version(version, build)
    info = app_info(app)
    verify_app(app, architecture, version, build)
    output.mkdir(parents=True, exist_ok=True)
    installer = output.resolve() / f'BShare-{version}-macos-{architecture}.pkg'
    with tempfile.TemporaryDirectory(prefix='bshare-pkg-') as temporary:
        work = Path(temporary)
        payload = work / 'payload'
        staged = payload / 'Applications' / APP_NAME
        staged.parent.mkdir(parents=True)
        run(['ditto', app, staged])
        adb = stage_usb_adb(staged, architecture, app_signing_identity=app_signing_identity)
        verify_app(staged, architecture, version, build)
        components = work / 'components.plist'
        run(['pkgbuild', '--analyze', '--root', payload, components])
        configure_components(components)
        component = work / 'BShare-component.pkg'
        run(['pkgbuild', '--root', payload, '--component-plist', components,
             '--identifier', info['CFBundleIdentifier'] + '.installer',
             '--version', package_version, '--install-location', '/', component])
        distribution = work / 'Distribution.xml'
        run(['productbuild', '--synthesize', '--package', component, distribution])
        configure_distribution(distribution, architecture, version, info.get('LSMinimumSystemVersion'))
        arguments = ['productbuild', '--distribution', distribution, '--package-path', work]
        if signing_identity:
            arguments += ['--sign', signing_identity]
        run([*arguments, installer])
        expanded = work / 'expanded'
        run(['pkgutil', '--expand-full', installer, expanded])
        apps = list(expanded.rglob(APP_NAME))
        if len(apps) != 1 or apps[0].parent.name != 'Applications' or apps[0].parent.parent.name != 'Payload':
            raise ValueError('The expanded PKG has an unexpected app payload')
        payload_binary = verify_app(apps[0], architecture, version, build)
        payload_adb = apps[0] / ADB_EXECUTABLE
        run(['codesign', '--verify', '--strict', payload_adb])
        if hashlib.sha256(payload_adb.read_bytes()).hexdigest() != adb['signedAdbSha256']:
            raise ValueError('The PKG ADB executable differs from the signed payload')
        payload_hash = hashlib.sha256(payload_binary.read_bytes()).hexdigest()
        installed = False
        if verify_install:
            # This option is enabled on the ephemeral native CI runner only.
            run(['sudo', 'installer', '-pkg', installer, '-target', '/'])
            installed_binary = verify_app(Path('/Applications') / APP_NAME, architecture, version, build)
            if hashlib.sha256(installed_binary.read_bytes()).hexdigest() != payload_hash:
                raise ValueError('The installed executable differs from the package payload')
            installed_adb = Path('/Applications') / APP_NAME / ADB_EXECUTABLE
            run(['codesign', '--verify', '--strict', installed_adb])
            if hashlib.sha256(installed_adb.read_bytes()).hexdigest() != adb['signedAdbSha256']:
                raise ValueError('The installed ADB executable differs from the signed payload')
            installed = True
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    installer.with_suffix('.pkg.sha256').write_text(f'{digest}  {installer.name}\n', encoding='utf-8')
    report = {'format': 'pkg', 'architecture': architecture, 'version': version,
              'packageVersion': package_version, 'installLocation': f'/Applications/{APP_NAME}',
              'payloadVerified': True, 'installationVerified': installed,
              'bundledAdb': adb,
              'installerSigned': bool(signing_identity), 'notarized': False, 'sha256': digest}
    installer.with_suffix('.pkg.verification.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
    return installer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('build/macos/Build/Products/Release/bshare.app'))
    parser.add_argument('--output', type=Path, default=Path('dist/macos'))
    parser.add_argument('--architecture', choices=ARCHITECTURES, required=True)
    parser.add_argument('--version')
    parser.add_argument('--build-number')
    parser.add_argument('--verify-install', action='store_true')
    parser.add_argument('--signing-identity')
    parser.add_argument('--app-signing-identity', default='-',
                        help='App/ADB code-signing identity; distinct from PKG installer identity')
    args = parser.parse_args()
    info = app_info(args.app)
    package(args.app.resolve(), args.output, args.architecture,
            args.version or info['CFBundleShortVersionString'],
            args.build_number or info['CFBundleVersion'],
            verify_install=args.verify_install, signing_identity=args.signing_identity,
            app_signing_identity=args.app_signing_identity)


if __name__ == '__main__':
    main()
