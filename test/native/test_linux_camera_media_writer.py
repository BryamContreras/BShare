"""Decode synthetic JPEG/MP4 files produced by the actual Linux media backend."""
from pathlib import Path
import array
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
#include "desktop_media_writer.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>
#include <gst/gst.h>
using namespace bshare::media;
int main(int argc, char** argv) {
  assert(argc == 3);
  gst_init(nullptr, nullptr);
  // Each subprocess sees a real plugin directory containing just one of the
  // supported AAC implementations. Factory rank alone cannot hide a factory.
  for (const auto* name : {"voaacenc", "fdkaacenc", "avenc_aac"}) {
    auto* factory = gst_element_factory_find(name);
    assert((factory != nullptr) == (std::string(argv[2]) == name));
    if (factory) gst_object_unref(factory);
  }
  if (std::string(argv[2]) == "none") {
    auto writer = CreatePlatformMediaWriter(); std::string error;
    assert(!writer->Start(std::string(argv[1]) + "/unsupported.mp4", 320, 240, 30, error));
    assert(error == "Missing GStreamer AAC encoder: voaacenc, fdkaacenc or avenc_aac");
    return 0;
  }
  VideoFrame frame; frame.width = 320; frame.height = 240; frame.stride = 1280;
  frame.bgra.resize(320 * 240 * 4);
  for (int y = 0; y < 240; ++y) for (int x = 0; x < 320; ++x) {
    auto* p = frame.bgra.data() + y * frame.stride + x * 4;
    p[0] = y < 120 ? 0 : 255; p[1] = 0;
    p[2] = y < 120 ? 255 : 0; p[3] = 255;
  }
  std::string error;
  if (!WritePlatformPhotoJpeg(std::string(argv[1]) + "/synthetic.jpg", frame, .92, error)) {
    std::cerr << error; return 1;
  }
  auto writer = CreatePlatformMediaWriter();
  if (!writer->Start(std::string(argv[1]) + "/synthetic.mp4", 320, 240, 30, error)) {
    std::cerr << error; return 1;
  }
  const auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < 60; ++i) {
    frame.pts_us = i * 1000000LL / 30;
    if (!writer->WriteVideo(frame, error)) { std::cerr << error; return 1; }
    AudioFrame audio; audio.pts_us = frame.pts_us; audio.samples_s16.resize(3200);
    for (int j = 0; j < 1600; ++j) {
      auto sample = static_cast<int16_t>(12000 * std::sin((i * 1600 + j) * 2 * 3.141592653589793 * 1000 / 48000));
      audio.samples_s16[j * 2] = audio.samples_s16[j * 2 + 1] = sample;
    }
    if (!writer->WriteAudio(audio, error)) { std::cerr << error; return 1; }
    std::this_thread::sleep_until(start + std::chrono::microseconds((i + 1) * 1000000LL / 30));
  }
  if (!writer->Finish(error)) { std::cerr << error; return 1; }
  {
    auto invalid = CreatePlatformMediaWriter(); error.clear();
    assert(!invalid->Start(std::string(argv[1]) + "/odd.mp4", 321, 240, 30, error));
    assert(!error.empty()); error.clear();
    assert(!invalid->Start(std::string(argv[1]) + "/odd.mp4", 320, 241, 30, error));
    assert(!error.empty());
  }
  {
    auto bounded = CreatePlatformMediaWriter(); error.clear();
    if (!bounded->Start(std::string(argv[1]) + "/overflow.part.mp4", 320, 240, 30, error)) {
      std::cerr << error; return 1;
    }
    AudioFrame too_large; too_large.samples_s16.resize(48000 * 2 + 2);
    assert(!bounded->WriteAudio(too_large, error));
    const auto original = error;
    assert(original == "Recording encoder cannot keep up with received audio");
    const auto before = std::chrono::steady_clock::now(); error.clear();
    assert(!bounded->Finish(error));
    assert(error == original);
    // A known failure must remain visible, rather than consume its error and
    // wait for an EOS that cannot arrive (the normal timeout is 15 seconds).
    assert(std::chrono::steady_clock::now() - before < std::chrono::seconds(2));
  }
  {
    auto short_clip = CreatePlatformMediaWriter(); error.clear();
    if (!short_clip->Start(std::string(argv[1]) + "/short-silent.mp4", 320, 240, 30, error)) {
      std::cerr << error; return 1;
    }
    frame.pts_us = 0;
    if (!short_clip->WriteVideo(frame, error)) { std::cerr << error; return 1; }
    assert(!short_clip->WriteVideo(frame, error));  // duplicate timestamp
    AudioFrame silence; silence.samples_s16.resize(3200);
    if (!short_clip->WriteAudio(silence, error)) { std::cerr << error; return 1; }
    assert(!short_clip->WriteAudio(silence, error));
    if (!short_clip->Finish(error)) { std::cerr << error; return 1; }
  }
  const auto dirs = PlatformMediaDirectories();
  assert(!dirs.first.empty() && dirs.first[0] == '/');
  assert(!dirs.second.empty() && dirs.second[0] == '/');
}
'''

@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux GStreamer backend')
class LinuxCameraMediaWriterTest(unittest.TestCase):
    def test_actual_jpeg_h264_aac_and_decoded_pixels(self):
        for tool in ('g++', 'pkg-config', 'gst-inspect-1.0', 'ffmpeg', 'ffprobe'):
            self.assertIsNotNone(shutil.which(tool), tool)
        with tempfile.TemporaryDirectory(prefix='bshare-owned-media-') as temp:
            directory = Path(temp)
            fixture, binary = directory / 'fixture.cpp', directory / 'fixture'
            fixture.write_text(HARNESS)
            flags = subprocess.check_output(['pkg-config', '--cflags', '--libs',
                'gstreamer-1.0', 'gstreamer-app-1.0', 'gdk-pixbuf-2.0'], text=True).split()
            subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I' + str(ROOT / 'third_party/flutter_webrtc/common/cpp/include'),
                str(fixture), str(ROOT / 'third_party/flutter_webrtc/linux/desktop_media_writer_gstreamer.cc'),
                '-o', str(binary), *flags], check=True, timeout=60)
            encoders = {}
            for name in ('voaacenc', 'fdkaacenc', 'avenc_aac'):
                inspected = subprocess.run(['gst-inspect-1.0', name], capture_output=True, text=True,
                    env=dict(os.environ, LC_ALL='C'), timeout=15)
                if inspected.returncode == 0:
                    location = re.search(r'^\s*Filename\s+(.+)$', inspected.stdout, re.MULTILINE)
                    self.assertIsNotNone(location, inspected.stdout)
                    encoders[name] = Path(location.group(1)).resolve()
            self.assertIn('voaacenc', encoders, 'Install the bad plugins for the first encoder branch')
            self.assertIn('avenc_aac', encoders, 'Install gstreamer1.0-libav for real fallback coverage')
            plugin_roots = {path.parent for path in encoders.values()}
            plugin_roots.add(Path(subprocess.check_output(
                ['pkg-config', '--variable=pluginsdir', 'gstreamer-1.0'], text=True).strip()))
            encoder_files = set(encoders.values())
            for name in [*encoders, 'none']:
                with self.subTest(encoder=name):
                    output = directory / name
                    output.mkdir()
                    plugins = output / 'plugins'
                    plugins.mkdir()
                    for root in plugin_roots:
                        for plugin in root.glob('*.so'):
                            if plugin.resolve() in encoder_files and plugin.resolve() != encoders.get(name):
                                continue
                            target = plugins / plugin.name
                            if not target.exists():
                                target.symlink_to(plugin)
                    registry = str(output / 'registry.bin')
                    environment = dict(os.environ, GST_PLUGIN_SYSTEM_PATH=str(plugins),
                        GST_PLUGIN_SYSTEM_PATH_1_0=str(plugins), GST_PLUGIN_PATH='', GST_PLUGIN_PATH_1_0='',
                        GST_REGISTRY=registry, GST_REGISTRY_1_0=registry)
                    result = subprocess.run([str(binary), str(output), name], env=environment,
                        capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    if name == 'none':
                        self.assertFalse((output / 'unsupported.mp4').exists())
                    else:
                        self.verify_files(output)
                        print('AAC implementation decoded successfully:', name)

    def verify_files(self, directory):
        movie = directory / 'synthetic.mp4'
        info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams',
            '-show_format', '-of', 'json', str(movie)], timeout=15))
        self.assertEqual([s['codec_name'] for s in info['streams']], ['h264', 'aac'])
        self.assertAlmostEqual(float(info['format']['duration']), 2, delta=.15)
        self.assertEqual((info['streams'][0]['width'], info['streams'][0]['height']), (320, 240))
        self.assertGreaterEqual(int(info['streams'][0]['nb_frames']), 55)
        for path in (directory / 'synthetic.jpg', movie):
            pixels = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
                '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], timeout=15)
            self.assertGreater(pixels[2 * 320 * 3], 220)
            self.assertLess(pixels[2 * 320 * 3 + 2], 30)
            self.assertGreater(pixels[200 * 320 * 3 + 2], 220)
            self.assertLess(pixels[200 * 320 * 3], 30)
        pcm = array.array('h', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(movie),
            '-vn', '-f', 's16le', '-ac', '2', '-ar', '48000', '-'], timeout=15))
        self.assertGreater(len(pcm), 180000)
        self.assertGreater(math.sqrt(sum(v * v for v in pcm) / len(pcm)), 7000)
        short_clip = directory / 'short-silent.mp4'
        short_info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams',
            '-show_format', '-of', 'json', str(short_clip)], timeout=15))
        self.assertEqual([s['codec_name'] for s in short_info['streams']], ['h264', 'aac'])
        self.assertEqual(int(short_info['streams'][0]['nb_frames']), 1)
        self.assertLess(float(short_info['format']['duration']), .15)
        silence = array.array('h', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(short_clip),
            '-vn', '-f', 's16le', '-ac', '2', '-ar', '48000', '-'], timeout=15))
        self.assertGreater(len(silence), 0)
        self.assertLessEqual(max(abs(value) for value in silence), 1)
        self.assertFalse((directory / 'odd.mp4').exists())
        print('Linux: JPEG orientation/colors, H.264/AAC duration/pixels/PCM, one-frame silent finalization, '
              'monotonic timestamps, early dimension validation and bounded audio failure verified.')

if __name__ == '__main__': unittest.main()
