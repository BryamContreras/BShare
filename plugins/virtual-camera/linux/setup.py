#!/usr/bin/python3
"""Installer-owned Linux virtual camera setup; never unloads another module.

Only one exact BShare-labelled v4l2loopback device and BShare's systemd units
are managed. Missing kernel headers, signing/enrolment and external driver
repositories are reported as availability conditions, not bypassed.
"""
from __future__ import annotations
import argparse
import json
import fcntl
import os
from pathlib import Path
import pwd
import re
import subprocess
import stat
import tempfile

LABEL = 'BShare Virtual Camera'
PREFIX = Path(__file__).resolve().parents[2]
STATE = Path('/var/lib/bshare/virtual-camera-status.json')
SYSFS = Path('/sys/devices/virtual/video4linux')
DEVICE_ROOT = Path('/dev')
DEVICE_CLASS = Path('/sys/class/video4linux')
MODULE = Path('/sys/module/v4l2loopback')
KERNEL_HEADERS = Path('/lib/modules') / os.uname().release / 'build'


def run(arguments, *, timeout=15):
    return subprocess.run(list(map(str, arguments)), capture_output=True, text=True,
                          timeout=timeout, check=False)


def owned_device(device):
    if not re.fullmatch(r'/dev/video[0-9]{1,3}', str(device)):
        return False
    try:
        result = run([PREFIX / 'bshare-camera', '--inspect-device', device])
        return result.returncode == 0 and json.loads(result.stdout).get('owned') is True
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def find_owned():
    for entry in sorted(SYSFS.glob('video*')):
        try:
            if (entry / 'name').read_text().strip() == LABEL:
                candidate = DEVICE_ROOT / entry.name
                if owned_device(candidate):
                    return candidate
        except OSError:
            continue
    return None


def save_status(value):
    STATE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if STATE.parent.is_symlink() or STATE.is_symlink():
        raise ValueError('Refusing a symlink for machine virtual-camera state')
    owner = STATE.parent.stat()
    if owner.st_uid != 0 or (owner.st_mode & 0o022):
        raise ValueError('Machine virtual-camera state directory must be root-owned')
    if STATE.exists() and (not STATE.is_file() or STATE.stat().st_uid != 0):
        raise ValueError('Machine virtual-camera state must be a root-owned file')
    with tempfile.NamedTemporaryFile(prefix='.virtual-camera-', dir=STATE.parent,
                                     delete=False, mode='w', encoding='utf8') as temporary:
        temporary.write(json.dumps(value) + '\n')
        path = Path(temporary.name)
    try:
        path.chmod(0o644)
        os.replace(path, STATE)
    finally:
        path.unlink(missing_ok=True)


def dynamic_devices_supported():
    # Jammy's 0.12.5 ctl is a shell script with only set-* commands. Loading
    # that driver with devices=0 would leave no camera and no way to add one.
    # Both the userspace add command and the >=0.13 kernel API are required.
    try:
        help_result = run(['v4l2loopback-ctl', '--help'])
        if not re.search(r'\badd\s+[\[{]', help_result.stdout + help_result.stderr):
            return False
        if MODULE.exists():
            version = (MODULE / 'version').read_text().strip()
        else:
            version = run(['modinfo', '-F', 'version', 'v4l2loopback']).stdout.strip()
        match = re.match(r'(\d+)\.(\d+)(?:\.(\d+))?', version)
        return bool(match and tuple(int(part or 0) for part in match.groups()) >= (0, 13, 0))
    except (OSError, subprocess.SubprocessError):
        return False


def available_devices():
    for number in range(63, 31, -1):
        candidate = DEVICE_ROOT / f'video{number}'
        if not candidate.exists() and not (DEVICE_CLASS / candidate.name).exists():
            yield candidate


def loaded_result(arguments):
    try:
        loaded = run(['modprobe', 'v4l2loopback', *arguments])
    except (OSError, subprocess.SubprocessError):
        return {'ready': False, 'reason': 'kernel-module-unavailable'}
    if loaded.returncode:
        stderr = loaded.stderr.lower()
        if 'key was rejected' in stderr or 'required key' in stderr or 'signature' in stderr:
            reason = 'kernel-signature-rejected'
        elif not KERNEL_HEADERS.exists():
            reason = 'kernel-headers-unavailable'
        else:
            reason = 'kernel-module-unavailable'
        return {'ready': False, 'reason': reason}
    run(['udevadm', 'settle', '--timeout=5'])
    return None


def verified_result(candidate):
    if owned_device(candidate):
        return {'ready': True, 'device': str(candidate), 'deviceName': LABEL, 'reason': ''}
    return {'ready': False, 'reason': 'kernel-device-verification-failed'}


