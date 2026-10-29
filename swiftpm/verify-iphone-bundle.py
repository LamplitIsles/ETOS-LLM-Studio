#!/usr/bin/env python3
"""Check ad-hoc Mach-O hashes and bundle resource seals, without Apple credentials.

This is an integrity check, not Apple's codesign verification or a device test.
"""
import hashlib
import math
import plistlib
import re
import struct
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_keychain_metadata(info, entitlements, prefix):
    group = f"{prefix}.com.ericterminal.els.shared"
    require(entitlements.get("keychain-access-groups") == [group],
            "main shared keychain entitlement has the wrong prefix")
    require(info.get("AppIdentifierPrefix") == prefix + ".",
            "main Info.plist has the wrong AppIdentifierPrefix")
    require(info.get("ETKeychainAccessGroup") == group,
            "main Info.plist keychain group differs from the entitlement")


def be32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def require_nested_seals(parent, child):
    seals = plistlib.loads((parent / "_CodeSignature/CodeResources").read_bytes())["files2"]
    executable = plistlib.loads((child / "Info.plist").read_bytes())["CFBundleExecutable"]
    for path in (child / executable, child / "Info.plist", child / "_CodeSignature/CodeResources"):
        require(str(path.relative_to(parent)) in seals, f"{parent}: nested resource is not sealed: {path}")


def verify_executable(bundle, expected_entitlements=None):
    info = (bundle / "Info.plist").read_bytes()
    executable = plistlib.loads(info)["CFBundleExecutable"]
    data = (bundle / executable).read_bytes()
    require(data[:4] == b"\xcf\xfa\xed\xfe", f"{bundle}: expected 64-bit little-endian Mach-O")
    count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    signature = None
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= len(data), f"{bundle}: invalid load command")
        if command == 0x1D:
            start, length = struct.unpack_from("<II", data, offset + 8)
            signature = data[start:start + length]
        offset += size
    require(signature is not None and be32(signature, 0) == 0xFADE0CC0, f"{bundle}: missing signature")
    length, count = struct.unpack_from(">II", signature, 4)
    require(length <= len(signature), f"{bundle}: truncated signature")
    blobs = {}
    for i in range(count):
        slot, start = struct.unpack_from(">II", signature, 12 + 8 * i)
        size = be32(signature, start + 4)
        require(start + size <= length, f"{bundle}: truncated signature blob")
        blobs[slot] = signature[start:start + size]
    cd = blobs[0]
    require(be32(cd, 0) == 0xFADE0C02, f"{bundle}: invalid CodeDirectory")
    _, flags, hash_offset, _, special, pages, limit = struct.unpack_from(">7I", cd, 8)
    hash_size, hash_type, _, page_log = struct.unpack_from("4B", cd, 36)
    require(flags & 2 and hash_size == 32 and hash_type == 2, f"{bundle}: expected SHA-256 ad-hoc signature")
    require(limit <= len(data), f"{bundle}: invalid code limit")
    require(pages == math.ceil(limit / (1 << page_log)), f"{bundle}: invalid code page count")
    for i in range(pages):
        page = data[i * (1 << page_log):min((i + 1) * (1 << page_log), limit)]
        require(hashlib.sha256(page).digest() == cd[hash_offset + i * 32:hash_offset + (i + 1) * 32],
                f"{bundle}: code page {i} hash mismatch")
    resources = (bundle / "_CodeSignature/CodeResources").read_bytes()
    special_data = {1: info, 2: blobs.get(2), 3: resources, 5: blobs.get(5), 7: blobs.get(7)}
    for slot in range(1, special + 1):
        actual = cd[hash_offset - slot * 32:hash_offset - (slot - 1) * 32]
        content = special_data.get(slot)
        require(actual == (hashlib.sha256(content).digest() if content is not None else bytes(32)),
                f"{bundle}: special slot {slot} mismatch or unsupported")
    for name, seal in plistlib.loads(resources)["files2"].items():
        require(isinstance(seal, dict) and "hash2" in seal, f"{bundle}: unsupported resource seal {name}")
        path = bundle / name
        require(path.is_file() and hashlib.sha256(path.read_bytes()).digest() == seal["hash2"],
                f"{bundle}: resource mismatch {name}")
    if expected_entitlements is not None:
        require(5 in blobs and plistlib.loads(blobs[5][8:]) == plistlib.loads(expected_entitlements.read_bytes()),
                f"{bundle}: embedded entitlements differ")
    print(f"{bundle}: {pages} code pages, special slots and resource hashes verified"
          + ("; entitlements match" if expected_entitlements is not None else ""))


