#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
flutter_executable="$(readlink -f -- "$(command -v flutter)")"
flutter_sdk="$(cd -- "$(dirname -- "$flutter_executable")/.." && pwd)"
case "$(uname -m)" in
  aarch64|arm64) flutter_arch=arm64 ;;
  *) flutter_arch=x64 ;;
esac
read -r -a gtk_flags <<< "$(pkg-config --cflags gtk+-3.0)"
test_binary="$(mktemp /tmp/bshare-video-renderer-test.XXXXXX)"
trap 'rm -f -- "$test_binary"' EXIT

"${CXX:-c++}" -std=c++17 -O2 -pthread -ffunction-sections -fdata-sections \
  -I"$plugin_dir/common/cpp/include" \
  -I"$plugin_dir/linux/flutter/include" \
  -I"$plugin_dir/third_party/libwebrtc/include" \
  -I"$flutter_sdk/bin/cache/artifacts/engine/linux-$flutter_arch" \
  "${gtk_flags[@]}" \
  "$plugin_dir/test/native/flutter_video_renderer_test.cc" \
  "$plugin_dir/common/cpp/src/flutter_video_renderer.cc" \
  "$plugin_dir/third_party/libwebrtc/lib/libwebrtc.so" \
  -Wl,-rpath,"$plugin_dir/third_party/libwebrtc/lib" \
  -Wl,--gc-sections -o "$test_binary"
"$test_binary"
