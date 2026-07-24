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
  LINUX_BUNDLE="$ROOT/build/linux/x64/release/bundle"
  if [[ "$DEB_ONLY" != "1" ]]; then
    LINUX_TARGET="$RELEASE_ROOT/linux/BShare-linux-x64"
    rm -rf "$LINUX_TARGET"
    mkdir -p "$LINUX_TARGET"
    cp -a "$LINUX_BUNDLE/." "$LINUX_TARGET/"
    tar -C "$RELEASE_ROOT/linux" -czf "$RELEASE_ROOT/linux/BShare-$SAFE_VERSION-linux-x64.tar.gz" "BShare-linux-x64"
  fi
  "$ROOT/scripts/build_deb.sh" --skip-build
  echo "Linux release ready: $RELEASE_ROOT/linux"
fi

if [[ "$OS" == "Darwin" && "$LINUX_ONLY" != "1" ]]; then
  flutter build macos --release
  MACOS_APP="$ROOT/build/macos/Build/Products/Release/bshare.app"
  MACOS_TARGET="$RELEASE_ROOT/macos/BShare.app"
  rm -rf "$MACOS_TARGET"
  cp -a "$MACOS_APP" "$MACOS_TARGET"
  ditto -c -k --sequesterRsrc --keepParent "$MACOS_TARGET" "$RELEASE_ROOT/macos/BShare-$SAFE_VERSION-macos.zip"
  echo "macOS release ready: $RELEASE_ROOT/macos"
fi

if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
  echo "This script builds Linux on Linux and macOS on macOS. Current OS: $OS" >&2
  exit 1
fi
