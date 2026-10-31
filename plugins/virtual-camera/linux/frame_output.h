#pragma once
#include "transport.h"
#include <algorithm>
#include <array>
#include <map>
#include <vector>

namespace bshare::virtual_camera {
constexpr int kOutputWidth = 1280, kOutputHeight = 720;
constexpr size_t kOutputBytes = size_t(kOutputWidth) * kOutputHeight * 2;
struct PixelFrame { uint32_t width = 0, height = 0, stride = 0; std::vector<uint8_t> pixels; };

inline uint8_t Limited(int value) { return static_cast<uint8_t>(std::clamp(value, 0, 255)); }
inline void BgraToYuyv(const PixelFrame& frame, std::vector<uint8_t>& output) {
  output.resize(kOutputBytes);
  for (size_t i = 0; i < output.size(); i += 4) {
    output[i] = output[i + 2] = 16; output[i + 1] = output[i + 3] = 128;
  }
  if (!frame.width || !frame.height || frame.stride < frame.width * 4 ||
      uint64_t(frame.stride) * frame.height > frame.pixels.size()) return;
  int width, height;
  if (uint64_t(frame.width) * kOutputHeight > uint64_t(kOutputWidth) * frame.height) {
    width = kOutputWidth; height = int(uint64_t(frame.height) * width / frame.width);
  } else {
    height = kOutputHeight; width = int(uint64_t(frame.width) * height / frame.height);
  }
  width = std::max(2, width & ~1); height = std::max(1, height);
  const int left = ((kOutputWidth - width) / 2) & ~1, top = (kOutputHeight - height) / 2;
  for (int y = 0; y < height; ++y) {
    const auto* row = frame.pixels.data() + size_t(uint64_t(y) * frame.height / height) * frame.stride;
    auto* destination = output.data() + (size_t(y + top) * kOutputWidth + left) * 2;
    for (int x = 0; x < width; x += 2) {
      const auto* first = row + (uint64_t(x) * frame.width / width) * 4;
      const auto* second = row + (uint64_t(x + 1) * frame.width / width) * 4;
      const int r = int(first[2]) + second[2], g = int(first[1]) + second[1], b = int(first[0]) + second[0];
      destination[x * 2] = Limited(16 + ((47 * first[2] + 157 * first[1] + 16 * first[0] + 128) >> 8));
      destination[x * 2 + 2] = Limited(16 + ((47 * second[2] + 157 * second[1] + 16 * second[0] + 128) >> 8));
      destination[x * 2 + 1] = Limited(128 + ((-26 * r - 87 * g + 112 * b + 256) >> 9));
      destination[x * 2 + 3] = Limited(128 + ((112 * r - 102 * g - 10 * b + 256) >> 9));
    }
  }
}

inline std::vector<uint8_t> WaitingImage() {
  PixelFrame image;
  image.width = kOutputWidth; image.height = kOutputHeight; image.stride = kOutputWidth * 4;
  image.pixels.resize(size_t(image.stride) * image.height);
  for (size_t i = 0; i < image.pixels.size(); i += 4) {
    image.pixels[i] = 38; image.pixels[i + 1] = 31; image.pixels[i + 2] = 24; image.pixels[i + 3] = 255;
  }
  const std::map<char, std::array<uint8_t, 7>> font{
    {'A',{14,17,17,31,17,17,17}}, {'B',{30,17,17,30,17,17,30}},
    {'C',{14,17,16,16,16,17,14}}, {'D',{30,17,17,17,17,17,30}},
    {'E',{31,16,16,30,16,16,31}}, {'H',{17,17,17,31,17,17,17}},
    {'I',{31,4,4,4,4,4,31}}, {'N',{17,25,25,21,19,19,17}},
    {'O',{14,17,17,17,17,17,14}}, {'R',{30,17,17,30,20,18,17}},
    {'S',{15,16,16,14,1,1,30}}, {'T',{31,4,4,4,4,4,4}},
    {'V',{17,17,17,17,17,10,4}},
  };
  auto text = [&](const std::string& label, int y, int scale) {
    int left = (kOutputWidth - int(label.size()) * 6 * scale) / 2;
    for (char letter : label) {
      auto found = font.find(letter);
      if (found != font.end()) for (int row = 0; row < 7; ++row) for (int column = 0; column < 5; ++column)
        if (found->second[row] & (1 << (4 - column))) for (int py = 0; py < scale; ++py)
          for (int px = 0; px < scale; ++px) {
            auto* pixel = image.pixels.data() + size_t(y + row * scale + py) * image.stride + (left + column * scale + px) * 4;
            pixel[0] = pixel[1] = pixel[2] = 222;
          }
      left += 6 * scale;
    }
  };
  text("BSHARE", 278, 9);
  text("NO VIDEO DEVICE CONNECTED", 390, 4);
  std::vector<uint8_t> output;
  BgraToYuyv(image, output);
  return output;
}
}  // namespace bshare::virtual_camera
