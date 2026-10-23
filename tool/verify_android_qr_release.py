#!/usr/bin/env python3
"""Check that an APK retains ML Kit's reflectively invoked constructors.

Run after a normal minified release build:
    python3 tool/verify_android_qr_release.py build/app/outputs/flutter-apk/app-release.apk

This checks declared DEX methods, not just class-name strings. It does not
replace a camera test on Android, and deliberately needs no Android SDK tools.
"""

import argparse
import json
from pathlib import Path
import re
import struct
import sys
from zipfile import BadZipFile, ZipFile


REGISTRARS = (
    "com.google.mlkit.common.internal.CommonComponentRegistrar",
    "com.google.mlkit.vision.barcode.internal.BarcodeRegistrar",
    "com.google.mlkit.vision.common.internal.VisionCommonRegistrar",
)


class DexError(ValueError):
    """A DEX table cannot be read safely."""


class Dex:
    def __init__(self, data):
        self.data = data
        if len(data) < 112 or not re.fullmatch(rb"dex\n(035|037|038|039|040|041)\x00", data[:8]):
            raise DexError("Unsupported or invalid DEX header")
        if self.u32(40) != 0x12345678:
            raise DexError("Only little-endian DEX is supported")
        self.strings_count, self.strings_offset = self.table(56, 4)
        self.types_count, self.types_offset = self.table(64, 4)
        self.protos_count, self.protos_offset = self.table(72, 12)
        self.methods_count, self.methods_offset = self.table(88, 8)
        self.classes_count, self.classes_offset = self.table(96, 32)

    def u32(self, offset):
        if offset < 0 or offset + 4 > len(self.data):
            raise DexError("DEX offset exceeds file size")
        return struct.unpack_from("<I", self.data, offset)[0]

    def table(self, header_offset, entry_size):
        count, offset = self.u32(header_offset), self.u32(header_offset + 4)
        if offset + count * entry_size > len(self.data):
            raise DexError("DEX table exceeds file size")
        return count, offset

    def uleb(self, offset):
        value = 0
        for shift in range(0, 35, 7):
            if offset >= len(self.data):
                raise DexError("Truncated DEX integer")
            byte = self.data[offset]
            offset += 1
            value |= (byte & 0x7f) << shift
            if not byte & 0x80:
                return value, offset
        raise DexError("Invalid DEX integer")

    def string(self, index):
        if index >= self.strings_count:
            raise DexError("Invalid DEX string index")
        _, offset = self.uleb(self.u32(self.strings_offset + 4 * index))
        end = self.data.find(b"\x00", offset)
        if end < 0:
            raise DexError("Unterminated DEX string")
        # The relevant descriptors and method names are all ASCII; other
        # modified-UTF-8 strings are irrelevant to these checks.
        return self.data[offset:end].decode("utf-8", errors="replace")

    def type_name(self, index):
        if index >= self.types_count:
            raise DexError("Invalid DEX type index")
        return self.string(self.u32(self.types_offset + 4 * index))

    def no_arg_constructor(self, class_index, class_data_offset):
        if class_data_offset == 0:
            return False
        offset = class_data_offset
        sizes = []
        for _ in range(4):
            value, offset = self.uleb(offset)
            sizes.append(value)
        if sum(sizes) > len(self.data):
            raise DexError("Invalid DEX class-data sizes")
        for _ in range(sizes[0] + sizes[1]):
            _, offset = self.uleb(offset)  # field index delta
            _, offset = self.uleb(offset)  # access flags
        for count in sizes[2:]:
            method_index = 0
            for _ in range(count):
                delta, offset = self.uleb(offset)
                method_index += delta
                access_flags, offset = self.uleb(offset)
                code_offset, offset = self.uleb(offset)
                if method_index >= self.methods_count:
                    raise DexError("Invalid DEX method index")
                method_offset = self.methods_offset + method_index * 8
                owner, proto_index, name_index = struct.unpack_from(
                    "<HHI", self.data, method_offset
                )
                if owner != class_index or self.string(name_index) != "<init>":
                    continue
                if proto_index >= self.protos_count:
                    raise DexError("Invalid DEX prototype index")
                proto_offset = self.protos_offset + proto_index * 12
                return_type = self.u32(proto_offset + 4)
                parameters_offset = self.u32(proto_offset + 8)
                has_no_args = parameters_offset == 0 or self.u32(parameters_offset) == 0
                if (has_no_args and self.type_name(return_type) == "V"
                        and access_flags & 0x1 and code_offset != 0):
                    if code_offset + 16 > len(self.data):
                        raise DexError("Truncated DEX constructor code")
                    return True
        return False

    def registrars(self):
        found = {}
        targets = {"L" + name.replace(".", "/") + ";": name for name in REGISTRARS}
        for index in range(self.classes_count):
            offset = self.classes_offset + index * 32
            class_index = self.u32(offset)
            descriptor = self.type_name(class_index)
            if descriptor in targets:
                found[targets[descriptor]] = self.no_arg_constructor(
                    class_index, self.u32(offset + 24)
                )
        return found


def inspect_apk(path):
    found = {}
    dex_files = []
    with ZipFile(path) as archive:
        for name in sorted(archive.namelist()):
            if re.fullmatch(r"classes(?:[2-9]|[1-9][0-9]+)?\.dex", name):
                dex_files.append(name)
                for registrar, retained in Dex(archive.read(name)).registrars().items():
                    if registrar in found:
                        raise DexError("Duplicate registrar definition: " + registrar)
                    found[registrar] = (name, retained)
    if not dex_files:
        raise DexError("No root classes*.dex files found in APK")
    checks = [
        {
            "class": registrar,
            "classPresent": registrar in found,
            "publicNoArgConstructor": found.get(registrar, (None, False))[1],
            "dex": found.get(registrar, (None, False))[0],
        }
        for registrar in REGISTRARS
    ]
    return {
        "apk": str(Path(path).resolve()),
        "dexFiles": dex_files,
        "checks": checks,
        "passed": all(check["publicNoArgConstructor"] for check in checks),
        "cameraRuntimeVerified": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    try:
        result = inspect_apk(args.apk)
    except (OSError, BadZipFile, DexError) as error:
        print(json.dumps({"passed": False, "error": str(error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
