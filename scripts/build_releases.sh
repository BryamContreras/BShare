#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LINUX_ONLY=0
MACOS_ONLY=0
DEB_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --linux-only) LINUX_ONLY=1 ;;
    --macos-only) MACOS_ONLY=1 ;;
    --deb-only) LINUX_ONLY=1; DEB_ONLY=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(grep -E '^version:' pubspec.yaml | head -n1 | sed -E 's/^version:[[:space:]]*//')"
SAFE_VERSION="${VERSION/+/-}"
RELEASE_ROOT="$ROOT/dist/releases/BShare-$SAFE_VERSION"
mkdir -p "$RELEASE_ROOT/linux" "$RELEASE_ROOT/macos"

flutter pub get

OS="$(uname -s)"

if [[ "$OS" == "Linux" && "$MACOS_ONLY" != "1" ]]; then
  flutter build linux --release
  if [[ "$DEB_ONLY" == "1" ]]; then
    "$ROOT/scripts/build_deb.sh" --skip-build
  else
    python3 "$ROOT/tool/packaging_linux.py" --output "$RELEASE_ROOT/linux"
  fi
  echo "Linux DEB/RPM release ready: $RELEASE_ROOT/linux"
fi

if [[ "$OS" == "Darwin" && "$LINUX_ONLY" != "1" ]]; then
  case "$(uname -m)" in
    arm64) MACOS_ARCH=arm64; EXPECTED_ARCH=arm64; EXCLUDED_ARCH=x86_64 ;;
    x86_64) MACOS_ARCH=x64; EXPECTED_ARCH=x86_64; EXCLUDED_ARCH=arm64 ;;
    *) echo "Unsupported macOS host architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  FLUTTER_XCODE_EXCLUDED_ARCHS="$EXCLUDED_ARCH" flutter build macos --release
  MACOS_APP="$ROOT/build/macos/Build/Products/Release/bshare.app"
  MACOS_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$MACOS_APP/Contents/Info.plist")"
  MACOS_BINARY="$MACOS_APP/Contents/MacOS/$MACOS_EXECUTABLE"
  MACOS_ARCHS="$(lipo -archs "$MACOS_BINARY")"
  [[ " $MACOS_ARCHS " == *" $EXPECTED_ARCH "* ]] || {
    echo "Expected $EXPECTED_ARCH macOS binary, found: $MACOS_ARCHS" >&2
    exit 1
  }
  MACOS_STAGING="$RELEASE_ROOT/macos/BShare-dmg-root"
  MACOS_DMG="$RELEASE_ROOT/macos/BShare-$SAFE_VERSION-macos-$MACOS_ARCH.dmg"
  rm -rf "$MACOS_STAGING"
  mkdir -p "$MACOS_STAGING"
  ditto "$MACOS_APP" "$MACOS_STAGING/BShare.app"
  ln -s /Applications "$MACOS_STAGING/Applications"
  hdiutil create -quiet -volname BShare -srcfolder "$MACOS_STAGING" -format UDZO -ov "$MACOS_DMG"
  rm -rf "$MACOS_STAGING"
  shasum -a 256 "$MACOS_DMG" > "$MACOS_DMG.sha256"
  echo "macOS release ready: $RELEASE_ROOT/macos"
fi

if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
  echo "This script builds Linux on Linux and macOS on macOS. Current OS: $OS" >&2
  exit 1
fi
