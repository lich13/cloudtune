"""Verify unsigned iOS ARM64 IPA: Info.plist ATS rules, Mach-O platform IOS (rejecting IOSSIMULATOR), and path privacy."""
from __future__ import annotations

from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Callable
import zipfile

from verify_native_privacy import verify_native_binary


def default_vtool_runner(binary_path: Path) -> str:
    return subprocess.check_output(
        ["/usr/bin/vtool", "-arch", "arm64", "-show-build", str(binary_path)],
        text=True,
        stderr=subprocess.STDOUT,
    )


def verify_ats_policy(plist_data: dict) -> None:
    ats = plist_data.get("NSAppTransportSecurity")
    if not isinstance(ats, dict):
        raise ValueError("Info.plist missing NSAppTransportSecurity dictionary")
    if ats.get("NSAllowsArbitraryLoads") is True:
        raise ValueError("Info.plist must not enable NSAllowsArbitraryLoads")
    domains = ats.get("NSExceptionDomains")
    if not isinstance(domains, dict) or list(domains.keys()) != ["127.0.0.1"]:
        raise ValueError("Info.plist NSExceptionDomains must strictly contain only 127.0.0.1")
    loopback = domains["127.0.0.1"]
    if not isinstance(loopback, dict) or loopback.get("NSExceptionAllowsInsecureHTTPLoads") is not True:
        raise ValueError("127.0.0.1 exception must enable NSExceptionAllowsInsecureHTTPLoads")


def verify_vtool_ios_device_output(vtool_output: str) -> None:
    platforms = re.findall(r"^\s*platform\s+([A-Z0-9_]+)\s*$", vtool_output, re.MULTILINE)
    if not platforms:
        raise ValueError("vtool output contains no LC_BUILD_VERSION platform entry")
    if "IOSSIMULATOR" in platforms:
        raise ValueError("IPA contains IOSSIMULATOR binary instead of physical device IOS arm64")
    if platforms != ["IOS"]:
        raise ValueError(f"expected Mach-O platform ['IOS'], got {platforms}")


def verify_ipa(
    ipa_path: Path,
    vtool_runner: Callable[[Path], str] = default_vtool_runner,
) -> None:
    scratch = Path(tempfile.mkdtemp(prefix="cloudtune-verify-ipa-"))
    try:
        with zipfile.ZipFile(ipa_path) as zf:
            names = zf.namelist()
            plist_entries = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
            if len(plist_entries) != 1:
                raise ValueError(f"expected exactly one Payload/*.app/Info.plist, found {len(plist_entries)}")
            plist_entry = plist_entries[0]
            app_prefix = plist_entry[: -len("Info.plist")]

            info = plistlib.loads(zf.read(plist_entry))
            verify_ats_policy(info)

            executable_name = info.get("CFBundleExecutable")
            if not isinstance(executable_name, str) or not executable_name:
                raise ValueError("Info.plist missing CFBundleExecutable")

            exec_entry = f"{app_prefix}{executable_name}"
            if exec_entry not in names:
                raise ValueError(f"IPA missing executable {exec_entry}")

            exec_bytes = zf.read(exec_entry)
            verify_native_binary(exec_bytes)

            extracted_bin = scratch / executable_name
            extracted_bin.write_bytes(exec_bytes)
            vtool_text = vtool_runner(extracted_bin)
            verify_vtool_ios_device_output(vtool_text)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("expected one IPA path", file=sys.stderr)
        return 1
    try:
        verify_ipa(Path(sys.argv[1]).resolve(strict=True))
    except Exception as err:
        print(str(err), file=sys.stderr)
        return 1
    print("PASS: iOS ARM64 device IPA (platform IOS, 127.0.0.1 ATS only, path privacy ok)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
