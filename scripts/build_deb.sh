#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --help|-h)
      echo "Usage: scripts/build_deb.sh [--skip-build]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

for command in dpkg dpkg-deb sed; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "This package build currently supports amd64 hosts only." >&2
  exit 1
fi

VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+).*/\1/p' pubspec.yaml | head -n1)"
if [[ -z "$VERSION" ]]; then
  echo "Could not read the application version from pubspec.yaml." >&2
  exit 1
fi

# Flutter uses + for its build number; in a Debian version it is the package
# revision separator, so 1.0.2+3 becomes 1.0.2-3.
DEB_VERSION="${VERSION/+/-}"
RELEASE_ROOT="$ROOT/dist/releases/BShare-$DEB_VERSION/linux"
BUNDLE="$ROOT/build/linux/x64/release/bundle"

if [[ "$SKIP_BUILD" != "1" ]]; then
  flutter build linux --release
fi

for required_path in \
  "$BUNDLE/bshare" \
  "$BUNDLE/data" \
  "$BUNDLE/lib" \
  "$BUNDLE/share/applications/com.bshare.bshare.desktop" \
  "$BUNDLE/share/icons/hicolor/512x512/apps/com.bshare.bshare.png"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Linux bundle is incomplete: $required_path" >&2
    exit 1
  fi
done

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bshare-deb.XXXXXX")"
PACKAGE_ROOT="$STAGING_ROOT/root"
trap 'rm -rf "$STAGING_ROOT"' EXIT

install -d \
  "$PACKAGE_ROOT/DEBIAN" \
  "$PACKAGE_ROOT/opt/bshare" \
  "$PACKAGE_ROOT/usr/bin" \
  "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps"

cp -a "$BUNDLE/bshare" "$BUNDLE/data" "$BUNDLE/lib" "$PACKAGE_ROOT/opt/bshare/"
find "$PACKAGE_ROOT/opt/bshare" -type d -exec chmod 0755 {} +
find "$PACKAGE_ROOT/opt/bshare" -type f -exec chmod 0644 {} +
chmod 0755 "$PACKAGE_ROOT/opt/bshare/bshare"
install -m 0755 packaging/debian/bshare-wrapper "$PACKAGE_ROOT/usr/bin/bshare"
install -m 0644 "$BUNDLE/share/applications/com.bshare.bshare.desktop" \
  "$PACKAGE_ROOT/usr/share/applications/com.bshare.bshare.desktop"
install -m 0644 "$BUNDLE/share/icons/hicolor/512x512/apps/com.bshare.bshare.png" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps/com.bshare.bshare.png"

sed "s/@VERSION@/$DEB_VERSION/g" packaging/debian/control.in > "$PACKAGE_ROOT/DEBIAN/control"
install -m 0755 packaging/debian/postinst "$PACKAGE_ROOT/DEBIAN/postinst"
install -m 0755 packaging/debian/postrm "$PACKAGE_ROOT/DEBIAN/postrm"

mkdir -p "$RELEASE_ROOT"
PACKAGE_FILE="$RELEASE_ROOT/bshare_${DEB_VERSION}_amd64.deb"
rm -f "$PACKAGE_FILE"
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$PACKAGE_FILE" >/dev/null

echo "Debian package ready: $PACKAGE_FILE"
dpkg-deb --info "$PACKAGE_FILE" | sed -n '1,80p'
