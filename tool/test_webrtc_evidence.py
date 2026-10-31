import unittest
from unittest.mock import Mock, patch
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading
import time

from webrtc_interop_probe import (
    Fixture, close_native_window, find_browser, native_video_has_multiple_frames,
    native_crash_backtrace, video_codec_names, wait_for_browser_ready,
)
from webrtc_native_sender_probe import launch_xvfb
from webrtc_receive_probe import video_evidence


def sample(time, frames, codec='video/VP8', state='connected'):
    return {'event': 'stats', 'timestampMs': time, 'framesDecoded': frames,
        'firstFrameRendered': frames > 0, 'connectionState': state,
        'codec': codec, 'frameWidth': 640, 'frameHeight': 360}


class VideoCodecOfferTest(unittest.TestCase):
    def test_audio_codecs_do_not_invalidate_vp8_only_video_fallback(self):
        sdp = '\r\n'.join([
            'v=0', 'm=audio 9 UDP/TLS/RTP/SAVPF 96 8',
            'a=rtpmap:96 opus/48000/2', 'a=rtpmap:8 PCMA/8000',
            'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
            'a=rtpmap:96 VP8/90000', 'a=rtpmap:97 rtx/90000',
            'm=audio 9 UDP/TLS/RTP/SAVPF 0', 'a=rtpmap:0 PCMU/8000'])
        self.assertEqual(video_codec_names(sdp), {'VP8', 'rtx'})

    def test_additional_video_codec_remains_visible_to_strict_fallback_check(self):
        sdp = '\n'.join([
            'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102',
            'a=rtpmap:96 VP8/90000', 'a=rtpmap:97 rtx/90000',
            'a=rtpmap:102 H264/90000'])
        self.assertEqual(video_codec_names(sdp), {'VP8', 'rtx', 'H264'})

    def test_unoffered_payload_and_audio_only_offer_are_not_video(self):
        self.assertEqual(video_codec_names('\n'.join([
            'm=video 9 UDP/TLS/RTP/SAVPF 96',
            'a=rtpmap:96 VP8/90000', 'a=rtpmap:102 H264/90000'])), {'VP8'})
        self.assertEqual(video_codec_names('\n'.join([
            'm=audio 9 UDP/TLS/RTP/SAVPF 102', 'a=rtpmap:102 opus/48000/2'])), set())


@unittest.skipUnless(os.name != 'nt', 'POSIX-owned core files')
class NativeCrashBacktraceTest(unittest.TestCase):
    def test_actual_debugger_reads_owned_synthetic_abort_and_removes_dump(self):
        if not shutil.which('gdb') or not shutil.which('cc'):
            self.skipTest('Native gdb and C compiler are not installed')
        with tempfile.TemporaryDirectory(prefix='bshare-native-cores-') as temporary:
            directory = Path(temporary)
            source, binary = directory / 'fixture.c', directory / 'fixture'
            core = directory / 'core.1234'
            source.write_text('#include <stdlib.h>\nint main(void) { abort(); }\n')
            subprocess.run(['cc', '-g', '-O0', str(source), '-o', str(binary)],
                           capture_output=True, check=True, timeout=20)
            # Generate only this debugger-owned child's core. The host kernel
            # pattern, limits and other applications are never modified.
            generated = subprocess.run([
                'gdb', '--batch', '--quiet', '-ex', 'set debuginfod enabled off',
                '-ex', 'run', '-ex', f'generate-core-file {core}', str(binary),
            ], capture_output=True, text=True, timeout=30)
            self.assertTrue(core.is_file(), generated.stdout + generated.stderr)
            with patch.dict(os.environ, BSHARE_NATIVE_CORE_DIRECTORY=temporary):
                trace = native_crash_backtrace(binary, 1234, -6)
            self.assertTrue(trace['captured'], trace)
            self.assertIn('SIGABRT', trace['text'])
            self.assertIn('main', trace['text'])
            self.assertTrue(trace['coreRemoved'])
            self.assertFalse(core.exists())

    def test_only_exact_child_core_is_read_and_removed_after_text_capture(self):
        with tempfile.TemporaryDirectory(prefix='bshare-native-cores-') as temporary:
            directory = Path(temporary)
            core = directory / 'core.1234'
            other = directory / 'core.9876'
            core.write_bytes(b'synthetic core fixture')
            other.write_bytes(b'other process')
            result = subprocess.CompletedProcess([], 0, 'thread backtrace fixture', '')
            with patch.dict(os.environ, BSHARE_NATIVE_CORE_DIRECTORY=temporary), \
                    patch('webrtc_interop_probe.shutil.which', return_value='/usr/bin/gdb'), \
                    patch('webrtc_interop_probe.subprocess.run', return_value=result) as command:
                trace = native_crash_backtrace(Path('/owned/bshare'), 1234, -6)
            self.assertTrue(trace['captured'])
            self.assertIn('thread backtrace fixture', trace['text'])
            self.assertEqual(command.call_args.args[0][-2:], ['/owned/bshare', str(core)])
            self.assertFalse(core.exists())
            self.assertTrue(other.exists())

    def test_debugger_failure_still_removes_own_core(self):
        with tempfile.TemporaryDirectory(prefix='bshare-native-cores-') as temporary:
            core = Path(temporary) / 'core.1234'
            core.write_bytes(b'synthetic core fixture')
            with patch.dict(os.environ, BSHARE_NATIVE_CORE_DIRECTORY=temporary), \
                    patch('webrtc_interop_probe.shutil.which', return_value='/usr/bin/gdb'), \
                    patch('webrtc_interop_probe.subprocess.run', side_effect=subprocess.TimeoutExpired('gdb', 30)):
                trace = native_crash_backtrace(Path('/owned/bshare'), 1234, -11)
            self.assertFalse(trace['captured'])
            self.assertFalse(core.exists())

    def test_normal_exit_does_not_read_core_and_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory(prefix='bshare-native-cores-') as temporary:
            directory = Path(temporary)
            target = directory / 'unrelated'
            target.write_bytes(b'not a child core')
            core = directory / 'core.1234'
            core.symlink_to(target)
            with patch.dict(os.environ, BSHARE_NATIVE_CORE_DIRECTORY=temporary), \
                    patch('webrtc_interop_probe.subprocess.run') as command:
                self.assertIsNone(native_crash_backtrace(Path('/owned/bshare'), 1234, 0))
                self.assertFalse(native_crash_backtrace(Path('/owned/bshare'), 1234, -11)['captured'])
            command.assert_not_called()
            self.assertTrue(target.exists())


