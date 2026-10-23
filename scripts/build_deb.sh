#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

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

for command in python3 sed; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+).*/\1/p' pubspec.yaml | head -n1)"
if [[ -z "$VERSION" ]]; then
  echo "Could not read the application version from pubspec.yaml." >&2
  exit 1
fi

# Flutter uses + for its build number; in a Debian version it is the package
# revision separator, so 1.0.2+3 becomes 1.0.2-3.
DEB_VERSION="${VERSION/+/-}"
RELEASE_ROOT="$project_root/dist/releases/BShare-$DEB_VERSION/linux"

if [[ "$SKIP_BUILD" != "1" ]]; then
  flutter build linux --release
fi

python3 tool/packaging_linux.py --formats deb --output "$RELEASE_ROOT"