def main():
    require(len(sys.argv) == 4, "usage: verify-iphone-bundle.py <app> <main-entitlements.plist> <app-identifier-prefix>")
    app = Path(sys.argv[1])
    root = Path(__file__).resolve().parent.parent
    bundles = {
        app: Path(sys.argv[2]),
        app / "PlugIns/ETOSShare.appex": root / "ETOS LLM Studio/ETOS Agent Share/ETOS Agent ShareDebug.entitlements",
        app / "PlugIns/ETOSWidgets.appex": root / "ETOS LLM Studio/ETOS Agent Widgets/ETOS Agent WidgetsDebug.entitlements",
        app / "PlugIns/ETOSWorkspaceProvider.appex": root / "ETOS LLM Studio/ETOS Workspace Provider/ETOS_Workspace_Provider.entitlements",
    }
    expected_ids = {
        app: "com.ericterminal.els",
        app / "PlugIns/ETOSShare.appex": "com.ericterminal.els.share",
        app / "PlugIns/ETOSWidgets.appex": "com.ericterminal.els.widgets",
        app / "PlugIns/ETOSWorkspaceProvider.appex": "com.ericterminal.els.workspace-provider",
    }
    baseline = plistlib.loads((root / "ETOS LLM Studio/ETOS LLM Studio iOS App/ETOS LLM Studio iOS App.entitlements").read_bytes())
    effective = plistlib.loads(bundles[app].read_bytes())
    prefix = sys.argv[3]
    require(re.fullmatch(r"[A-Za-z0-9]+", prefix) is not None, "invalid App ID prefix")
    def expand(value):
        if isinstance(value, str): return value.replace("$(AppIdentifierPrefix)", prefix + ".")
        if isinstance(value, list): return [expand(item) for item in value]
        if isinstance(value, dict): return {key: expand(item) for key, item in value.items()}
        return value
    require(effective == expand(baseline), "main entitlements differ from the expanded project entitlements")
    require(set((app / "PlugIns").glob("*.appex")) == set(expected_ids) - {app}, "unexpected extension bundles")
    app_info = plistlib.loads((app / "Info.plist").read_bytes())
    verify_keychain_metadata(app_info, effective, prefix)
    print(f"main keychain access group: {effective['keychain-access-groups'][0]}")
    for bundle, entitlements in bundles.items():
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        require(info["CFBundleIdentifier"] == expected_ids[bundle], f"{bundle}: incorrect bundle ID")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            require(info[key] == app_info[key], f"{bundle}: version differs from app")
        if bundle != app:
            require_nested_seals(app, bundle)
        verify_executable(bundle, entitlements)
        for framework in (bundle / "Frameworks").glob("*.framework"):
            require_nested_seals(bundle, framework)
            verify_executable(framework)
    for bundle in [app, app / "PlugIns/ETOSWidgets.appex"]:
        require((bundle / "Assets.car").read_bytes().startswith(b"BOMStore"), f"{bundle}: invalid asset catalog")
    app_assets = (app / "Assets.car").read_bytes()
    require(b"AppIconDisplay" in app_assets and b"AccentColor" in app_assets,
            "app asset catalog is missing named app assets")
    icons = app_info["CFBundleIcons"]["CFBundlePrimaryIcon"]
    require(icons["CFBundleIconName"] == "AppIcon" and icons["CFBundleIconFiles"], "missing primary app icon metadata")
    for name in icons["CFBundleIconFiles"]:
        require(any(app.glob(f"{name}*.png")), f"missing icon file for {name}")
    require(b"$(AppIdentifierPrefix)" not in bundles[app].read_bytes(), "main entitlement has unresolved AppIdentifierPrefix")
    print("Integrity checks passed; Apple validation and device execution were not performed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, struct.error, plistlib.InvalidFileException) as error:
        print(f"bundle verification failed: {error}", file=sys.stderr)
        sys.exit(1)