class _FakeClock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


class _FakeReady:
    def __init__(self, clock, fixture, ready_after=None):
        self.clock = clock
        self.fixture = fixture
        self.ready_at = None if ready_after is None else clock() + ready_after
        self.waits = []
        self.on_wait = None

    def is_set(self):
        return self.fixture.ready_received_at is not None

    def wait(self, timeout):
        self.waits.append(timeout)
        duration = timeout
        if self.ready_at is not None:
            duration = min(duration, max(0, self.ready_at - self.clock()))
        self.clock.now += duration
        if self.ready_at is not None and self.clock() >= self.ready_at:
            self.fixture.ready_received_at = self.ready_at
        if self.on_wait is not None:
            self.on_wait()
        return self.is_set()


class BrowserStartupTest(unittest.TestCase):
    def fixture(self, ready_after=None):
        clock = _FakeClock()
        fixture = Fixture('H264', False, False)
        fixture.ready = _FakeReady(clock, fixture, ready_after)
        return clock, fixture, Mock(poll=Mock(return_value=None))

    def test_browser_ready_after_seventeen_seconds_has_its_own_budget(self):
        clock, fixture, browser = self.fixture(ready_after=17)
        wait_for_browser_ready(fixture, browser, clock=clock)
        self.assertEqual(clock(), 117)
        self.assertEqual(fixture.ready_received_at, 117)
        self.assertTrue(all(0 < duration <= .1 for duration in fixture.ready.waits))

    def test_browser_readiness_stall_reaches_exact_forty_five_second_deadline(self):
        clock, fixture, browser = self.fixture()
        with self.assertRaisesRegex(TimeoutError, 'within 45 seconds'):
            wait_for_browser_ready(fixture, browser, clock=clock)
        self.assertEqual(clock(), 145)
        self.assertTrue(all(0 < duration <= .1 for duration in fixture.ready.waits))

    def test_ready_received_after_deadline_cannot_reverse_a_timeout(self):
        clock, fixture, browser = self.fixture(ready_after=46)
        with self.assertRaises(TimeoutError):
            wait_for_browser_ready(fixture, browser, started_at=100, clock=clock)
        fixture.ready.wait(1)  # A late report can still arrive during cleanup.
        self.assertEqual(fixture.ready_received_at, 146)
        with self.assertRaises(TimeoutError):
            wait_for_browser_ready(fixture, browser, started_at=100, clock=clock)

    def test_browser_exit_fails_early_even_when_ready_is_also_received(self):
        for ready_after in [None, 2]:
            for exit_code in [0, 9]:
                with self.subTest(ready_after=ready_after, exit_code=exit_code):
                    clock, fixture, browser = self.fixture(ready_after)
                    browser.poll.side_effect = lambda: exit_code if clock() >= 102 else None
                    with self.assertRaisesRegex(RuntimeError, f'Browser exited early: {exit_code}'):
                        wait_for_browser_ready(fixture, browser, clock=clock)
                    self.assertLess(clock(), 103)

    def test_fatal_fails_early_even_when_ready_is_also_received(self):
        for ready_after in [None, 2]:
            with self.subTest(ready_after=ready_after):
                clock, fixture, browser = self.fixture(ready_after)

                def report_fatal():
                    if clock() >= 102:
                        fixture.reports.append({'event': 'fatal', 'message': 'fixture failed'})

                fixture.ready.on_wait = report_fatal
                with self.assertRaisesRegex(RuntimeError, 'Browser fixture fatal: fixture failed'):
                    wait_for_browser_ready(fixture, browser, clock=clock)
                self.assertLess(clock(), 103)

    def test_startup_budget_must_be_positive_and_finite(self):
        clock, fixture, browser = self.fixture()
        for timeout in [0, -1, float('inf'), float('nan')]:
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                wait_for_browser_ready(fixture, browser, timeout, clock=clock)
        self.assertFalse(fixture.ready.waits)

    def test_ready_report_records_its_first_received_time_before_signaling(self):
        fixture = Fixture('H264', False, False)
        handler = object.__new__(fixture.handler())
        payload = json.dumps({'event': 'ready'}).encode()
        handler.path = '/report'
        handler.headers = {'Content-Length': str(len(payload))}
        handler.reply = Mock()
        for received_at in [117, 146]:
            handler.rfile = io.BytesIO(payload)
            with patch('webrtc_interop_probe.time.monotonic', return_value=received_at):
                handler.do_POST()
            self.assertEqual(fixture.ready_received_at, 117)
            self.assertTrue(fixture.ready.is_set())


