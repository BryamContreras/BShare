#!/usr/bin/env python3
"""Exercise native desktop capture/encode against a real browser receiver.

Build tool/webrtc_native_probe.dart explicitly, then pass that binary here.
Linux always starts its own Xvfb; Windows requires --isolated-desktop and the
GitHub Actions hosted-runner environment. No user's desktop is captured. Video
and audio frames are never written; evidence consists of WebRTC statistics.

Example (Windows hosted runner):
  python tool/webrtc_native_sender_probe.py --isolated-desktop \
      --binary build/windows/x64/runner/Release/bshare.exe --output sender.json

Example (Linux with Xvfb installed):
  python3 tool/webrtc_native_sender_probe.py \
      --binary build/linux/x64/release/bundle/bshare --output sender.json
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

from webrtc_interop_probe import close_native_window, find_browser, stop_process
from webrtc_receive_probe import main as receive_media


def json_request(url, data=None, timeout=5):
    request = urllib.request.Request(url,
        data=None if data is None else json.dumps(data).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def unused_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def port_closed(port):
    if port is None:
        return True
    with socket.socket() as connection:
        connection.settimeout(1)
        return connection.connect_ex(('127.0.0.1', port)) != 0


def maximize_owned_windows(pid):
    """Fill the isolated hosted Windows desktop with the synthetic pattern."""
    if os.name != 'nt':
        return
    from ctypes import wintypes
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]

    @callback_type
    def maximize(window, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
        if owner.value == pid:
            user32.ShowWindow(window, 3)  # SW_MAXIMIZE
        return True

    user32.EnumWindows(maximize, 0)


def launch_xvfb(executable, output, env):
    import select
    read_fd, write_fd = os.pipe()
    display = None
    try:
        display = subprocess.Popen([executable, '-displayfd', str(write_fd),
            '-screen', '0', '1280x720x24', '-nolisten', 'tcp', '-noreset', '-ac'],
            pass_fds=(write_fd,), stdout=output, stderr=subprocess.STDOUT, env=env)
        os.close(write_fd)
        write_fd = None
        # Xorg may write the digits and newline separately. Keep the read end
        # open until the complete line arrives; closing after the digits can
        # give Xvfb EPIPE and terminate a display that looked ready.
        line = b''
        deadline = time.monotonic() + 15
        while b'\n' not in line:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([read_fd], [], [], remaining)[0]:
                raise RuntimeError('Xvfb did not allocate an isolated display')
            chunk = os.read(read_fd, 100)
            if not chunk:
                raise RuntimeError('Xvfb closed its startup pipe before readiness')
            line += chunk
        number = line.decode().strip()
        if not number.isdigit():
            raise RuntimeError(f'Xvfb display startup failed: {number!r}')
        return display, f':{number}'
    except BaseException:
        if display is not None and display.poll() is None:
            display.terminate()
            stop_process(display, timeout=5)
        raise
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True,
        help='Binary compiled with --target tool/webrtc_native_probe.dart')
    parser.add_argument('--browser', default=find_browser())
    parser.add_argument('--xvfb', default=shutil.which('Xvfb'))
    parser.add_argument('--isolated-desktop', action='store_true')
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    if not options.binary.is_file() or not options.browser:
        parser.error('A built diagnostic binary and Chrome/Chromium/Brave are required')
    if options.seconds < 3 or options.seconds > 60:
        parser.error('--seconds must be between 3 and 60')
    if os.name == 'nt':
        if not options.isolated_desktop or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
            parser.error('Windows capture requires --isolated-desktop on a GitHub hosted runner')
    elif platform.system() != 'Linux' or not options.xvfb:
        parser.error('Linux capture requires Xvfb; the existing user display is never used')
    binary = options.binary.resolve()
    aot = binary.parent / ('data/app.so' if os.name == 'nt' else 'lib/libapp.so')
    report = {'scope': 'Native desktop capture and encoder to browser decoder; isolated desktop',
        'platform': platform.system(), 'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'aotSha256': hashlib.sha256(aot.read_bytes()).hexdigest(), 'cases': [], 'passed': False}
    native = display = None
    source_port = None
    control_port = unused_port()
    control_origin = f'http://127.0.0.1:{control_port}'
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='bshare-native-sender-') as directory:
        temp = Path(directory)
        env = dict(os.environ)
        for key, name in [('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config')]:
            path = temp / name
            path.mkdir()
            env[key] = str(path)
        native_log = temp / 'native.log'
        display_log = temp / 'display.log'
        with native_log.open('w') as native_output, display_log.open('w') as display_output:
            try:
                if os.name != 'nt':
                    display, number = launch_xvfb(options.xvfb, display_output, env)
                    env.update(DISPLAY=number, GDK_BACKEND='x11', XDG_SESSION_TYPE='x11',
                        LIBGL_ALWAYS_SOFTWARE='1')
                    env.pop('WAYLAND_DISPLAY', None)
                    report['display'] = 'owned Xvfb 1280x720x24'
                else:
                    report['display'] = 'GitHub hosted Windows runner'
                native = subprocess.Popen([str(binary), '--probe-mode', 'sender',
                    '--probe-control-port', str(control_port), '--probe-port', str(unused_port()),
                    '--probe-seconds', str(int(options.seconds * 3 + 150))],
                    stdout=native_output, stderr=subprocess.STDOUT, env=env)
                deadline = time.monotonic() + 40
                initial = None
                while time.monotonic() < deadline:
                    if native.poll() is not None:
                        raise RuntimeError(f'Native sender exited during startup: {native.returncode}')
                    try:
                        initial = json_request(f'{control_origin}/status', timeout=2)
                        if initial.get('ready') and initial.get('sourcePort'):
                            break
                    except (OSError, ValueError):
                        pass
                    time.sleep(.2)
                if not initial or not initial.get('ready'):
                    raise RuntimeError('Native sender did not finish capture startup')
                source_port = initial['sourcePort']
                maximize_owned_windows(native.pid)
                source_origin = f'http://127.0.0.1:{source_port}'
                initial_metadata = json_request(f'{source_origin}/api/screen/metadata')['metadata']
                report['initialStatus'] = initial
                report['initialMetadata'] = initial_metadata
                print(json.dumps({'event': 'READY', 'sourcePort': source_port, 'controlPort': control_port}), flush=True)
                for index, (codec, compatibility) in enumerate([('H264', False), ('VP8', False), ('VP8', True)]):
                    result_path = temp / f'case-{index}.json'
                    arguments = ['--source', source_origin, '--kind', 'screen', '--codec', codec,
                        '--seconds', str(options.seconds), '--browser', options.browser,
                        '--require-continuous', '--verify-synthetic-pattern',
                        '--output', str(result_path)]
                    if compatibility:
                        arguments.append('--compatibility')
                    # Run the bounded receiver in this process so its finally
                    # cleanup cannot be bypassed by killing an intermediate
                    # Python subprocess with a still-running browser child.
                    receiver_exit_code = receive_media(arguments)
                    if not result_path.is_file():
                        raise RuntimeError('Browser receiver did not produce a report')
                    result = json.loads(result_path.read_text())
                    result['probeExitCode'] = receiver_exit_code
                    result['sourceStillActive'] = json_request(f'{source_origin}/api/screen/metadata')['metadata']['generation'] == initial_metadata['generation']
                    if compatibility:
                        received = [event for event in result['events'] if event['event'] == 'stats' and event.get('framesDecoded', 0) > 0]
                        result['compatibilitySizeWithinLimit'] = bool(received) and all(
                            max(event.get('frameWidth', 0), event.get('frameHeight', 0)) <= 1280 and
                            min(event.get('frameWidth', 0), event.get('frameHeight', 0)) <= 720 for event in received)
                    result['passed'] = result['passed'] and receiver_exit_code == 0 and result['sourceStillActive'] and result.get('remoteViewerStopStatus') == 200 and result.get('compatibilitySizeWithinLimit', True)
                    report['cases'].append(result)
                    print(json.dumps({key: value for key, value in result.items() if key != 'events'}), flush=True)
                report['passed'] = all(case['passed'] for case in report['cases'])
            except Exception as error:
                report['error'] = str(error)
            finally:
                try:
                    report['cleanupResponse'] = json_request(f'{control_origin}/stop', {}, timeout=20)
                except (OSError, ValueError) as error:
                    report['cleanupError'] = str(error)
                report['nativeCloseRequested'] = native is not None and close_native_window(native.pid)
                report['nativeExitCode'] = stop_process(native, timeout=20)
                report['sourcePortClosed'] = port_closed(source_port)
                report['controlPortClosed'] = port_closed(control_port)
                if display is not None and display.poll() is None:
                    display.terminate()
                report['displayExitCode'] = stop_process(display, timeout=5)
        report['nativeLog'] = native_log.read_text(errors='replace')
        report['displayLog'] = display_log.read_text(errors='replace')
        report['cleanupPassed'] = (report.get('cleanupResponse', {}).get('cleanupComplete') is True and
            report['nativeCloseRequested'] and report['nativeExitCode'] == 0 and
            report['sourcePortClosed'] and report['controlPortClosed'] and
            (display is None or display.poll() is not None))
        report['passed'] = report['passed'] and report['cleanupPassed']
    report['temporaryProfileRemoved'] = not temp.exists()
    report['durationSeconds'] = round(time.monotonic() - started, 2)
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key not in ['nativeLog', 'displayLog', 'cases']}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
