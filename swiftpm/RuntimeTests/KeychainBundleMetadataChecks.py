#!/usr/bin/env python3
"""Exercise bundle metadata checks with in-memory, non-user values."""
import importlib.util
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "verify_iphone_bundle", Path(__file__).resolve().parent.parent / "verify-iphone-bundle.py"
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

prefix = "TESTPREFIX"
group = f"{prefix}.com.ericterminal.els.shared"
info = {"AppIdentifierPrefix": prefix + ".", "ETKeychainAccessGroup": group}
entitlements = {"keychain-access-groups": [group]}
checker.verify_keychain_metadata(info, entitlements, prefix)

for invalid_info, invalid_entitlements in (
    ({}, entitlements),
    ({"ETKeychainAccessGroup": group}, entitlements),
    ({"AppIdentifierPrefix": prefix + "."}, entitlements),
    ({**info, "AppIdentifierPrefix": prefix}, entitlements),
    ({**info, "ETKeychainAccessGroup": "OTHER.group"}, entitlements),
    (info, {"keychain-access-groups": ["OTHER.group"]}),
    (info, {}),
):
    try:
        checker.verify_keychain_metadata(invalid_info, invalid_entitlements, prefix)
    except ValueError:
        continue
    raise AssertionError("invalid keychain metadata was accepted")

print("keychain bundle metadata checks passed")
