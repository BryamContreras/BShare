"""Compile and validate the actual Windows JPEG/MP4 writer with synthetic media.

Uses WIC and Media Foundation decoders to verify JPEG geometry, H.264/AAC tracks,
decoded frames and PCM energy. Files live only in an owned temporary directory.
No camera, microphone, user desktop or application process is captured.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def verify_ffprobe(movie):
    executable = shutil.which('ffprobe')
    if executable:
        command = [executable]
        filename = str(movie)
    elif shutil.which('wsl'):
        available = subprocess.run(['wsl', '--exec', '/usr/bin/test', '-x', '/usr/bin/ffprobe'], capture_output=True, timeout=10)
        if available.returncode != 0: return
        filename = subprocess.run(['wsl', '--exec', '/usr/bin/wslpath', '-u', str(movie)], capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        command = ['wsl', '--exec', '/usr/bin/ffprobe']
    else:
        return
    result = subprocess.run([*command, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', filename], capture_output=True, text=True, timeout=15, check=True)
    value = json.loads(result.stdout)
    video = next(stream for stream in value['streams'] if stream['codec_type'] == 'video')
    audio = next(stream for stream in value['streams'] if stream['codec_type'] == 'audio')
    assert video['codec_name'] == 'h264' and video['width'] == 320 and video['height'] == 240
    assert int(video['nb_frames']) == 60
    assert audio['codec_name'] == 'aac' and int(audio['sample_rate']) == 48000 and audio['channels'] == 2
    assert 1.9 <= float(value['format']['duration']) <= 2.2
    print('Independent ffprobe: H264/AAC, 60 frames, 320x240, 48 kHz stereo, duration 2s.')
HARNESS = r'''
#include "desktop_media_writer.h"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <cassert>
#include <cmath>
#include <iostream>
using namespace bshare::media;
using Microsoft::WRL::ComPtr;
constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD kMediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);
void Ok(HRESULT result) { if (FAILED(result)) { std::cerr << std::hex << result << "\n"; std::abort(); } }
int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string directory = argv[1];
  const std::string photo = directory + "/synthetic.jpg";
  const std::string movie = directory + "/synthetic.mp4";
  VideoFrame frame; frame.width = 320; frame.height = 240; frame.stride = 1280;
  frame.bgra.resize(320 * 240 * 4);
  for (int y = 0; y < 240; ++y) for (int x = 0; x < 320; ++x) {
    auto* pixel = frame.bgra.data() + y * frame.stride + x * 4;
    pixel[0] = y < 120 ? 0 : 255; pixel[1] = 0; pixel[2] = y < 120 ? 255 : 0; pixel[3] = 255;
  }
  std::string error;
  assert(WritePlatformPhotoJpeg(photo, frame, .92, error));
  {
    auto writer = CreatePlatformMediaWriter();
    if (!writer->Start(movie, 320, 240, 30, error)) { std::cerr << error << "\n"; return 1; }
    int64_t sample = 0;
    for (int index = 0; index < 60; ++index) {
      frame.pts_us = index * 1000000LL / 30;
      if (!writer->WriteVideo(frame, error)) { std::cerr << error << "\n"; return 1; }
      AudioFrame audio; audio.pts_us = sample * 1000000 / 48000;
      audio.samples_s16.resize(3200);
      for (int offset = 0; offset < 1600; ++offset) {
        const auto value = static_cast<int16_t>(12000 * std::sin((sample + offset) * 2 * 3.141592653589793 * 1000 / 48000));
        audio.samples_s16[offset * 2] = value; audio.samples_s16[offset * 2 + 1] = value;
      }
      sample += 1600;
      if (!writer->WriteAudio(audio, error)) { std::cerr << error << "\n"; return 1; }
    }
    if (!writer->Finish(error)) { std::cerr << error << "\n"; return 1; }
  }
  Ok(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); Ok(MFStartup(MF_VERSION));
  {
    ComPtr<IWICImagingFactory> factory; ComPtr<IWICBitmapDecoder> decoder; ComPtr<IWICBitmapFrameDecode> image;
    Ok(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
    const std::wstring photo_wide(photo.begin(), photo.end());
    Ok(factory->CreateDecoderFromFilename(photo_wide.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder));
    Ok(decoder->GetFrame(0, &image)); UINT width = 0, height = 0; Ok(image->GetSize(&width, &height));
    assert(width == 320 && height == 240);
    ComPtr<IWICFormatConverter> converter; Ok(factory->CreateFormatConverter(&converter));
    Ok(converter->Initialize(image.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
    std::vector<uint8_t> pixels(320 * 240 * 4); Ok(converter->CopyPixels(nullptr, 1280, static_cast<UINT>(pixels.size()), pixels.data()));
    assert(pixels[2] > 220 && pixels[0] < 30);
    assert(pixels[200 * 1280] > 220 && pixels[200 * 1280 + 2] < 30);
  }
  {
    const std::wstring movie_wide(movie.begin(), movie.end()); ComPtr<IMFSourceReader> reader;
    Ok(MFCreateSourceReaderFromURL(movie_wide.c_str(), nullptr, &reader));
    ComPtr<IMFMediaType> video, audio; GUID subtype{};
    Ok(reader->GetNativeMediaType(kVideoStream, 0, &video));
    Ok(video->GetGUID(MF_MT_SUBTYPE, &subtype)); assert(subtype == MFVideoFormat_H264);
    Ok(reader->GetNativeMediaType(kAudioStream, 0, &audio));
    Ok(audio->GetGUID(MF_MT_SUBTYPE, &subtype)); assert(subtype == MFAudioFormat_AAC);
    PROPVARIANT duration{}; Ok(reader->GetPresentationAttribute(kMediaSource, MF_PD_DURATION, &duration));
    assert(duration.uhVal.QuadPart >= 19000000 && duration.uhVal.QuadPart <= 22000000); PropVariantClear(&duration);
    ComPtr<IMFMediaType> raw_video; Ok(MFCreateMediaType(&raw_video));
    Ok(raw_video->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)); Ok(raw_video->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12));
    Ok(reader->SetCurrentMediaType(kVideoStream, nullptr, raw_video.Get()));
    int frames = 0; for (;;) {
      DWORD flags = 0; ComPtr<IMFSample> sample;
      Ok(reader->ReadSample(kVideoStream, 0, nullptr, &flags, nullptr, &sample));
      if (sample) ++frames; if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    assert(frames == 60);
    PROPVARIANT beginning{}; beginning.vt = VT_I8; beginning.hVal.QuadPart = 0; Ok(reader->SetCurrentPosition(GUID_NULL, beginning));
    ComPtr<IMFMediaType> pcm; Ok(MFCreateMediaType(&pcm)); Ok(pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    Ok(pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM)); Ok(reader->SetCurrentMediaType(kAudioStream, nullptr, pcm.Get()));
    int64_t audio_bytes = 0; int64_t energy = 0;
    for (;;) {
      DWORD flags = 0; ComPtr<IMFSample> sample;
      Ok(reader->ReadSample(kAudioStream, 0, nullptr, &flags, nullptr, &sample));
      if (sample) {
        ComPtr<IMFMediaBuffer> buffer; Ok(sample->ConvertToContiguousBuffer(&buffer)); BYTE* bytes = nullptr; DWORD length = 0;
        Ok(buffer->Lock(&bytes, nullptr, &length)); audio_bytes += length;
        const auto* values = reinterpret_cast<const int16_t*>(bytes);
        for (DWORD index = 0; index < length / 2; ++index) energy += std::abs(static_cast<int>(values[index]));
        buffer->Unlock();
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    assert(audio_bytes >= 350000 && energy > 1000000);
    std::cout << "JPEG top-down 320x240; MP4 H264 60 decoded frames + AAC remote-fixture PCM, duration 2s.\n";
  }
  MFShutdown(); CoUninitialize();
}
'''

@unittest.skipUnless(os.name == 'nt', 'Windows Media Foundation/WIC backend')
class WindowsCameraMediaWriterTest(unittest.TestCase):
    def test_actual_jpeg_and_h264_aac_files(self):
        with tempfile.TemporaryDirectory(prefix='bshare-owned-media-') as temp:
            directory = Path(temp)
            fixture, binary = directory / 'fixture.cpp', directory / 'fixture.exe'
            fixture.write_text(HARNESS)
            arguments = ['/nologo', '/std:c++17', '/W4', '/WX', '/wd4100', '/EHsc', '/DNOMINMAX',
                f'/I{ROOT / "third_party/flutter_webrtc/common/cpp/include"}', str(fixture),
                str(ROOT / 'third_party/flutter_webrtc/windows/desktop_media_writer_mf.cc'),
                f'/Fo{directory}/', f'/Fe{binary}', '/link', 'mfplat.lib', 'mfreadwrite.lib', 'mfuuid.lib',
                'windowscodecs.lib', 'ole32.lib', 'oleaut32.lib', 'shell32.lib', 'uuid.lib']
            compiler = shutil.which('cl')
            if compiler:
                command = [compiler, *arguments]
            else:
                vswhere = Path(os.environ.get('ProgramFiles(x86)', '')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
                installation = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
                    capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                vcvars = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
                script = directory / 'compile.cmd'
                script.write_text('@echo off\ncall "' + str(vcvars) + '" >nul\nif errorlevel 1 exit /b %errorlevel%\ncl ' +
                    ' '.join('"' + value + '"' for value in arguments) + '\nexit /b %errorlevel%\n')
                command = ['cmd', '/c', str(script)]
            built = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            executed = subprocess.run([str(binary), str(directory)], cwd=directory, capture_output=True, text=True, timeout=30)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            print(executed.stdout.strip())
            self.assertGreater((directory / 'synthetic.jpg').stat().st_size, 1000)
            self.assertGreater((directory / 'synthetic.mp4').stat().st_size, 10000)
            verify_ffprobe(directory / 'synthetic.mp4')

if __name__ == '__main__': unittest.main()
