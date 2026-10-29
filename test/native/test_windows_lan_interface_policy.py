"""Compile and execute the production Windows LAN classifier on any desktop.

Run: python test/native/test_windows_lan_interface_policy.py
Requires MSVC (including a standard Build Tools installation) on Windows, or
clang++/g++ on Linux/macOS. No Flutter engine, devices or network are required.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'test/native/windows_lan_interface_policy_test.cpp'


def compile_fixture(directory, source=SOURCE):
    binary = directory / (source.stem + ('.exe' if os.name == 'nt' else ''))
    if os.name == 'nt':
        arguments = [
            '/nologo', '/std:c++17', '/W4', '/WX', '/EHsc',
            f'/I{ROOT}', str(source),
            f'/Fo{directory / "lan_policy.obj"}', f'/Fe{binary}',
        ]
        compiler = shutil.which('cl')
        if compiler:
            command = [compiler, *arguments]
        else:
            vswhere = Path(os.environ.get('ProgramFiles(x86)', '')) / (
                'Microsoft Visual Studio/Installer/vswhere.exe')
            if not vswhere.is_file():
                raise unittest.SkipTest('MSVC or Visual Studio Build Tools required')
            installation = subprocess.run([
                str(vswhere), '-latest', '-products', '*',
                '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                '-property', 'installationPath',
            ], check=True, capture_output=True, text=True, timeout=20).stdout.strip()
            vcvars = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
            if not installation or not vcvars.is_file():
                raise unittest.SkipTest('MSVC x64 build tools required')
            script = directory / 'compile.cmd'
            # Every path/argument is quoted; none is taken from test input.
            options = ' '.join(f'"{value}"' for value in arguments)
            script.write_text(
                f'@echo off\ncall "{vcvars}" >nul\n'
                f'if errorlevel 1 exit /b %errorlevel%\n'
                f'cl {options}\nexit /b %errorlevel%\n', encoding='utf-8')
            command = [os.environ.get('ComSpec', 'cmd.exe'), '/d', '/c', str(script)]
    else:
        compiler = shutil.which('clang++') or shutil.which('g++')
        if not compiler:
            raise unittest.SkipTest('clang++ or g++ required')
        command = [compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                   '-pedantic', '-I', str(ROOT), str(source), '-o', str(binary)]
    compilation = subprocess.run(command, cwd=directory, capture_output=True,
                                 text=True, timeout=90)
    if compilation.returncode:
        raise AssertionError(compilation.stdout + compilation.stderr)
    return binary


class WindowsLanPolicyTest(unittest.TestCase):
    def test_native_adapter_fixtures(self):
        with tempfile.TemporaryDirectory(prefix='bshare-lan-policy-') as temporary:
            directory = Path(temporary)
            binary = compile_fixture(directory)
            result = subprocess.run([str(binary)], cwd=directory, capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('24 native LAN classification fixtures passed', result.stdout)
            print(result.stdout.strip())

    def test_native_default_route_priority(self):
        with tempfile.TemporaryDirectory(prefix='bshare-route-policy-') as temporary:
            directory = Path(temporary)
            source = ROOT / 'test/native/windows_route_metric_policy_test.cpp'
            binary = compile_fixture(directory, source)
            result = subprocess.run([str(binary)], cwd=directory, capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Native Windows default-route priority scenarios passed', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
