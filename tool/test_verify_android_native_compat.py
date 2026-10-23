import struct
import tempfile
import unittest
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

from verify_android_native_compat import inspect_apk, inspect_elf


def elf64(*, alignment=16384, machine=183, virtual_address=0):
    data = bytearray(256)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<H', data, 18, machine)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<I', data, 64, 1)  # PT_LOAD
    struct.pack_into('<QQ', data, 72, 0, virtual_address)
    struct.pack_into('<Q', data, 112, alignment)
    return bytes(data)


class NativeCompatibilityTest(unittest.TestCase):
    def inspect_archive(self, libraries, *, required=(), compressed=True):
        with tempfile.TemporaryDirectory(prefix='bshare-native-compat-') as folder:
            apk = Path(folder) / 'native.apk'
            with ZipFile(apk, 'w', ZIP_DEFLATED if compressed else ZIP_STORED) as archive:
                for path, data in libraries.items():
                    archive.writestr(path, data)
            return inspect_apk(apk, required)

    def test_16k_and_64k_elf_alignment(self):
        for alignment in (16384, 65536):
            self.assertTrue(inspect_elf(elf64(alignment=alignment))['elf16kAligned'])

    def test_4k_and_incongruent_load_segments_fail(self):
        self.assertFalse(inspect_elf(elf64(alignment=4096))['elf16kAligned'])
        self.assertFalse(inspect_elf(elf64(virtual_address=4096))['elf16kAligned'])

    def test_invalid_or_truncated_elf_rejected(self):
        for data in (b'invalid', elf64()[:80]):
            with self.assertRaises(ValueError):
                inspect_elf(data)

    def test_complete_matching_compressed_abi_sets_pass(self):
        report = self.inspect_archive({
            'lib/arm64-v8a/libapp.so': elf64(),
            'lib/x86_64/libapp.so': elf64(machine=62),
        }, required=('arm64-v8a', 'x86_64'))
        self.assertTrue(report['passed'])
        self.assertFalse(report['runtimeVerified'])

    def test_missing_required_abi_fails(self):
        report = self.inspect_archive({
            'lib/arm64-v8a/libapp.so': elf64(),
        }, required=('armeabi-v7a',))
        self.assertFalse(report['checks']['requiredAbisPresent'])

    def test_partial_library_set_fails(self):
        report = self.inspect_archive({
            'lib/arm64-v8a/libapp.so': elf64(),
            'lib/arm64-v8a/libwebrtc.so': elf64(),
            'lib/x86_64/libapp.so': elf64(machine=62),
        })
        self.assertFalse(report['checks']['eachPackagedAbiHasCompleteLibrarySet'])

    def test_mislabeled_elf_machine_fails(self):
        report = self.inspect_archive({
            'lib/arm64-v8a/libapp.so': elf64(machine=62),
        })
        self.assertFalse(report['checks']['allElfMachinesMatchAbi'])

    def test_unaligned_uncompressed_zip_fails(self):
        report = self.inspect_archive({
            'lib/arm64-v8a/libapp.so': elf64(),
        }, compressed=False)
        self.assertFalse(report['libraries'][0]['zip16kAligned'])
        self.assertFalse(report['checks']['all64BitLibraries16kPackaged'])


if __name__ == '__main__':
    unittest.main()
