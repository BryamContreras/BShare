import unittest
from unittest.mock import patch

from webrtc_interop_probe import find_browser, native_video_has_advanced
from webrtc_receive_probe import video_evidence


def sample(time, frames, codec='video/VP8', state='connected'):
    return {'event': 'stats', 'timestampMs': time, 'framesDecoded': frames,
        'firstFrameRendered': frames > 0, 'connectionState': state,
        'codec': codec, 'frameWidth': 640, 'frameHeight': 360}


class VideoEvidenceTest(unittest.TestCase):
    def test_native_receiver_requires_advancing_frames_over_time(self):
        self.assertFalse(native_video_has_advanced(None, 0, 2))
        self.assertFalse(native_video_has_advanced((1, 1), 1, 4))
        self.assertFalse(native_video_has_advanced((1, 1), 10, 1.5))
        self.assertTrue(native_video_has_advanced((1, 29), 59, 3))

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
