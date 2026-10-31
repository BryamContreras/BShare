"""Build/run the optional silent Windows media-session duck-notification probe."""
import argparse
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--self-test', action='store_true')
parser.add_argument('--self-test-opt-out', action='store_true')
parser.add_argument('--calibration', choices=['legacy-comms', 'legacy-explicit', 'legacy-cached', 'explicit-communication'])
parser.add_argument('--build-only', action='store_true')
args = parser.parse_args()
if os.name != 'nt': raise SystemExit('Windows required')
build = ROOT / '.dart_tool/audio-ducking/probe'
build.mkdir(parents=True, exist_ok=True)
source = ROOT / 'tool/windows_audio_duck_probe.cpp'
binary = build / 'audio-duck-probe.exe'
if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    installation = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
        capture_output=True, text=True, check=True, timeout=20).stdout.strip()
    vcvars = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
    options = ['/nologo', '/std:c++17', '/W4', '/WX', '/wd4100', '/EHsc',
        '/DNOMINMAX', str(source), f'/Fo{build / "probe.obj"}', f'/Fe{binary}',
        '/link', 'ole32.lib', 'uuid.lib', 'mmdevapi.lib']
    script = build / 'compile.cmd'
    script.write_text('@echo off\ncall "' + str(vcvars) + '" >nul\n'
        'if errorlevel 1 exit /b %errorlevel%\ncl ' +
        ' '.join('"' + value + '"' for value in options) + '\nexit /b %errorlevel%\n')
    compiled = subprocess.run(['cmd', '/c', str(script)], cwd=build,
        capture_output=True, text=True, timeout=60)
    if compiled.returncode: raise SystemExit(compiled.stdout + compiled.stderr)
if args.build_only: print(binary)
else:
    command = [str(binary), str(args.seconds)]
    if args.calibration: command.append('--self-test-' + args.calibration)
    elif args.self_test_opt_out: command.append('--self-test-optout')
    elif args.self_test: command.append('--self-test')
    raise SystemExit(subprocess.call(command))
