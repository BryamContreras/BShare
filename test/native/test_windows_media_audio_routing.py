"""Compile actual Windows multimedia routing with an isolated SDK test double.

Reads the real OS default output; never opens audio, changes volume or settings.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(os.name == 'nt', 'Windows Core Audio contract')
class MediaAudioRoutingTest(unittest.TestCase):
    def test_multimedia_identity_and_explicit_selection(self):
        with tempfile.TemporaryDirectory(prefix='bshare-media-routing-') as directory:
            directory = Path(directory)
            binary = directory / 'routing.exe'
            arguments = ['/nologo', '/std:c++17', '/W4', '/WX', '/wd4100', '/EHsc',
                '/D_WINDOWS', '/DLIB_WEBRTC_API_DLL', '/DNOMINMAX',
                f'/I{ROOT}', f'/I{ROOT / "third_party/flutter_webrtc/third_party/libwebrtc/include"}',
                str(ROOT / 'test/native/windows_media_audio_routing_test.cpp'),
                f'/Fo{directory / "routing.obj"}', f'/Fe{binary}',
                '/link', 'ole32.lib', 'uuid.lib', 'mmdevapi.lib']
            compiler = shutil.which('cl')
            if compiler:
                command = [compiler, *arguments]
            else:
                vswhere = Path(os.environ.get('ProgramFiles(x86)', '')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
                if not vswhere.is_file(): self.skipTest('MSVC C++ tools required')
                installation = subprocess.run([str(vswhere), '-latest', '-products', '*',
                    '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                    '-property', 'installationPath'], capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                vcvars = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
                if not vcvars.is_file(): self.skipTest('MSVC x64 compiler required')
                script = directory / 'compile.cmd'
                script.write_text('@echo off\ncall "' + str(vcvars) + '" >nul\n'
                    'if errorlevel 1 exit /b %errorlevel%\ncl ' +
                    ' '.join('"' + value + '"' for value in arguments) + '\nexit /b %errorlevel%\n')
                command = ['cmd', '/c', str(script)]
            built = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            print(executed.stdout.strip())

if __name__ == '__main__': unittest.main()
