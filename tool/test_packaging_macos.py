import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

import packaging_macos
from packaging_macos import configure_components, configure_distribution, validate_version


class MacosPackagingTest(unittest.TestCase):
    def test_adb_inherits_sandbox_and_outer_bundle_is_sealed_last(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'BShare.app'
            adb_directory = app / 'Contents/MacOS/tools/platform-tools'
            binary = adb_directory / 'adb'
            calls = []

            def run(arguments):
                args = list(map(str, arguments))
                calls.append(args)
                if args[0] != 'codesign':
                    adb_directory.mkdir(parents=True)
                    binary.write_bytes(b'Pinned upstream client fixture')
                    (adb_directory / 'bshare-adb-manifest.json').write_text(
                        '{"revision":"37.0.0","files":{}}')
                elif args[-1] == str(binary):
                    binary.write_bytes(binary.read_bytes() + b' signed for inheritance')
                return ''

            with mock.patch.object(packaging_macos, 'run', side_effect=run):
                report = packaging_macos.stage_usb_adb(app, 'arm64')
            self.assertEqual(calls[0][2:4], ['--platform', 'macos'])
            child_sign, outer_sign = calls[1:]
            self.assertEqual(child_sign[-1], str(binary))
            entitlements = Path(child_sign[child_sign.index('--entitlements') + 1])
            self.assertEqual(plistlib.loads(entitlements.read_bytes()), {
                'com.apple.security.app-sandbox': True,
                'com.apple.security.inherit': True,
            })
            self.assertEqual(outer_sign[-1], str(app))
            self.assertNotIn('--deep', outer_sign)
            self.assertIn('--preserve-metadata=identifier,entitlements,flags,runtime', outer_sign)
            self.assertNotEqual(report['upstreamAdbSha256'], report['signedAdbSha256'])
            self.assertTrue((adb_directory / 'MACOS-CODESIGN.txt').is_file())

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
