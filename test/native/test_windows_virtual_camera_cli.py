"""Exercise the real direct-source CLI without virtual-camera registration APIs.

The temporary helper includes the production source unchanged, intercepting
only platform-support lookup. The actual DLL, COM factory, Media Foundation
source and lifecycle run normally. No camera device is installed or captured.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / 'plugins/virtual-camera'
HARNESS = r'''
#include <windows.h>
#include <cstring>
#include <cwchar>
static unsigned platform_support_queries = 0;
static FARPROC WINAPI WithoutVirtualCameraRegistration(HMODULE module, LPCSTR name) {
  if (std::strcmp(name, "IsWow64Process2") == 0 || std::strcmp(name, "MFCreateVirtualCamera") == 0) {
    ++platform_support_queries;
    return nullptr;
  }
  return GetProcAddress(module, name);
}
#define GetProcAddress WithoutVirtualCameraRegistration
#define wmain ProductionCameraHelperMain
#include "camera_helper.cpp"
#undef wmain
#undef GetProcAddress
int wmain(int argc, wchar_t** argv) {
  const int result = ProductionCameraHelperMain(argc, argv);
  const bool direct = argc > 1 && (std::wcscmp(argv[1], L"--probe-direct") == 0 ||
      std::wcscmp(argv[1], L"--probe-direct-cycle") == 0);
  if (direct && platform_support_queries) return 90;
  if (!direct && !platform_support_queries) return 91;
  return result;
}
'''


@unittest.skipUnless(os.name == 'nt', 'Windows Media Foundation source CLI')
class WindowsVirtualCameraCliTest(unittest.TestCase):
    def test_direct_source_does_not_require_registration_api(self):
        dll = Path(os.environ.get('BSHARE_VIRTUAL_CAMERA_DLL', str(
            ROOT / '.dart_tool/virtual-camera/build/Release/bshare-virtual-camera.dll')))
        self.assertTrue(dll.is_file(), 'Build the native virtual-camera tests first')
        with tempfile.TemporaryDirectory(prefix='bshare-owned-camera-cli-') as temp:
            directory = Path(temp)
            fixture, binary = directory / 'fixture.cpp', directory / 'fixture.exe'
            fixture.write_text(HARNESS)
            arguments = ['/nologo', '/std:c++20', '/W4', '/WX', '/wd4245', '/EHsc', '/utf-8',
                '/DNOMINMAX', '/DUNICODE', '/D_UNICODE', '/DWIN32_LEAN_AND_MEAN',
                f'/I{PLUGIN / "src"}', f'/I{PLUGIN / "include"}', str(fixture),
                f'/Fo{directory}/', f'/Fe{binary}', '/link', 'mf.lib', 'mfplat.lib',
                'mfreadwrite.lib', 'mfuuid.lib', 'mfsensorgroup.lib', 'ole32.lib', 'advapi32.lib']
            compiler = shutil.which('cl')
            if compiler:
                command = [compiler, *arguments]
            else:
                vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
                installation = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
                    capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                script = directory / 'compile.cmd'
                script.write_text('@echo off\ncall "' + str(Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat') +
                    '" >nul\nif errorlevel 1 exit /b %errorlevel%\ncl ' +
                    ' '.join('"' + value + '"' for value in arguments) + '\nexit /b %errorlevel%\n')
                command = ['cmd', '/c', str(script)]
            built = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            status = subprocess.run([str(binary), '--status'], capture_output=True, text=True, timeout=10)
            self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
            self.assertFalse(json.loads(status.stdout)['supported'])
            for option, frames in [('--probe-direct', [2]), ('--probe-direct-cycle', [2, 5, 5])]:
                with self.subTest(command=option):
                    invalid = subprocess.run([str(binary), option], capture_output=True, text=True, timeout=10)
                    self.assertEqual(invalid.returncode, 1, invalid.stdout + invalid.stderr)
                    self.assertIn('80070057', invalid.stderr)
                    executed = subprocess.run([str(binary), option, str(dll), '2'],
                        capture_output=True, text=True, timeout=30)
                    self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
                    results = [json.loads(line) for line in executed.stdout.splitlines() if line.strip()]
                    self.assertEqual([value['frames'] for value in results], frames)
            print('Real CLI: unsupported registration status, direct source and repeated source lifecycle PASS.')


if __name__ == '__main__':
    unittest.main()
