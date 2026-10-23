#!/usr/bin/env python3
"""Unit tests for DEX table inspection; synthetic files do not run on Android."""

from pathlib import Path
import struct
from tempfile import TemporaryDirectory
import unittest
from zipfile import ZipFile

from verify_android_qr_release import DexError, REGISTRARS, inspect_apk


def uleb(value):
    result = bytearray()
    while True:
        byte = value & 0x7f
        value >>= 7
        result.append(byte | (0x80 if value else 0))
        if not value:
            return result


def dex_fixture(names=REGISTRARS, *, declared=True, public=True, has_argument=False):
    """Build only the DEX tables used by the reader, plus constructor code."""
    descriptors = ["L" + name.replace(".", "/") + ";" for name in names]
    strings = descriptors + ["V", "I", "<init>"]
    count = len(names)
    strings_offset = 112
    types_offset = strings_offset + 4 * len(strings)
    protos_offset = types_offset + 4 * (count + 2)
    methods_offset = protos_offset + 12
    classes_offset = methods_offset + 8 * count
    data = bytearray(classes_offset + 32 * count)
    data[:8] = b"dex\n035\x00"
    struct.pack_into("<I", data, 40, 0x12345678)
    for header, size, offset in [
        (56, len(strings), strings_offset),
        (64, count + 2, types_offset),
        (72, 1, protos_offset),
        (88, count, methods_offset),
        (96, count, classes_offset),
    ]:
        struct.pack_into("<II", data, header, size, offset)
    for index, string in enumerate(strings):
        struct.pack_into("<I", data, strings_offset + 4 * index, len(data))
        data.extend(uleb(len(string)) + string.encode("ascii") + b"\x00")
    for index in range(count + 2):
        struct.pack_into("<I", data, types_offset + 4 * index, index)
    parameters_offset = 0
    if has_argument:
        parameters_offset = len(data)
        data.extend(struct.pack("<IH", 1, count + 1))
    struct.pack_into("<III", data, protos_offset, count, count, parameters_offset)
    # Minimal code item; only existence of the code header is inspected.
    code_offset = len(data)
    data.extend(bytes(16) + b"\x0e\x00")
    for index in range(count):
        struct.pack_into("<HHI", data, methods_offset + 8 * index, index, 0, count + 2)
        class_data_offset = len(data)
        data.extend(uleb(0) + uleb(0) + uleb(1 if declared else 0) + uleb(0))
        if declared:
            data.extend(uleb(index) + uleb(0x10001 if public else 0x10002) + uleb(code_offset))
        struct.pack_into("<I", data, classes_offset + 32 * index, index)
        struct.pack_into("<I", data, classes_offset + 32 * index + 24, class_data_offset)
    return data


class VerifyAndroidQrReleaseTest(unittest.TestCase):
    def inspect(self, files):
        with TemporaryDirectory(prefix="bshare-qr-dex-test-") as directory:
            path = Path(directory) / "test.apk"
            with ZipFile(path, "w") as archive:
                for name, data in files.items():
                    archive.writestr(name, data)
            return inspect_apk(path)

    def test_public_no_arg_constructors_are_retained_across_dex_files(self):
        result = self.inspect({
            "classes.dex": dex_fixture(REGISTRARS[:1]),
            "classes2.dex": dex_fixture(REGISTRARS[1:]),
        })
        self.assertTrue(result["passed"])
        self.assertEqual(3, len(result["checks"]))
        self.assertFalse(result["cameraRuntimeVerified"])

    def test_class_and_method_name_strings_do_not_prove_a_declared_constructor(self):
        result = self.inspect({"classes.dex": dex_fixture(declared=False)})
        self.assertFalse(result["passed"])
        self.assertTrue(all(check["classPresent"] for check in result["checks"]))
        self.assertFalse(any(check["publicNoArgConstructor"] for check in result["checks"]))

    def test_missing_registrar_fails(self):
        result = self.inspect({"classes.dex": dex_fixture(REGISTRARS[:-1])})
        self.assertFalse(result["passed"])
        self.assertFalse(result["checks"][-1]["classPresent"])

    def test_private_constructor_fails(self):
        self.assertFalse(self.inspect({"classes.dex": dex_fixture(public=False)})["passed"])

    def test_constructor_with_arguments_fails(self):
        self.assertFalse(self.inspect({"classes.dex": dex_fixture(has_argument=True)})["passed"])

    def test_invalid_dex_fails(self):
        with self.assertRaises(DexError):
            self.inspect({"classes.dex": b"not a dex"})

    def test_no_dex_fails(self):
        with self.assertRaises(DexError):
            self.inspect({"assets/classes.dex": dex_fixture()})

    def test_duplicate_definition_fails(self):
        with self.assertRaises(DexError):
            self.inspect({"classes.dex": dex_fixture(), "classes2.dex": dex_fixture()})


if __name__ == "__main__":
    unittest.main()
