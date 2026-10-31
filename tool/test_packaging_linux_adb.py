from pathlib import Path
import tempfile
import unittest
from unittest import mock

import packaging_linux


class LinuxAdbPackagingTest(unittest.TestCase):
    def test_rpm_requires_real_h264_encoder_and_declares_media_backends(self):
        self.assertIn('openh264', packaging_linux.RPM_DYNAMIC_DEPENDENCIES)
        self.assertIn('gstreamer1-plugin-openh264', packaging_linux.RPM_DYNAMIC_DEPENDENCIES)
        self.assertIn('gstreamer1-plugins-bad-free', packaging_linux.RPM_DYNAMIC_DEPENDENCIES)
        self.assertIn('gstreamer1.0-plugins-bad', packaging_linux.DEB_DYNAMIC_DEPENDENCIES)

    def test_adb_is_checked_as_an_elf_but_not_patched(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            bundle, stage = work / 'bundle', work / 'stage'
            files = ['bshare', 'bshare-camera', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
                     'lib/libapp.so', 'lib/libflutter_linux_gtk.so',
                     'lib/libflutter_webrtc_plugin.so', 'lib/libwebrtc.so']
            for name in files:
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'\x7fELFfixture' if name in ['bshare', 'bshare-camera'] or name.endswith('.so') else b'asset')
            adb = stage / 'opt/bshare/tools/platform-tools/adb'
            calls = []

            def run(arguments):
                args = list(map(str, arguments))
                calls.append(args)
                if len(args) > 1 and args[1].endswith('prepare_adb.py'):
                    adb.parent.mkdir(parents=True)
                    adb.write_bytes(b'\x7fELFpinned ADB fixture')
                if args[0] == 'readelf':
                    return 'Machine: Advanced Micro Devices X86-64'
                return ''

            with mock.patch.object(packaging_linux, 'run', side_effect=run):
                checked = packaging_linux.stage_bundle(bundle, stage)
            self.assertIn(adb, checked)
            self.assertIn(['ldd', str(adb)], calls)
            patched = [call[-1] for call in calls if call[0] == 'patchelf']
            self.assertTrue(patched)
            self.assertNotIn(str(adb), patched)
            self.assertTrue((stage / 'usr/lib/udev/rules.d/70-bshare-adb.rules').is_file())
            self.assertTrue((stage / 'usr/lib/systemd/user/bshare-virtual-camera.service').is_file())
            self.assertTrue((stage / 'usr/lib/systemd/system/bshare-virtual-camera-setup.service').is_file())
            self.assertEqual(adb.read_bytes(), b'\x7fELFpinned ADB fixture')


if __name__ == '__main__':
    unittest.main()
