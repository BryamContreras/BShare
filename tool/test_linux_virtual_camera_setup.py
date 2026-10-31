"""Exercise production Linux installer decisions without loading kernel modules."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux installer setup')
class LinuxVirtualCameraSetupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[1] / 'plugins/virtual-camera/linux/setup.py'
        spec = importlib.util.spec_from_file_location('bshare_linux_camera_setup', source)
        cls.setup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.setup)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='bshare-camera-setup-')
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.module = root / 'module'
        self.devices = root / 'dev'
        self.classes = root / 'class'
        self.headers = root / 'headers'
        self.devices.mkdir()
        self.classes.mkdir()
        for name, value in [('MODULE', self.module), ('DEVICE_ROOT', self.devices),
                            ('DEVICE_CLASS', self.classes), ('KERNEL_HEADERS', self.headers)]:
            active = patch.object(self.setup, name, value)
            active.start()
            self.addCleanup(active.stop)
        self.calls = []
        self.modern_tool = False
        self.version = '0.12.5'
        self.load_error = None
        self.add_error = False
        self.claims = True
        self.existing = None
        for name, value in [('run', self.command), ('find_owned', lambda: self.existing),
                            ('owned_device', lambda _candidate: self.claims)]:
            active = patch.object(self.setup, name, value)
            active.start()
            self.addCleanup(active.stop)

    def command(self, arguments, **_kwargs):
        arguments = list(map(str, arguments))
        self.calls.append(arguments)
        result = subprocess.CompletedProcess(arguments, 0, '', '')
        if arguments[:2] == ['v4l2loopback-ctl', '--help']:
            result.stdout = ('add {<flags>} [<outputdevice> [<capturedevice>]]'
                             if self.modern_tool else 'set-fps <FPS> /dev/videoX')
        elif arguments[:2] == ['modinfo', '-F']:
            result.stdout = self.version
        elif arguments[0] == 'modprobe' and self.load_error:
            result.returncode, result.stderr = self.load_error
        elif arguments[:2] == ['v4l2loopback-ctl', 'add'] and self.add_error:
            result.returncode = 1
        return result

    def loaded(self, version):
        self.module.mkdir()
        (self.module / 'version').write_text(version)

    def mutations(self):
        return [call for call in self.calls if call[0] in ['modprobe', 'rmmod'] or
                (call[0] == 'v4l2loopback-ctl' and call[1] in ['add', 'delete'])]

    def test_reuse_owned_device_without_touching_driver(self):
        self.existing = self.devices / 'video42'
        result = self.setup.ensure_device()
        self.assertTrue(result['ready'])
        self.assertEqual(result['device'], str(self.existing))
        self.assertEqual(self.calls, [])

    def test_jammy_legacy_loads_one_named_device_and_no_empty_module(self):
        result = self.setup.ensure_device()
        self.assertTrue(result['ready'])
        self.assertEqual(self.mutations(), [[
            'modprobe', 'v4l2loopback', 'devices=1', 'video_nr=63',
            'card_label=BShare Virtual Camera', 'exclusive_caps=1',
            'max_width=1280', 'max_height=720', 'max_buffers=2']])

    def test_legacy_loaded_for_obs_is_left_untouched(self):
        self.loaded('0.12.5')
        self.modern_tool = True  # A newer tool cannot upgrade a loaded kernel API.
        result = self.setup.ensure_device()
        self.assertEqual(result, {'ready': False, 'reason': 'unsupported-driver-version'})
        self.assertEqual(self.mutations(), [])

    def test_modern_empty_load_then_dynamic_add_skips_occupied_numbers(self):
        self.modern_tool, self.version = True, '0.13.2'
        (self.devices / 'video63').touch()
        (self.classes / 'video62').mkdir()
        result = self.setup.ensure_device()
        self.assertTrue(result['ready'])
        mutations = self.mutations()
        self.assertEqual(mutations[0], ['modprobe', 'v4l2loopback', 'devices=0'])
        self.assertEqual(mutations[1], [
            'v4l2loopback-ctl', 'add', '-n', 'BShare Virtual Camera', '-x', '1',
            '-w', '1280', '-h', '720', '-b', '2', str(self.devices / 'video61')])

    def test_modern_loaded_module_adds_without_reload(self):
        self.loaded('0.14.0')
        self.modern_tool = True
        self.assertTrue(self.setup.ensure_device()['ready'])
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual(self.mutations()[0][:2], ['v4l2loopback-ctl', 'add'])

    def test_dynamic_failure_does_not_retry_every_free_device(self):
        self.loaded('0.13.0')
        self.modern_tool = self.add_error = True
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-device-creation-failed')
        self.assertEqual(len(self.mutations()), 1)

    def test_wrong_driver_or_label_never_reports_success(self):
        self.claims = False
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-device-verification-failed')

    def test_signature_and_headers_failures_remain_visible(self):
        self.load_error = (1, 'modprobe: ERROR: Key was rejected by service')
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-signature-rejected')
        self.load_error = (1, 'modprobe: FATAL: module not found')
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-headers-unavailable')
        self.headers.mkdir()
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-module-unavailable')

    def test_no_free_device_does_not_load_module(self):
        for number in range(32, 64):
            (self.devices / f'video{number}').touch()
        self.assertEqual(self.setup.ensure_device()['reason'], 'kernel-device-creation-failed')
        self.assertEqual(self.mutations(), [])

    def test_removal_only_deletes_verified_device_with_dynamic_api(self):
        self.existing = self.devices / 'video42'
        self.loaded('0.13.2')
        self.modern_tool = True
        with patch.object(self.setup.os, 'geteuid', return_value=0), \
                patch.object(self.setup, 'user_services'):
            self.setup.configure('remove')
        self.assertEqual(self.mutations(), [[
            'v4l2loopback-ctl', 'delete', str(self.existing)]])
        self.calls.clear()
        self.modern_tool = False
        with patch.object(self.setup.os, 'geteuid', return_value=0), \
                patch.object(self.setup, 'user_services'):
            self.setup.configure('remove')
        self.assertEqual(self.mutations(), [])


if __name__ == '__main__':
    unittest.main()
