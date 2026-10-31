import plistlib
import contextlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import platform
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

import packaging_macos
from packaging_macos import configure_components, configure_distribution, validate_version


class MacosPackagingTest(unittest.TestCase):
    def test_native_tool_failure_retains_stdout_stderr_and_original_error(self):
        failure = subprocess.CalledProcessError(1, ['codesign'],
            output='Signing bundle\n', stderr='In subcomponent: invalid nested bundle\n')
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(packaging_macos.subprocess, 'run', side_effect=failure), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                packaging_macos.run(['codesign', '--verify', 'fixture.app'])
        self.assertIs(raised.exception, failure)
        self.assertIn('Signing bundle', stdout.getvalue())
        self.assertIn('invalid nested bundle', stderr.getvalue())

    def test_adb_inherits_sandbox_and_outer_bundle_is_sealed_last(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'BShare.app'
            adb_directory = app / packaging_macos.ADB_RESOURCES
            binary = app / packaging_macos.ADB_EXECUTABLE
            calls = []

            def run(arguments):
                args = list(map(str, arguments))
                calls.append(args)
                if args[0] != 'codesign':
                    prepared = Path(args[args.index('--destination') + 1])
                    prepared.mkdir(parents=True)
                    (prepared / 'adb').write_bytes(b'Pinned upstream client fixture')
                    (prepared / 'NOTICE.txt').write_text('Complete upstream notice fixture')
                    (prepared / 'bshare-adb-manifest.json').write_text(
                        '{"revision":"37.0.0","files":{}}')
                elif '--sign' in args and args[-1] == str(binary):
                    binary.write_bytes(binary.read_bytes() + b' signed for inheritance')
                return ''

            with mock.patch.object(packaging_macos, 'run', side_effect=run):
                report = packaging_macos.stage_usb_adb(app, 'arm64')
            self.assertEqual(calls[0][2:4], ['--platform', 'macos'])
            child_sign, child_verify, outer_sign = calls[1:]
            self.assertEqual(child_sign[-1], str(binary))
            entitlements = Path(child_sign[child_sign.index('--entitlements') + 1])
            self.assertEqual(plistlib.loads(entitlements.read_bytes()), {
                'com.apple.security.app-sandbox': True,
                'com.apple.security.inherit': True,
            })
            self.assertEqual(outer_sign[-1], str(app))
            self.assertEqual(child_verify, ['codesign', '--verify', '--strict', str(binary)])
            self.assertNotIn('--deep', outer_sign)
            self.assertIn('--preserve-metadata=identifier,entitlements,flags,runtime', outer_sign)
            self.assertNotEqual(report['upstreamAdbSha256'], report['signedAdbSha256'])
            self.assertTrue((adb_directory / 'MACOS-CODESIGN.txt').is_file())
            self.assertTrue((adb_directory / 'NOTICE.txt').is_file())
            self.assertFalse((adb_directory / 'adb').exists())
            self.assertEqual(report['executable'], 'Contents/MacOS/adb')
            record = json.loads((adb_directory / 'bshare-adb-manifest.json').read_text())
            self.assertEqual(record['files']['adb']['bundlePath'], 'Contents/MacOS/adb')

    @unittest.skipUnless(platform.system() == 'Darwin', 'Native macOS codesign contract')
    def test_real_adb_layout_is_inside_out_signed_and_strictly_verified(self):
        with tempfile.TemporaryDirectory(prefix='bshare-macos-codesign-') as directory:
            app = Path(directory) / 'BShare.app'
            executable = app / 'Contents/MacOS/bshare'
            executable.parent.mkdir(parents=True)
            source = Path(directory) / 'fixture.c'
            source.write_text('int main(void) { return 0; }\n')
            packaging_macos.run(['clang', str(source), '-o', executable])
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.bshare.codesign-fixture',
                'CFBundleExecutable': 'bshare', 'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': '1.0.5', 'CFBundleVersion': '1',
            }))
            packaging_macos.run(['codesign', '--force', '--sign', '-', '--entitlements',
                packaging_macos.ROOT / 'macos/Runner/Release.entitlements', app])
            architecture = 'arm64' if platform.machine() == 'arm64' else 'x64'
            packaging_macos.verify_app(app, architecture, '1.0.5', '1')
            report = packaging_macos.stage_usb_adb(app, architecture)
            packaging_macos.verify_app(app, architecture, '1.0.5', '1')
            child = app / packaging_macos.ADB_EXECUTABLE
            packaging_macos.run(['codesign', '--verify', '--strict', child])
            entitlements = packaging_macos.run(['codesign', '--display', '--entitlements', ':-', child])
            self.assertEqual(plistlib.loads(entitlements.encode()), {
                'com.apple.security.app-sandbox': True,
                'com.apple.security.inherit': True,
            })
            self.assertEqual(sorted(path.name for path in executable.parent.iterdir()), ['adb', 'bshare'])
            resources = app / packaging_macos.ADB_RESOURCES
            self.assertTrue((resources / 'NOTICE.txt').is_file())
            self.assertTrue((resources / 'LICENSE.adb.txt').is_file())
            self.assertFalse((resources / 'adb').exists())
            self.assertEqual(report['executable'], 'Contents/MacOS/adb')

    def test_installer_version_tracks_same_version_rebuilds(self):
        self.assertEqual(validate_version('1.0.4', '42'), '1.0.4.42')
        for version, build in [('v1.0.4', '42'), ('1.0.4;bad', '42'), ('1.0.4', '0'), ('1.0.4', '65536')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                validate_version(version, build)

    def test_application_cannot_relocate_to_an_arbitrary_old_install(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'components.plist'
            path.write_bytes(plistlib.dumps([{'RootRelativeBundlePath': 'Applications/BShare.app',
                                              'BundleIsRelocatable': True}]))
            configure_components(path)
            component = plistlib.loads(path.read_bytes())[0]
            self.assertFalse(component['BundleIsRelocatable'])
            self.assertEqual(component['BundleOverwriteAction'], 'upgrade')
            path.write_bytes(plistlib.dumps([{'RootRelativeBundlePath': 'Library/Wrong.app'}]))
            with self.assertRaisesRegex(ValueError, 'exactly Applications'):
                configure_components(path)

    def test_distribution_limits_architecture_os_and_install_domain(self):
        for label, expected in [('arm64', 'arm64'), ('x64', 'x86_64')]:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'Distribution.xml'
                path.write_text('<installer-gui-script minSpecVersion="2"><options customize="allow"/></installer-gui-script>')
                configure_distribution(path, label, '1.0.4', '13.0')
                root = ET.parse(path).getroot()
                self.assertEqual(root.findtext('title'), 'BShare v1.0.4')
                self.assertEqual(root.find('options').get('hostArchitectures'), expected)
                self.assertEqual(root.find('options').get('customize'), 'never')
                self.assertEqual(root.find('domains').get('enable_currentUserHome'), 'false')
                self.assertEqual(root.find('volume-check/allowed-os-versions/os-version').get('min'), '13.0')


if __name__ == '__main__':
    unittest.main()
