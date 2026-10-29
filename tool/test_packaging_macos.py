import plistlib
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from packaging_macos import configure_components, configure_distribution, validate_version


class MacosPackagingTest(unittest.TestCase):
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
