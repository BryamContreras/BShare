"""Compile actual Linux IPC/V4L2 ownership contracts; never load a module."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux native virtual-camera contract')
class LinuxVirtualCameraTest(unittest.TestCase):
    def test_transport_waiting_image_and_device_ownership(self):
        compiler = shutil.which('g++')
        if not compiler:
            self.skipTest('A C++17 compiler is required')
        base = ROOT / 'build/linux-virtual-camera-native-tests'
        base.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='case-', dir=base) as directory:
            work = Path(directory).resolve()
            self.assertTrue(work.is_relative_to(base.resolve()))
            source = ROOT / 'plugins/virtual-camera/linux'
            flags = [compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread', f'-I{source}']
            for file, name, extra in [('transport_test.cpp', 'transport-test', []),
                                      ('camera_helper_linux.cpp', 'bshare-camera', ['-ldl'])]:
                result = subprocess.run([*flags, str(source / file), *extra, '-o', str(work / name)],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(work / 'transport-test')], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())
            status = subprocess.run([str(work / 'bshare-camera'), '--status'],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(status.returncode, 0, status.stderr)
            payload = json.loads(status.stdout)
            self.assertTrue(payload['supported'])
            self.assertIn('registered', payload)
            self.assertEqual(payload['deviceName'], 'BShare Virtual Camera')


if __name__ == '__main__':
    unittest.main()
