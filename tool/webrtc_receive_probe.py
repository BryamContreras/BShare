#!/usr/bin/env python3
"""Receive an existing BShare screen/camera stream and retain statistics only.

Example:
  python3 tool/webrtc_receive_probe.py --source http://192.168.1.10:53317 \
      --kind camera --codec VP8 --compatibility --seconds 60 \
      --output .dart_tool/camera-receive.json

No frame, screenshot or audio recording is written. The browser is muted. A
single owned viewer ID is released through stop-viewer before browser cleanup.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

from webrtc_interop_probe import Fixture, find_browser, stop_process


def video_evidence(events, codec, require_continuous=False, verify_synthetic_pattern=False):
    samples = [event for event in events if event['event'] == 'stats']
    valid = [sample for sample in samples if sample.get('framesDecoded', 0) > 0
        and sample.get('firstFrameRendered') and sample.get('connectionState') == 'connected'
        and sample.get('codec', '').lower() == f'video/{codec.lower()}'
        and sample.get('frameWidth', 0) > 0 and sample.get('frameHeight', 0) > 0
        and (not verify_synthetic_pattern or sample.get('syntheticPatternPresent') is True)]
    result = {'passed': False, 'advancingVideo': False, 'continuousVideo': False, 'observedFramesPerSecond': 0}
    if verify_synthetic_pattern:
        result['syntheticPatternObserved'] = bool(valid)
    if len(valid) < 2:
        return result
    first, last = valid[0], valid[-1]
    elapsed = (last.get('timestampMs', 0) - first.get('timestampMs', 0)) / 1000
    growth = last['framesDecoded'] - first['framesDecoded']
    result['advancingVideo'] = elapsed >= 1 and growth > 0
    if elapsed > 0:
        result['observedFramesPerSecond'] = round(growth / elapsed, 2)
    previous = next((sample for sample in reversed(valid)
        if last.get('timestampMs', 0) - sample.get('timestampMs', 0) >= 2000), None)
    result['continuousVideo'] = (result['advancingVideo'] and previous is not None and
        last['framesDecoded'] > previous['framesDecoded'] and
        samples[-1].get('connectionState') == 'connected' and
        samples[-1].get('timestampMs', 0) - last.get('timestampMs', 0) < 1000)
    result['passed'] = result['continuousVideo'] if require_continuous else result['advancingVideo']
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='BShare HTTP origin, including port')
    parser.add_argument('--kind', choices=['screen', 'camera'], default='screen')
    parser.add_argument('--codec', choices=['H264', 'VP8'], default='H264')
    parser.add_argument('--compatibility', action='store_true')
    parser.add_argument('--viewer-id', default=str(uuid.uuid4()))
    parser.add_argument('--browser', default=find_browser())
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--stop-file', type=Path)
    parser.add_argument('--require-continuous', action='store_true',
        help='Require advancing frames during the final two seconds before cleanup')
    parser.add_argument('--verify-synthetic-pattern', action='store_true',
        help='Require the diagnostic target blue/yellow pattern; never use for real user media')
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args(arguments)
    if not options.browser:
        parser.error('Chrome/Chromium/Brave is required')
    if options.compatibility and options.codec != 'VP8':
        parser.error('Compatibility mode requires --codec VP8')
    if options.seconds <= 0:
        parser.error('--seconds must be positive')
    origin = options.source.rstrip('/')
    fixture = Fixture(options.codec, False, False,
        source_url=f'{origin}/api/{options.kind}/offer', audio=options.kind == 'camera',
        compatibility=options.compatibility, viewer_id=options.viewer_id,
        verify_synthetic_pattern=options.verify_synthetic_pattern)
    server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.handler())
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    browser = None
    measurement_events = []
    report = {'scope': 'Real BShare sender to browser receiver; stats only, muted playout',
        'kind': options.kind, 'requestedCodec': options.codec,
        'compatibilityMode': options.compatibility, 'passed': False}
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='bshare-receiver-') as directory:
        temp = Path(directory)
        log = temp / 'browser.log'
        with log.open('w') as output:
            try:
                browser = subprocess.Popen([options.browser, '--headless=new', '--disable-gpu',
                    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
                    '--disable-background-networking', '--disable-component-update',
                    '--autoplay-policy=no-user-gesture-required',
                    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
                    f'--user-data-dir={temp / "browser-profile"}', f'http://127.0.0.1:{server.server_port}/'],
                    stdout=output, stderr=subprocess.STDOUT)
                if not fixture.ready.wait(15):
                    raise RuntimeError('Browser fixture did not become ready')
                print(json.dumps({'event': 'READY', 'kind': options.kind, 'viewerId': options.viewer_id,
                    'seconds': options.seconds, 'connected': False}), flush=True)
                deadline = time.monotonic() + options.seconds
                reported = 0
                while time.monotonic() < deadline:
                    if options.stop_file and options.stop_file.exists():
                        report['stopFileObserved'] = True
                        break
                    if browser.poll() is not None:
                        raise RuntimeError(f'Browser exited early: {browser.returncode}')
                    latest = fixture.reports[reported:]
                    reported += len(latest)
                    for event in latest:
                        print(json.dumps(event), flush=True)
                    fatal = next((event for event in latest if event['event'] == 'fatal'), None)
                    if fatal:
                        raise RuntimeError(fatal['message'])
                    time.sleep(.5)
            except Exception as error:
                report['error'] = str(error)
            finally:
                measurement_events = list(fixture.reports)
                request = urllib.request.Request(f'{origin}/api/{options.kind}/stop-viewer',
                    data=json.dumps({'viewerId': options.viewer_id}).encode(),
                    headers={'Content-Type': 'application/json'}, method='POST')
                try:
                    with urllib.request.urlopen(request, timeout=5) as response:
                        report['remoteViewerStopStatus'] = response.status
                except Exception as error:
                    report['remoteViewerStopError'] = str(error)
                fixture.stop()
                deadline = time.monotonic() + 3
                while browser is not None and time.monotonic() < deadline:
                    if any(event['event'] == 'closed' for event in fixture.reports):
                        break
                    time.sleep(.1)
                report['browserMediaClosed'] = any(event['event'] == 'closed' for event in fixture.reports)
                if browser is not None and browser.poll() is None:
                    if os.name == 'nt':
                        subprocess.run(['taskkill', '/PID', str(browser.pid), '/T', '/F'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
                    else:
                        browser.terminate()
                report['browserExitCode'] = stop_process(browser, timeout=5)
                server.shutdown()
                server.server_close()
                serving.join(timeout=5)
        report['events'] = fixture.reports
        samples = [event for event in measurement_events if event['event'] == 'stats']
        evidence = video_evidence(measurement_events, options.codec, options.require_continuous,
            options.verify_synthetic_pattern)
        report.update(evidence)
        report['decodedFrames'] = max((sample.get('framesDecoded', 0) for sample in samples), default=0)
        report['audioSamplesReceived'] = max((sample.get('audioSamplesReceived', 0) for sample in samples), default=0)
        report['cleanupPassed'] = report['browserMediaClosed'] and browser is not None and browser.poll() is not None and not serving.is_alive()
        report['passed'] = evidence.get('passed', False) and report['cleanupPassed'] and 'error' not in report
        report['durationSeconds'] = round(time.monotonic() - started, 2)
    report['temporaryProfileRemoved'] = not temp.exists()
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'events'}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
