#!/usr/bin/env python3
"""Inspect APK ABI coverage and 16 KB native library packaging without a device.

This checks ELF LOAD alignment and ZIP data offsets. It does not substitute for
running the app on each Android/API/ABI or on a device booted with 16 KB pages.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from zipfile import ZIP_STORED, ZipFile


ABI_MACHINES = {
    'armeabi-v7a': (32, 40),
    'arm64-v8a': (64, 183),
    'x86': (32, 3),
    'x86_64': (64, 62),
}


def inspect_elf(data):
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[4] not in (1, 2):
        raise ValueError('Invalid or unsupported ELF header')
    if data[5] not in (1, 2):
        raise ValueError('Invalid ELF byte order')
    endian = '<' if data[5] == 1 else '>'
    bits = 32 if data[4] == 1 else 64
    machine = struct.unpack_from(endian + 'H', data, 18)[0]
    if bits == 64:
        offset = struct.unpack_from(endian + 'Q', data, 32)[0]
        entry_size, count = struct.unpack_from(endian + 'HH', data, 54)
        minimum_size = 56
    else:
        offset = struct.unpack_from(endian + 'I', data, 28)[0]
        entry_size, count = struct.unpack_from(endian + 'HH', data, 42)
        minimum_size = 32
    if entry_size < minimum_size or offset + entry_size * count > len(data):
        raise ValueError('Truncated ELF program headers')
    segments = []
    for index in range(count):
        start = offset + index * entry_size
        if struct.unpack_from(endian + 'I', data, start)[0] != 1:
            continue  # PT_LOAD
        if bits == 64:
            file_offset, virtual_address = struct.unpack_from(
                endian + 'QQ', data, start + 8,
            )
            alignment = struct.unpack_from(endian + 'Q', data, start + 48)[0]
        else:
            file_offset, virtual_address = struct.unpack_from(
                endian + 'II', data, start + 4,
            )
            alignment = struct.unpack_from(endian + 'I', data, start + 28)[0]
        segments.append({
            'alignment': alignment,
            'offset': file_offset,
            'virtualAddress': virtual_address,
            'compatible16k': alignment >= 16384
            and (virtual_address - file_offset) % 16384 == 0,
        })
    if not segments:
        raise ValueError('ELF contains no LOAD segment')
    return {
        'bits': bits,
        'machine': machine,
        'loadSegments': segments,
        'elf16kAligned': all(segment['compatible16k'] for segment in segments),
    }


def inspect_apk(path, required_abis=(), aapt2=None):
    path = Path(path)
    raw = path.read_bytes()
    libraries = []
    abi_libraries = {}
    with ZipFile(path) as archive:
        for entry in archive.infolist():
            match = re.fullmatch(r'lib/([^/]+)/([^/]+\.so)', entry.filename)
            if not match:
                continue
            abi, name = match.groups()
            elf = inspect_elf(archive.read(entry))
            if raw[entry.header_offset:entry.header_offset + 4] != b'PK\x03\x04':
                raise ValueError('Invalid ZIP local header')
            name_size, extra_size = struct.unpack_from(
                '<HH', raw, entry.header_offset + 26,
            )
            data_offset = entry.header_offset + 30 + name_size + extra_size
            compressed = entry.compress_type != ZIP_STORED
            abi_match = ABI_MACHINES.get(abi) == (elf['bits'], elf['machine'])
            needs_16k = elf['bits'] == 64
            libraries.append({
                'entry': entry.filename,
                'abi': abi,
                'sha256': hashlib.sha256(archive.read(entry)).hexdigest(),
                **elf,
                'machineMatchesAbi': abi_match,
                'compressed': compressed,
                'zipDataOffset': data_offset,
                'zip16kAligned': data_offset % 16384 == 0,
                # 16 KB devices use the 64-bit ABIs; 32-bit LOAD alignment
                # is retained as evidence rather than rejected as a failure.
                'packaging16kCompatible': not needs_16k or (
                    elf['elf16kAligned'] and (compressed or data_offset % 16384 == 0)
                ),
            })
            abi_libraries.setdefault(abi, set()).add(name)
    all_names = set().union(*abi_libraries.values()) if abi_libraries else set()
    sdk = None
    if aapt2:
        result = subprocess.run(
            [str(aapt2), 'dump', 'badging', str(path)],
            check=True, text=True, capture_output=True,
        )
        minimum = re.search(
            r"^(?:minSdkVersion|sdkVersion):'(\d+)'", result.stdout, re.MULTILINE,
        )
        target = re.search(r"^targetSdkVersion:'(\d+)'", result.stdout, re.MULTILINE)
        sdk = {
            'minSdk': int(minimum.group(1)) if minimum else None,
            'targetSdk': int(target.group(1)) if target else None,
        }
    checks = {
        'nativeLibrariesPresent': bool(libraries),
        'requiredAbisPresent': set(required_abis).issubset(abi_libraries),
        'eachPackagedAbiHasCompleteLibrarySet': bool(abi_libraries)
        and all(names == all_names for names in abi_libraries.values()),
        'allElfMachinesMatchAbi': all(lib['machineMatchesAbi'] for lib in libraries),
        'all64BitLibraries16kPackaged': all(
            lib['packaging16kCompatible'] for lib in libraries
        ),
    }
    return {
        'apk': str(path.resolve()),
        'bytes': len(raw),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'sdk': sdk,
        'requiredAbis': list(required_abis),
        'packagedAbis': sorted(abi_libraries),
        'librariesByAbi': {abi: sorted(names) for abi, names in abi_libraries.items()},
        'libraries': libraries,
        'checks': checks,
        'passed': all(checks.values()),
        'runtimeVerified': False,
        'scope': 'Static APK ABI, ELF and ZIP inspection only; no device/API/16 KB runtime claim.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--require-abi', action='append', default=[])
    parser.add_argument('--aapt2', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = inspect_apk(args.apk, args.require_abi, args.aapt2)
    encoded = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
        print(json.dumps({
            'passed': report['passed'],
            'packagedAbis': report['packagedAbis'],
            'sdk': report['sdk'],
            'sha256': report['sha256'],
            'output': str(args.output),
        }))
    else:
        print(encoded, end='')
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
