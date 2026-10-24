#!/usr/bin/env python3
"""Exercise a built Linux/Windows BShare viewer against browser H264/VP8 media.

Usage:
  python3 tool/webrtc_interop_probe.py --output .dart_tool/interop.json

Requires Windows or an X11/XWayland display, and Chrome/Chromium/Brave. The native application uses
its production viewer, signaling, WebRTC decoder and video renderer. Media is a
synthetic canvas sent over the local network stack. This does not substitute for
physical Windows/Android, camera capture, LAN discovery or router/firewall tests.
No third-party Python packages are required. Each owned process has a deadline;
the fixture requests graceful WebRTC and application cleanup before termination.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def close_native_window(pid: int) -> bool:
    if os.name != 'nt':
        return close_x11_window(pid)
    from ctypes import wintypes
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    sent = False

    @callback_type
    def close(window, _):
        nonlocal sent
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
        if owner.value == pid:
            sent = bool(user32.PostMessageW(window, 0x0010, 0, 0)) or sent
        return True

    user32.EnumWindows(close, 0)
    return sent


def find_browser():
    for name in ['brave-browser', 'chromium', 'chromium-browser', 'google-chrome', 'chrome', 'msedge']:
        found = shutil.which(name)
        if found:
            return found
    for variable in ['PROGRAMFILES', 'PROGRAMFILES(X86)', 'LOCALAPPDATA']:
        for name in ['Google/Chrome/Application/chrome.exe', 'Microsoft/Edge/Application/msedge.exe']:
            found = Path(os.environ.get(variable, '')) / name
            if found.is_file():
                return str(found)
    return None


def close_x11_window(pid: int) -> bool:
    """Request WM_DELETE_WINDOW only for windows owned by the fixture PID."""
    c = ctypes
    library = ctypes.util.find_library('X11')
    if not library:
        return False
    x = c.CDLL(library)
    display_type, window_type = c.c_void_p, c.c_ulong
    x.XOpenDisplay.argtypes = [c.c_char_p]
    x.XOpenDisplay.restype = display_type
    display = x.XOpenDisplay(None)
    if not display:
        return False
    x.XDefaultRootWindow.argtypes = [display_type]
    x.XDefaultRootWindow.restype = window_type
    x.XInternAtom.argtypes = [display_type, c.c_char_p, c.c_int]
    x.XInternAtom.restype = window_type
    x.XGetWindowProperty.argtypes = [display_type, window_type, window_type,
        c.c_long, c.c_long, c.c_int, window_type, c.POINTER(window_type),
        c.POINTER(c.c_int), c.POINTER(window_type), c.POINTER(window_type),
        c.POINTER(c.POINTER(c.c_ubyte))]
    x.XFree.argtypes = [c.c_void_p]
    x.XCloseDisplay.argtypes = [display_type]
    x.XFlush.argtypes = [display_type]
    x.XQueryTree.argtypes = [display_type, window_type, ctypes.POINTER(window_type),
        ctypes.POINTER(window_type), ctypes.POINTER(ctypes.POINTER(window_type)), ctypes.POINTER(ctypes.c_uint)]

    def atom(name):
        return x.XInternAtom(display, name.encode(), 0)

    def property_values(window, name):
        kind, count, remaining, format_bits = window_type(), window_type(), window_type(), c.c_int()
        value = c.POINTER(c.c_ubyte)()
        x.XGetWindowProperty(display, window, atom(name), 0, 65536, 0, 0,
            c.byref(kind), c.byref(format_bits), c.byref(count), c.byref(remaining), c.byref(value))
        if not value:
            return []
        try:
            return list(c.cast(value, c.POINTER(window_type * count.value)).contents) if format_bits.value == 32 else []
        finally:
            x.XFree(value)

    class MessageData(c.Union):
        _fields_ = [('b', c.c_char * 20), ('s', c.c_short * 10), ('l', c.c_long * 5)]

    class Message(c.Structure):
        _fields_ = [('type', c.c_int), ('serial', window_type), ('send_event', c.c_int),
            ('display', display_type), ('window', window_type), ('message_type', window_type),
            ('format', c.c_int), ('data', MessageData)]

    class Event(c.Union):
        _fields_ = [('message', Message), ('padding', c.c_long * 24)]

    x.XSendEvent.argtypes = [display_type, window_type, c.c_int, c.c_long, c.POINTER(Event)]
    try:
        sent = False
        root = x.XDefaultRootWindow(display)
        windows = property_values(root, '_NET_CLIENT_LIST')
        if not windows:
            # CI can use bare Xvfb without a window manager. GTK still handles
            # WM_DELETE_WINDOW directly, but _NET_CLIENT_LIST is absent there.
            returned_root, parent, count = window_type(), window_type(), c.c_uint()
            children = c.POINTER(window_type)()
            if x.XQueryTree(display, root, c.byref(returned_root), c.byref(parent), c.byref(children), c.byref(count)):
                try:
                    windows = list(children[:count.value])
                finally:
                    if children:
                        x.XFree(children)
        for window in windows:
            if pid not in property_values(window, '_NET_WM_PID'):
                continue
            event = Event()
            event.message.type = 33
            event.message.display = display
            event.message.window = window
            event.message.message_type = atom('WM_PROTOCOLS')
            event.message.format = 32
            event.message.data.l[0] = atom('WM_DELETE_WINDOW')
            x.XSendEvent(display, window, 0, 0, c.byref(event))
            sent = True
        x.XFlush(display)
        return sent
    finally:
        x.XCloseDisplay(display)


def stop_process(process, timeout=10):
    if process is None:
        return None
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            return process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait(timeout=5)


class Fixture:
    def __init__(self, codec, stall_first, stall_all, source_url=None, audio=False,
                 compatibility=False, viewer_id=None, verify_synthetic_pattern=False):
        self.codec = codec
        self.stall_first = stall_first
        self.stall_all = stall_all
        self.source_url = source_url
        self.audio = audio
        self.compatibility = compatibility
        self.viewer_id = viewer_id
        self.verify_synthetic_pattern = verify_synthetic_pattern
        self.current_viewer_id = None
        self.jobs = queue.Queue()
        self.answers = {}
        self.reports = []
        self.ready = threading.Event()
        self.stopped = threading.Event()
        self.offer_count = 0
        self.offers = []
        self.metadata_count = 0
        self.lock = threading.Lock()

    def stop(self):
        self.stopped.set()
        # Release any in-flight offer handler if a native/browser failure ended
        # a case before signaling completed. Do not leave daemon workers waiting
        # for their normal 15-second answer deadline after cleanup returns.
        with self.lock:
            pending = list(self.answers.values())
        for result in pending:
            try:
                result.put_nowait({'error': 'fixture-stopped'})
            except queue.Full:
                pass

    def handler(self):
        fixture = self
        html = (ROOT / 'tool/webrtc_interop_fixture.html').read_bytes()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data, status=200, content_type='application/json'):
                body = data if isinstance(data, bytes) else json.dumps(data).encode()
                self.send_response(status)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self):
                if self.path == '/':
                    return self.reply(html, content_type='text/html; charset=utf-8')
                if self.path == '/configuration':
                    return self.reply({'role': 'receiver' if fixture.source_url else 'sender',
                        'codec': fixture.codec, 'audio': fixture.audio,
                        'verifySyntheticPattern': fixture.verify_synthetic_pattern})
                if self.path == '/next-offer':
                    if fixture.stopped.is_set():
                        return self.reply({'stop': True})
                    try:
                        return self.reply(fixture.jobs.get(timeout=.1))
                    except queue.Empty:
                        return self.reply({})
                if self.path == '/api/screen/metadata':
                    fixture.metadata_count += 1
                    return self.reply({'metadata': {'source': 'screen', 'generation': 1,
                        'aspectRatio': 16 / 9, 'width': 640, 'height': 360}})
                self.reply({'error': 'not-found'}, 404)

            def do_POST(self):
                size = int(self.headers.get('Content-Length', '0'))
                if size > 1024 * 1024:
                    return self.reply({'error': 'too-large'}, 413)
                data = json.loads(self.rfile.read(size))
                if self.path == '/source-offer' and fixture.source_url:
                    if fixture.compatibility:
                        data['compatibilityMode'] = True
                    if fixture.viewer_id:
                        data['viewerId'] = fixture.viewer_id
                    request = urllib.request.Request(fixture.source_url, data=json.dumps(data).encode(),
                        headers={'Content-Type': 'application/json'}, method='POST')
                    try:
                        with urllib.request.urlopen(request, timeout=30) as response:
                            return self.reply(response.read(), response.status)
                    except urllib.error.HTTPError as error:
                        return self.reply(error.read(), error.code)
                    except Exception as error:
                        return self.reply({'error': str(error)}, 502)
                if self.path == '/report':
                    fixture.reports.append(data)
                    if data.get('event') == 'ready':
                        fixture.ready.set()
                    return self.reply({'ok': True})
                if self.path.startswith('/answer/'):
                    result = fixture.answers.get(int(self.path.rsplit('/', 1)[1]))
                    if result is not None:
                        result.put(data)
                    return self.reply({'ok': True})
                if self.path == '/api/screen/stop-viewer':
                    if data.get('viewerId') == fixture.current_viewer_id:
                        fixture.jobs.put({'closeViewer': True})
                        fixture.current_viewer_id = None
                    return self.reply({'ok': True})
                if self.path == '/api/screen/offer':
                    with fixture.lock:
                        fixture.offer_count += 1
                        identifier = fixture.offer_count
                        result = queue.Queue(maxsize=1)
                        fixture.answers[identifier] = result
                        fixture.current_viewer_id = data.get('viewerId')
                    fixture.offers.append({'id': identifier,
                        'compatibilityMode': data.get('compatibilityMode', False),
                        'codecs': sorted(set(re.findall(r'^a=rtpmap:\d+ ([^/]+)/', data['sdp'], re.MULTILINE))),
                        'videoLine': next((line for line in data['sdp'].splitlines() if line.startswith('m=video')), '')})
                    recovering = fixture.stall_first or fixture.stall_all
                    job_codec = 'H264' if recovering and identifier == 1 else fixture.codec
                    fixture.jobs.put({'id': identifier, 'offer': data, 'codec': job_codec,
                        'stall': fixture.stall_all or (fixture.stall_first and identifier == 1)})
                    try:
                        answer = result.get(timeout=15)
                        return self.reply(answer, 200 if 'answer' in answer else 500)
                    except queue.Empty:
                        return self.reply({'error': 'browser-answer-timeout'}, 504)
                    finally:
                        fixture.answers.pop(identifier, None)
                self.reply({'error': 'not-found'}, 404)
        return Handler


def run_case(binary, browser, codec, seconds, stall_first, stall_all, native_probe=False):
    fixture = Fixture(codec, stall_first, stall_all)
    server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.handler())
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    source = native = None
    control_origin = None
    native_state = None
    if native_probe:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            control_port = listener.getsockname()[1]
        control_origin = f'http://127.0.0.1:{control_port}'
    started = time.monotonic()
    result = {'codec': codec, 'stallFirstOffer': stall_first, 'stallAllOffers': stall_all,
        'nativeDiagnosticEntrypoint': native_probe, 'passed': False}
    with tempfile.TemporaryDirectory(prefix='bshare-interop-') as directory:
        temp = Path(directory)
        native_log = temp / 'native.log'
        browser_log = temp / 'browser.log'
        env = dict(os.environ)
        for key, name in [('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config')]:
            path = temp / name
            path.mkdir()
            env[key] = str(path)
        if os.name != 'nt':
            env['GDK_BACKEND'] = 'x11'
        with native_log.open('w') as native_output, browser_log.open('w') as browser_output:
            try:
                source = subprocess.Popen([browser, '--headless=new', '--disable-gpu',
                    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
                    '--disable-background-networking', '--disable-component-update',
                    '--autoplay-policy=no-user-gesture-required',
                    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
                    f'--user-data-dir={temp / "browser-profile"}',
                    f'http://127.0.0.1:{server.server_port}/'],
                    stdout=browser_output, stderr=subprocess.STDOUT, env=env)
                if not fixture.ready.wait(15):
                    raise RuntimeError('Browser fixture did not become ready')
                arguments = [str(binary), '--viewer-ip', '127.0.0.1',
                    '--viewer-port', str(server.server_port), '--viewer-name', f'Interop-{codec}']
                if native_probe:
                    arguments += ['--probe-control-port', str(control_port), '--probe-seconds', str(int(seconds + 30))]
                native = subprocess.Popen(arguments,
                    stdout=native_output, stderr=subprocess.STDOUT, env=env)
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    text = native_log.read_text(errors='replace')
                    if control_origin:
                        try:
                            with urllib.request.urlopen(f'{control_origin}/status', timeout=.5) as response:
                                native_state = json.load(response)
                        except (OSError, ValueError):
                            pass
                    failure = (native_state or {}).get('error') or ''
                    if stall_all and ('No decoded video after the compatibility retry' in text or
                                      'No decoded video after the compatibility retry' in failure):
                        metadata_before = fixture.metadata_count
                        time.sleep(1.5)
                        result.update({'passed': fixture.offer_count == 2 and metadata_before == fixture.metadata_count,
                            'boundedFailureReported': True, 'metadataPollingStopped': metadata_before == fixture.metadata_count})
                        break
                    decoded = [int(value) for value in re.findall(r'decoded=(\d+)', text)]
                    decoded.append((native_state or {}).get('decodedFrames', 0))
                    first_frame = 'renderer received its first frame' in text or (native_state or {}).get('firstFrameRendered') is True
                    stats = [value for value in fixture.reports if value['event'] == 'stats']
                    outgoing = next((value for value in reversed(stats) if value.get('framesEncoded', 0) > 0), None)
                    if first_frame and any(decoded) and outgoing:
                        matched_codec = outgoing.get('codec', '').lower() == f'video/{codec.lower()}'
                        result.update({'passed': not stall_first or fixture.offer_count == 2,
                            'firstFrameRendered': True, 'decodedFrames': max(decoded),
                            'sender': outgoing, 'requestedCodecUsed': matched_codec})
                        result['passed'] = result['passed'] and matched_codec
                        break
                    if native.poll() is not None:
                        raise RuntimeError(f'Native application exited early: {native.returncode}')
                    time.sleep(.2)
                if not result['passed']:
                    result['error'] = 'No verified decoded frames before deadline'
            except Exception as error:
                result['error'] = str(error)
            finally:
                if control_origin:
                    try:
                        request = urllib.request.Request(f'{control_origin}/stop', data=b'{}',
                            headers={'Content-Type': 'application/json'}, method='POST')
                        with urllib.request.urlopen(request, timeout=15) as response:
                            result['nativeCleanupResponse'] = json.load(response)
                    except (OSError, ValueError) as error:
                        result['nativeCleanupError'] = str(error)
                    graceful = result.get('nativeCleanupResponse', {}).get('cleanupComplete') is True
                    if not graceful and native is not None:
                        close_native_window(native.pid)
                else:
                    graceful = native is not None and close_native_window(native.pid)
                result['nativeCloseRequested'] = graceful
                result['nativeExitCode'] = stop_process(native)
                fixture.stop()
                deadline = time.monotonic() + 3
                while source is not None and time.monotonic() < deadline:
                    if any(value['event'] == 'closed' for value in fixture.reports):
                        break
                    time.sleep(.1)
                result['browserMediaClosed'] = any(value['event'] == 'closed' for value in fixture.reports)
                if source is not None:
                    if os.name == 'nt' and source.poll() is None:
                        subprocess.run(['taskkill', '/PID', str(source.pid), '/T', '/F'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
                    elif source.poll() is None:
                        source.terminate()
                result['browserExitCode'] = stop_process(source, timeout=5)
                server.shutdown()
                server.server_close()
                serving.join(timeout=5)
        result['nativeLog'] = native_log.read_text(errors='replace')
        if native_probe:
            result['nativeStatus'] = native_state
        result['browserEvents'] = [value for value in fixture.reports if value['event'] != 'stats']
        result['offers'] = fixture.offers
        result['offerCount'] = fixture.offer_count
        if stall_first or stall_all:
            result['boundedCompatibilityRetry'] = (len(fixture.offers) == 2 and
                fixture.offers[0]['compatibilityMode'] is False and
                fixture.offers[1]['compatibilityMode'] is True and
                {codec.lower() for codec in fixture.offers[1]['codecs']} == {'vp8', 'rtx'})
            result['passed'] = result['passed'] and result['boundedCompatibilityRetry']
        result['durationSeconds'] = round(time.monotonic() - started, 2)
        result['cleanupPassed'] = (result['nativeExitCode'] == 0 and result['browserMediaClosed']
            and source is not None and source.poll() is not None and not serving.is_alive()
            and (not native_probe or result.get('nativeCleanupResponse', {}).get('cleanupComplete') is True))
        result['passed'] = result['passed'] and result['cleanupPassed']
    result['temporaryProfileRemoved'] = not temp.exists()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/linux/x64/release/bundle/bshare')
    parser.add_argument('--browser', default=find_browser())
    parser.add_argument('--codec', action='append', choices=['H264', 'VP8'])
    parser.add_argument('--timeout', type=float, default=65)
    parser.add_argument('--stall-first-offer', action='store_true')
    parser.add_argument('--stall-all-offers', action='store_true')
    parser.add_argument('--matrix', action='store_true', help='Run H264, VP8, VP8 recovery and bounded total failure')
    parser.add_argument('--native-probe', action='store_true', help='Binary uses webrtc_native_probe.dart; verify renderer/status via HTTP without stdout dependency')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.browser or not args.binary.is_file() or (os.name != 'nt' and not os.environ.get('DISPLAY')):
        parser.error('A built native binary, browser, and Windows or an X11 display are required')
    if args.matrix and (args.codec or args.stall_first_offer or args.stall_all_offers):
        parser.error('--matrix cannot be combined with single-case options')
    aot = args.binary.parent / ('data/app.so' if os.name == 'nt' else 'lib/libapp.so')
    report = {'scope': 'Native receiver; browser synthetic sender over loopback',
        'platform': platform.system(), 'binary': str(args.binary.resolve()),
        'binarySha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'aotSha256': hashlib.sha256(aot.read_bytes()).hexdigest(),
        'cases': []}
    codecs = args.codec or (['VP8'] if args.stall_first_offer or args.stall_all_offers else ['H264', 'VP8'])
    cases = [('H264', False, False), ('VP8', False, False), ('VP8', True, False), ('VP8', False, True)] if args.matrix else [
        (codec, args.stall_first_offer, args.stall_all_offers) for codec in codecs]
    for codec, stall_first, stall_all in cases:
        result = run_case(args.binary.resolve(), args.browser, codec, args.timeout, stall_first, stall_all, args.native_probe)
        report['cases'].append(result)
        print(json.dumps({key: value for key, value in result.items() if key not in ['nativeLog', 'browserEvents']}), flush=True)
    report['passed'] = all(case['passed'] for case in report['cases'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