class VideoEvidenceTest(unittest.TestCase):
    @unittest.skipIf(os.name == 'nt', 'X11 display selection is Linux-specific')
    def test_native_close_uses_the_owned_capture_display(self):
        with patch('webrtc_interop_probe.close_x11_window', return_value=True) as close:
            self.assertTrue(close_native_window(1234, display_name=':91'))
        close.assert_called_once_with(1234, ':91')

    @unittest.skipIf(os.name == 'nt', 'Xvfb uses Unix pipe readiness')
    def test_xvfb_waits_for_complete_display_number_line(self):
        writers, failures = [], []

        def launch(_arguments, **options):
            writer = os.dup(options['pass_fds'][0])

            def write_in_chunks():
                try:
                    os.write(writer, b'91')
                    time.sleep(.05)
                    os.write(writer, b'\n')
                except OSError as error:
                    failures.append(error)
                finally:
                    os.close(writer)

            thread = threading.Thread(target=write_in_chunks)
            writers.append(thread)
            thread.start()
            return object()

        try:
            with patch('webrtc_native_sender_probe.subprocess.Popen', side_effect=launch):
                _, display = launch_xvfb('unused', io.StringIO(), {})
            self.assertEqual(display, ':91')
        finally:
            for writer in writers:
                writer.join(timeout=2)
        self.assertFalse(failures)

    def test_native_receiver_rejects_single_decoded_frame(self):
        self.assertFalse(native_video_has_multiple_frames(0))
        self.assertFalse(native_video_has_multiple_frames(1))
        self.assertTrue(native_video_has_multiple_frames(2))
        self.assertTrue(native_video_has_multiple_frames(29))

    def test_browser_discovery_prefers_branded_h264_build(self):
        installed = {'google-chrome': '/usr/bin/google-chrome',
            'chromium': '/usr/bin/chromium'}
        with patch('webrtc_interop_probe.shutil.which', side_effect=installed.get):
            self.assertEqual(find_browser(), '/usr/bin/google-chrome')

    def test_single_frame_or_frozen_decoder_does_not_prove_streaming(self):
        for samples in [[sample(0, 1)], [sample(0, 1), sample(3000, 1)]]:
            with self.subTest(samples=samples):
                self.assertFalse(video_evidence(samples, 'VP8').get('passed', False))

    def test_different_negotiated_codec_does_not_satisfy_requested_case(self):
        self.assertFalse(video_evidence([
            sample(0, 10, 'video/H264'), sample(3000, 100, 'video/H264'),
        ], 'VP8').get('passed', False))

    def test_continuous_case_catches_stream_freezing_after_startup(self):
        samples = [sample(0, 1), sample(1000, 30), sample(3000, 30), sample(6000, 30)]
        self.assertTrue(video_evidence(samples, 'VP8')['passed'])
        self.assertFalse(video_evidence(samples, 'VP8', require_continuous=True)['passed'])

    def test_continuous_case_requires_connection_at_end_of_measurement(self):
        samples = [sample(0, 1), sample(3000, 90), sample(3500, 90, state='disconnected')]
        self.assertFalse(video_evidence(samples, 'VP8', require_continuous=True)['passed'])

    def test_real_progress_and_matching_codec_are_counted(self):
        evidence = video_evidence([sample(0, 1), sample(3000, 91)], 'VP8', require_continuous=True)
        self.assertTrue(evidence['passed'])
        self.assertEqual(evidence['observedFramesPerSecond'], 30)

    def test_native_capture_case_rejects_decodable_black_frames(self):
        samples = [sample(0, 1), sample(3000, 91)]
        self.assertFalse(video_evidence(samples, 'VP8', verify_synthetic_pattern=True)['passed'])
        for item in samples:
            item['syntheticPatternPresent'] = True
        self.assertTrue(video_evidence(samples, 'VP8', verify_synthetic_pattern=True)['passed'])


if __name__ == '__main__':
    unittest.main()
