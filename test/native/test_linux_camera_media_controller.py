"""Run the production camera worker/API with Linux SDK tracks and GStreamer.

Flutter channel/peer lookup are doubles; EncodableMap parsing, video conversion,
audio pacing, file publication and the encoder are production code. No GTK,
display server, phone, microphone or Flutter engine is opened.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_desktop_camera_media_controller import PLUGIN, controller_source


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux SDK and GStreamer contract')
class LinuxCameraMediaControllerTest(unittest.TestCase):
    def test_production_workers_and_platform_api(self):
        sdk = PLUGIN / 'third_party/libwebrtc'
        self.assertTrue((sdk / 'lib/libwebrtc.so').is_file(), 'Use an already installed Linux SDK')
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs',
            'gstreamer-1.0', 'gstreamer-app-1.0', 'gdk-pixbuf-2.0'], text=True).split()
        # Keep the actual shared EncodableValue types and parser helpers. Only
        # the unused engine registration headers are omitted from this fixture.
        common = (PLUGIN / 'common/cpp/include/flutter_common.h').read_text()
        helper_start = common.index('template <typename T>')
        helper_end = common.index('inline bool findBoolean(')
        result_class = common[common.index('class MethodResultProxy {'):common.index('class EventChannelProxy {')]
        shim = '''#pragma once
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>
#include <string>
#include <vector>
using EncodableValue = flutter::EncodableValue;
using EncodableMap = flutter::EncodableMap;
using EncodableList = flutter::EncodableList;
using MethodResult = flutter::MethodResult<EncodableValue>;
class TaskRunner;
''' + common[helper_start:helper_end] + result_class
        with tempfile.TemporaryDirectory(prefix='bshare-owned-linux-worker-') as temp:
            directory = Path(temp)
            (directory / 'flutter_common.h').write_text(shim)
            (directory / 'desktop_media_manager.h').write_text(
                (PLUGIN / 'common/cpp/include/desktop_media_manager.h').read_text())
            (directory / 'flutter_webrtc_base.h').write_text('''#pragma once
#include "libwebrtc.h"
namespace flutter_webrtc_plugin { using namespace libwebrtc; class FlutterWebRTCBase; }
''')
            fixture, binary = directory / 'fixture.cc', directory / 'fixture'
            fixture.write_text(controller_source())
            result = subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-Wno-unused-parameter', '-pthread', '-DRTC_DESKTOP_DEVICE',
                '-I' + str(directory), '-I' + str(PLUGIN / 'linux/flutter/include'),
                '-I' + str(PLUGIN / 'common/cpp/include'), '-I' + str(sdk / 'include'),
                str(fixture), str(PLUGIN / 'linux/desktop_media_writer_gstreamer.cc'),
                str(sdk / 'lib/libwebrtc.so'), '-Wl,-rpath,' + str(sdk / 'lib'),
                '-o', str(binary), *flags], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary), str(directory)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
