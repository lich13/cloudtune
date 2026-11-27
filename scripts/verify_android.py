"""Verify the installable ARM64 Android APK (signature, 16 KB ELF alignment, SDK bounds, manifest cleartext security, ABI, and path privacy)."""
from __future__ import annotations

import os
from pathlib import Path
import re
import struct
import subprocess
import sys
from typing import Callable
import zipfile

from verify_native_privacy import verify_native_binary

ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2
ELFDATA2LSB = 1
EM_AARCH64 = 183
PT_LOAD = 1
PAGE_ALIGNMENT_16K = 0x4000


def run_tool(*args: str | Path) -> str:
    return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT)


def parse_elf64_aarch64_load_alignments(data: bytes) -> list[int]:
    if len(data) < 64 or data[:4] != ELF_MAGIC:
        raise ValueError("invalid ELF64 header")
    if data[4] != ELFCLASS64 or data[5] != ELFDATA2LSB:
        raise ValueError("expected 64-bit little-endian ELF")

    (
        _e_type,
        e_machine,
        _e_version,
        _e_entry,
        e_phoff,
        _e_shoff,
        _e_flags,
        _e_ehsize,
        e_phentsize,
        e_phnum,
        _e_shentsize,
        _e_shnum,
        _e_shstrndx,
    ) = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)

    if e_machine != EM_AARCH64:
        raise ValueError(f"expected EM_AARCH64 (183), got {e_machine}")
    if e_phentsize < 56 or e_phnum == 0:
        raise ValueError("missing ELF64 program headers")

    alignments: list[int] = []
    for idx in range(e_phnum):
        offset = e_phoff + idx * e_phentsize
        if offset + 56 > len(data):
            raise ValueError("truncated ELF64 program header table")
        p_type, _p_flags, _p_offset, _p_vaddr, _p_paddr, _p_filesz, _p_memsz, p_align = struct.unpack_from(
            "<IIQQQQQQ", data, offset
        )
        if p_type == PT_LOAD:
            alignments.append(p_align)
    if not alignments:
        raise ValueError("ELF64 contains no PT_LOAD segments")
    return alignments


def verify_merged_manifest_xmltree(xmltree_text: str) -> None:
    if "networkSecurityConfig" not in xmltree_text:
        raise ValueError("merged AndroidManifest.xml missing android:networkSecurityConfig")
    if re.search(r"usesCleartextTraffic.*=\(type 0x12\)0xffffffff", xmltree_text):
        raise ValueError("merged AndroidManifest.xml must not set usesCleartextTraffic=true")


def verify_apk_archive_and_manifest(
    apk_path: Path,
    badging_text: str,
    xmltree_text: str | None = None,
) -> int:
    if not re.search(r"^(?:minSdkVersion|sdkVersion):'31'$", badging_text, re.MULTILINE):
        raise ValueError("expected minSdkVersion:'31' in APK manifest")
    if "targetSdkVersion:'36'" not in badging_text:
        raise ValueError("expected targetSdkVersion:'36' in APK manifest")
    if xmltree_text is not None:
        verify_merged_manifest_xmltree(xmltree_text)

    native_code_lines = re.findall(r"^(?:alt-)?native-code:\s*(.+)$", badging_text, re.MULTILINE)
    declared_abis = [abi for line in native_code_lines for abi in re.findall(r"'([^']+)'", line)]

    with zipfile.ZipFile(apk_path) as package:
        names = package.namelist()
        lib_entries = [n for n in names if n.startswith("lib/") and not n.endswith("/")]
        non_arm64 = [n for n in lib_entries if not n.startswith("lib/arm64-v8a/")]
        if non_arm64:
            raise ValueError(f"APK contains non-arm64-v8a lib entries: {non_arm64[0]}")

        so_entries = [n for n in lib_entries if n.endswith(".so")]
        dex_entries = [n for n in names if re.fullmatch(r"classes\d*\.dex", n)]
        if not dex_entries:
            raise ValueError("APK contains no classes*.dex payload")

        for dex_name in dex_entries:
            verify_native_binary(package.read(dex_name))

        hdpi_icons = [n for n in names if re.fullmatch(r"res/mipmap-hdpi(?:-[^/]+)?/ic_launcher\.png", n)]
        for icon_name in hdpi_icons:
            icon_bytes = package.read(icon_name)
            if len(icon_bytes) < 24 or icon_bytes[:8] != b"\x89PNG\r\n\x1a\n":
                raise ValueError(f"invalid PNG header in {icon_name}")
            width, height = struct.unpack_from(">II", icon_bytes, 16)
            if (width, height) != (72, 72):
                raise ValueError(f"expected 72x72 hdpi launcher icon in {icon_name}, got {width}x{height}")

        if so_entries:
            if declared_abis != ["arm64-v8a"]:
                raise ValueError(f"APK with native libraries must declare only arm64-v8a, got {declared_abis}")
            for so_name in so_entries:
                so_bytes = package.read(so_name)
                verify_native_binary(so_bytes)
                alignments = parse_elf64_aarch64_load_alignments(so_bytes)
                if min(alignments) < PAGE_ALIGNMENT_16K:
                    raise ValueError(f"4 KB ELF segment alignment in {so_name}: {hex(min(alignments))}")
        else:
            if native_code_lines:
                raise ValueError(f"pure DEX APK must not declare native-code, got {declared_abis}")

        return len(so_entries)


def verify(
    apk: Path,
    sdk_root: Path | None = None,
    runner: Callable[..., str] = run_tool,
) -> None:
    sdk = sdk_root or Path(os.environ["ANDROID_HOME"])
    build_tools = sdk / "build-tools/37.0.0"
    runner(build_tools / "apksigner", "verify", "--verbose", apk)
    runner(build_tools / "zipalign", "-c", "-P", "16", "4", apk)
    manifest = runner(build_tools / "aapt2", "dump", "badging", apk)
    xmltree = runner(build_tools / "aapt2", "dump", "xmltree", apk, "--file", "AndroidManifest.xml")
    so_count = verify_apk_archive_and_manifest(apk, manifest, xmltree)
    mode = f"{so_count} arm64-v8a native libraries (16 KB ELF)" if so_count else "pure DEX (0 native libraries)"
    print(f"PASS: signed ARM64 APK, Android 12+ (target 36), {mode}, networkSecurityConfig & 16 KB zipalign & path privacy ok")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
