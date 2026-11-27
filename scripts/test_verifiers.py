from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

from verify_android import (
    ELFCLASS64,
    ELFDATA2LSB,
    ELF_MAGIC,
    EM_AARCH64,
    PT_LOAD,
    verify_apk_archive_and_manifest,
)
from verify_ipa import verify_ipa
from verify_native_privacy import verify_native_binary


def make_elf64_so(p_align: int = 0x4000, machine: int = EM_AARCH64, extra_payload: bytes = b"") -> bytes:
    e_ident = ELF_MAGIC + bytes([ELFCLASS64, ELFDATA2LSB, 1]) + b"\x00" * 9
    ehdr = e_ident + struct.pack(
        "<HHIQQQIHHHHHH",
        3,
        machine,
        1,
        0,
        64,
        0,
        0,
        64,
        56,
        1,
        0,
        0,
        0,
    )
    phdr = struct.pack("<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0, 120, 120, p_align)
    return ehdr + phdr + extra_payload


class VerifierSuiteTests(unittest.TestCase):
    def _build_zip(self, suffix: str, entries: dict[str, bytes]) -> Path:
        tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
        tmp.close()
        path = Path(tmp.name)
        with zipfile.ZipFile(path, "w") as zf:
            for name, content in entries.items():
                zf.writestr(name, content)
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        return path

    def test_native_privacy_rejects_home_and_temp_paths_without_echoing(self):
        for secret in (
            b"/Users/fixture-secret/Library/Developer/Xcode/DerivedData/app",
            b"/home/fixture-secret/workspace/build/output",
            b"/private/var/folders/cd/z987/C/fixture-secret/cache",
        ):
            with self.assertRaises(ValueError) as raised:
                verify_native_binary(secret)
            self.assertNotIn("fixture-secret", str(raised.exception))

        verify_native_binary(b"/build/CloudTune/Sources/CloudTuneCore/Models.swift")

    def test_verify_ipa_accepts_device_ios_and_rejects_simulator_or_bad_ats(self):
        good_plist = plistlib.dumps({
            "CFBundleExecutable": "CloudTuneIOS",
            "NSAppTransportSecurity": {
                "NSAllowsArbitraryLoads": False,
                "NSExceptionDomains": {
                    "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True},
                },
            },
        })
        ipa = self._build_zip(".ipa", {
            "Payload/CloudTuneIOS.app/Info.plist": good_plist,
            "Payload/CloudTuneIOS.app/CloudTuneIOS": b"\xcf\xfa\xed\xfe-clean-arm64-macho",
        })
        verify_ipa(ipa, vtool_runner=lambda _: "Load command 1\n      cmd LC_BUILD_VERSION\n platform IOS\n    minos 17.0\n")

        with self.assertRaisesRegex(ValueError, "IOSSIMULATOR"):
            verify_ipa(
                ipa,
                vtool_runner=lambda _: "Load command 1\n      cmd LC_BUILD_VERSION\n platform IOSSIMULATOR\n    minos 17.0\n",
            )

        bad_ats_plist = plistlib.dumps({
            "CFBundleExecutable": "CloudTuneIOS",
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        })
        bad_ipa = self._build_zip(".ipa", {
            "Payload/CloudTuneIOS.app/Info.plist": bad_ats_plist,
            "Payload/CloudTuneIOS.app/CloudTuneIOS": b"\xcf\xfa\xed\xfe-clean",
        })
        with self.assertRaisesRegex(ValueError, "NSAllowsArbitraryLoads"):
            verify_ipa(bad_ipa, vtool_runner=lambda _: " platform IOS\n")

    def test_verify_android_checks_16k_elf_manifest_security_and_abi(self):
        good_xmltree = "E: application\n  A: android:networkSecurityConfig(0x01010527)=@0x7f0e0001\n"
        badging = "sdkVersion:'31'\ntargetSdkVersion:'36'\nnative-code: 'arm64-v8a'\n"

        apk_ok = self._build_zip(".apk", {
            "classes.dex": b"dex\n039\x00clean-bytecode",
            "lib/arm64-v8a/libandroidx.graphics.path.so": make_elf64_so(0x4000),
            "res/mipmap-hdpi-v4/ic_launcher.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + struct.pack(">II", 72, 72) + b"\x08\x06\x00\x00\x00",
        })
        self.assertEqual(verify_apk_archive_and_manifest(apk_ok, badging, good_xmltree), 1)

        apk_bad_hdpi = self._build_zip(".apk", {
            "classes.dex": b"dex\n039\x00clean-bytecode",
            "lib/arm64-v8a/libandroidx.graphics.path.so": make_elf64_so(0x4000),
            "res/mipmap-hdpi-v4/ic_launcher.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + struct.pack(">II", 49, 49) + b"\x08\x06\x00\x00\x00",
        })
        with self.assertRaisesRegex(ValueError, "72x72 hdpi"):
            verify_apk_archive_and_manifest(apk_bad_hdpi, badging, good_xmltree)

        apk_4k = self._build_zip(".apk", {
            "classes.dex": b"dex\n039\x00clean",
            "lib/arm64-v8a/libbad.so": make_elf64_so(0x1000),
        })
        with self.assertRaisesRegex(ValueError, "4 KB ELF"):
            verify_apk_archive_and_manifest(apk_4k, badging, good_xmltree)

        with self.assertRaisesRegex(ValueError, "usesCleartextTraffic"):
            verify_apk_archive_and_manifest(
                apk_ok,
                badging,
                good_xmltree + "  A: android:usesCleartextTraffic(0x010104ec)=(type 0x12)0xffffffff\n",
            )


if __name__ == "__main__":
    unittest.main()
