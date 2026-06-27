#!/usr/bin/env bash
set -u

failures=0

ok() {
  printf 'OK   %s\n' "$1"
}

warn() {
  printf 'WARN %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

find_executable() {
  if command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
    return 0
  fi
  for path in "/usr/sbin/$1" "/sbin/$1" "/usr/bin/$1" "/bin/$1"; do
    if [ -x "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

have() {
  find_executable "$1" >/dev/null 2>&1
}

check_command() {
  command_path="$(find_executable "$1" || true)"
  if [ -n "$command_path" ]; then
    ok "$1 found: $command_path"
  else
    fail "$1 is missing"
  fi
}

printf 'BShare Linux doctor\n'
printf '===================\n\n'

if [ "$(uname -s)" != "Linux" ]; then
  fail "this script must run on Linux"
else
  ok "running on Linux: $(uname -r)"
fi

printf '\n%s\n' 'Flutter'
printf '%s\n' '-------'
check_command flutter
check_command dart
if have flutter; then
  flutter_path="$(find_executable flutter)"
  case "$flutter_path" in
    /mnt/*)
      fail "Flutter points to a mounted Windows SDK ($flutter_path); install a native Linux Flutter SDK"
      ;;
    *)
      if flutter --version >/tmp/bshare_flutter_version.txt 2>/tmp/bshare_flutter_error.txt; then
        head -n 1 /tmp/bshare_flutter_version.txt
        flutter doctor -v | sed -n '/Linux toolchain/,+4p' || true
      else
        fail "flutter command failed: $(tr '\n' ' ' </tmp/bshare_flutter_error.txt)"
      fi
      ;;
  esac
  rm -f /tmp/bshare_flutter_version.txt /tmp/bshare_flutter_error.txt
fi

printf '\n%s\n' 'Linux desktop build tools'
printf '%s\n' '-------------------------'
for command_name in clang cmake ninja pkg-config; do
  check_command "$command_name"
done

if have pkg-config && pkg-config --exists gtk+-3.0; then
  ok "GTK 3 development files found"
else
  fail "GTK 3 development files are missing (install libgtk-3-dev)"
fi

if have ldconfig && ldconfig -p 2>/dev/null | grep -q 'libstdc++'; then
  ok "libstdc++ runtime found"
else
  warn "could not confirm libstdc++ with ldconfig"
fi

printf '\n%s\n' 'NetworkManager hotspot support'
printf '%s\n' '------------------------------'
if ! have nmcli; then
  fail "nmcli is missing (install NetworkManager/network-manager)"
else
  ok "nmcli found: $(find_executable nmcli)"
  if nmcli -t -f RUNNING general 2>/dev/null | grep -qx 'running'; then
    ok "NetworkManager is running"
  else
    fail "NetworkManager is not running"
  fi

  check_command wpa_supplicant

  dnsmasq_path="$(find_executable dnsmasq || true)"
  if [ -n "$dnsmasq_path" ]; then
    ok "dnsmasq found: $dnsmasq_path"
  else
    fail "dnsmasq is missing (install dnsmasq-base; NetworkManager uses it for hotspot DHCP)"
  fi

  if have pkcheck; then
    ok "polkit found: $(find_executable pkcheck)"
  else
    warn "polkit checker not found (install policykit-1/polkitd if hotspot authorization fails)"
  fi

  if have iw; then
    ok "iw found: $(find_executable iw)"
  else
    warn "iw is missing (install iw to diagnose Wi-Fi AP support)"
  fi

  permissions="$(nmcli -t -f PERMISSION,VALUE general permissions 2>/dev/null || true)"
  if [ -n "$permissions" ]; then
    denied_permissions="$(
      printf '%s\n' "$permissions" |
        awk -F: '$2 == "no" && ($1 == "org.freedesktop.NetworkManager.enable-disable-wifi" || $1 == "org.freedesktop.NetworkManager.network-control" || $1 == "org.freedesktop.NetworkManager.settings.modify.system") { print $1 }'
    )"
    auth_permissions="$(
      printf '%s\n' "$permissions" |
        awk -F: '$2 == "auth" && ($1 == "org.freedesktop.NetworkManager.enable-disable-wifi" || $1 == "org.freedesktop.NetworkManager.network-control" || $1 == "org.freedesktop.NetworkManager.settings.modify.system") { print $1 }'
    )"
    if [ -n "$denied_permissions" ]; then
      fail "user lacks NetworkManager permissions: $(printf '%s' "$denied_permissions" | paste -sd ' ' -)"
    elif [ -n "$auth_permissions" ]; then
      warn "NetworkManager may ask for authentication: $(printf '%s' "$auth_permissions" | paste -sd ' ' -)"
    else
      ok "NetworkManager permissions allow hotspot management"
    fi
  else
    warn "could not read NetworkManager permissions"
  fi

  wifi_devices="$(
    nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null |
      awk -F: '$2 == "wifi" && $3 != "unavailable" && $3 != "unmanaged" { print $1 }'
  )"

  if [ -z "$wifi_devices" ]; then
    fail "no managed Wi-Fi devices were reported by NetworkManager"
  else
    ok "managed Wi-Fi devices: $(printf '%s' "$wifi_devices" | paste -sd ' ' -)"
    ap_device_found=0
    while IFS= read -r device; do
      [ -z "$device" ] && continue
      ap_support="$(nmcli -g WIFI-PROPERTIES.AP device show "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
      if [ "$ap_support" = "yes" ]; then
        ok "$device supports AP/hotspot mode"
        ap_device_found=1
      else
        warn "$device does not report AP/hotspot support"
      fi
    done <<EOF
$wifi_devices
EOF
    if [ "$ap_device_found" -ne 1 ]; then
      fail "no Wi-Fi adapter with AP/hotspot support was found"
    fi
  fi
fi

printf '\n%s\n' 'Project'
printf '%s\n' '-------'
if [ -f pubspec.yaml ] && [ -d lib ] && [ -d linux ]; then
  ok "looks like the BShare project root"
else
  fail "run this script from the BShare project root"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  ok "Linux environment is ready for BShare"
else
  fail "$failures check(s) failed"
fi

exit "$failures"
