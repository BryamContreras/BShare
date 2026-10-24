import unittest
from unittest.mock import patch
import io
import os
import threading
import time

from webrtc_interop_probe import find_browser, native_video_has_multiple_frames
from webrtc_native_sender_probe import launch_xvfb
from webrtc_receive_probe import video_evidence


def sample(time, frames, codec='video/VP8', state='connected'):
    return {'event': 'stats', 'timestampMs': time, 'framesDecoded': frames,
        'firstFrameRendered': frames > 0, 'connectionState': state,
        'codec': codec, 'frameWidth': 640, 'frameHeight': 360}


class VideoEvidenceTest(unittest.TestCase):
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
