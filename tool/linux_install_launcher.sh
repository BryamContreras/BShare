#!/usr/bin/env bash
set -eu

app_id="com.bshare.bshare"
app_name="BShare"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
bundle_dir="${1:-"$project_root/build/linux/x64/release/bundle"}"
binary_path="$bundle_dir/bshare"
icon_path="$bundle_dir/share/icons/hicolor/512x512/apps/$app_id.png"

if [ ! -x "$binary_path" ]; then
  printf 'BShare binary was not found at:\n%s\n\n' "$binary_path" >&2
  printf 'Build it first with: flutter build linux\n' >&2
  exit 1
fi

if [ ! -f "$icon_path" ]; then
  icon_path="$bundle_dir/data/flutter_assets/assets/brand/app_icon.png"
fi

if [ ! -f "$icon_path" ]; then
  printf 'BShare icon was not found in the Linux bundle.\n' >&2
  exit 1
fi

applications_dir="$HOME/.local/share/applications"
icons_dir="$HOME/.local/share/icons/hicolor/512x512/apps"
desktop_path="$applications_dir/$app_id.desktop"
installed_icon_path="$icons_dir/$app_id.png"

mkdir -p "$applications_dir" "$icons_dir"
cp "$icon_path" "$installed_icon_path"

cat >"$desktop_path" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Comment=Share files directly on your local network
Exec=$binary_path
Icon=$app_id
Terminal=false
Categories=Network;FileTransfer;
StartupWMClass=$app_id
EOF

chmod 0644 "$desktop_path" "$installed_icon_path"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi

printf 'Installed %s launcher:\n%s\n' "$app_name" "$desktop_path"