def ensure_device():
    existing = find_owned()
    if existing:
        return verified_result(existing)
    dynamic = dynamic_devices_supported()
    if MODULE.exists() and not dynamic:
        # An old driver already serving OBS cannot add another device. Never
        # unload/reload it or replace its parameters to make space for BShare.
        return {'ready': False, 'reason': 'unsupported-driver-version'}
    if not MODULE.exists():
        if not dynamic:
            candidate = next(available_devices(), None)
            if candidate is None:
                return {'ready': False, 'reason': 'kernel-device-creation-failed'}
            failure = loaded_result(['devices=1', f'video_nr={candidate.name[5:]}',
                                     f'card_label={LABEL}', 'exclusive_caps=1',
                                     'max_width=1280', 'max_height=720', 'max_buffers=2'])
            return failure or verified_result(candidate)
        # Only drivers that support subsequent dynamic add are loaded empty.
        failure = loaded_result(['devices=0'])
        if failure:
            return failure
    try:
        for candidate in available_devices():
            created = run(['v4l2loopback-ctl', 'add', '-n', LABEL, '-x', '1',
                           '-w', '1280', '-h', '720', '-b', '2', str(candidate)])
            if created.returncode == 0:
                run(['udevadm', 'settle', '--timeout=5'])
                return verified_result(candidate)
            if not candidate.exists():
                return {'ready': False, 'reason': 'kernel-device-creation-failed'}
        return {'ready': False, 'reason': 'kernel-device-creation-failed'}
    except FileNotFoundError:
        return {'ready': False, 'reason': 'driver-tools-unavailable'}


def graphical_users():
    try:
        sessions = run(['loginctl', 'list-sessions', '--no-legend', '--no-pager'])
        users = set()
        for row in sessions.stdout.splitlines():
            fields = row.split()
            if not fields or not re.fullmatch(r'[A-Za-z0-9_-]+', fields[0]):
                continue
            values = run(['loginctl', 'show-session', fields[0], '--property=User',
                          '--property=Active', '--property=Type']).stdout.splitlines()
            properties = dict(line.split('=', 1) for line in values if '=' in line)
            if properties.get('Active') != 'yes' or properties.get('Type') not in ['x11', 'wayland']:
                continue
            uid = int(properties.get('User', '0'))
            if uid > 0 and (Path('/run/user') / str(uid) / 'bus').exists():
                users.add(uid)
        return users
    except (OSError, ValueError, subprocess.SubprocessError):
        return set()


def user_services(operation):
    for uid in graphical_users():
        try:
            name = pwd.getpwuid(uid).pw_name
            environment = [f'XDG_RUNTIME_DIR=/run/user/{uid}',
                           f'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus']
            base = ['runuser', '-u', name, '--', 'env', *environment, 'systemctl', '--user']
            run([*base, 'daemon-reload'])
            run([*base, operation, 'bshare-virtual-camera.service'])
        except (KeyError, OSError, subprocess.SubprocessError):
            continue


def configure(action, start_users=True):
    if os.geteuid() != 0:
        return {'ready': False, 'reason': 'administrator-required'}
    if action == 'remove':
        user_services('stop')
        run(['systemctl', '--global', 'disable', 'bshare-virtual-camera.service'])
        run(['systemctl', 'disable', 'bshare-virtual-camera-setup.service'])
        existing = find_owned()
        if existing and dynamic_devices_supported():
            # Busy consumers may retain this one device until the next boot.
            # Do not kill OBS, force removal, or unload the shared kernel module.
            run(['v4l2loopback-ctl', 'delete', str(existing)])
        return {'ready': False, 'reason': 'component-removed'}
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', '--global', 'enable', 'bshare-virtual-camera.service'])
    run(['systemctl', 'enable', 'bshare-virtual-camera-setup.service'])
    lock = os.open('/run/lock/bshare-virtual-camera-setup.lock',
                   os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        details = os.fstat(lock)
        if details.st_uid != 0 or not stat.S_ISREG(details.st_mode):
            raise ValueError('Setup lock is not a root-owned regular file')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result = {'ready': False, 'reason': 'setup-in-progress'}
        else:
            result = ensure_device()
            save_status(result)
    finally:
        os.close(lock)
    if start_users:
        user_services('start')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['ensure', 'remove', 'status'])
    parser.add_argument('--no-user-start', action='store_true')
    args = parser.parse_args()
    try:
        if args.action == 'status':
            result = json.loads(STATE.read_text()) if STATE.is_file() else {'ready': False, 'reason': 'not-configured'}
        else:
            result = configure(args.action, not args.no_user_start)
    except (OSError, ValueError, subprocess.SubprocessError):
        result = {'ready': False, 'reason': 'setup-incomplete'}
        if os.geteuid() == 0:
            try:
                save_status(result)
            except OSError:
                pass
    print(json.dumps(result))
    # The app can still install when this kernel requires headers, a reboot or
    # native signing approval. Availability is reported by the status/helper UI.


if __name__ == '__main__':
    main()
