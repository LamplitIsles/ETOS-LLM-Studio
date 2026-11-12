import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

script = Path(__file__).resolve().parents[1] / "scripts" / "ios-sign.py"
spec = importlib.util.spec_from_file_location("ios_sign", script)
ios_sign = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios_sign)

TEAM = "FAKETEAM"
UDID = "fake-udid"
CERT = b"synthetic-certificate"
IDENTITY = hashlib.sha1(CERT).hexdigest().upper()


def profile():
    app_id = TEAM + "." + ios_sign.BUNDLE
    return {"TeamIdentifier": [TEAM], "ExpirationDate": datetime.datetime(2099, 1, 1),
            "ProvisionedDevices": [UDID], "DeveloperCertificates": [CERT],
            "Entitlements": {"application-identifier": app_id,
                             "com.apple.developer.team-identifier": TEAM,
                             "get-task-allow": True, "keychain-access-groups": [app_id]}}


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="etos-sign-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "ETOSExpo.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": ios_sign.BUNDLE, "CFBundleExecutable": "ETOSExpo"}))
        (self.app / "ETOSExpo").write_bytes(b"fake executable")
        self.config = self.root / "entitlements.plist"
        self.config.write_bytes(plistlib.dumps({}))
        self.device = self.root / "device.json"
        self.device.write_text(json.dumps({"udid": UDID}))
        self.profiles = self.root / "profiles"
        self.profiles.mkdir()
        self.embedded = self.app / "embedded.mobileprovision"
        self.embedded.write_bytes(plistlib.dumps(profile()))
        self.calls = []
        self.signed_entitlements = None

    def run_fake(self, args):
        self.calls.append(args)
        if args[:2] == ["security", "find-identity"]:
            return (IDENTITY + " fake identity").encode()
        if args[:2] == ["security", "cms"]:
            return Path(args[-1]).read_bytes()
        if args[0] == "codesign" and "--entitlements" in args:
            self.signed_entitlements = plistlib.loads(Path(args[args.index("--entitlements") + 1]).read_bytes())
        return b""

    def sign(self, run=None):
        ios_sign.sign(self.app, self.device, TEAM, self.config, self.profiles, run=run or self.run_fake)

    def test_valid_profile_signs_nested_code_inside_out_then_app_and_verifies(self):
        frameworks = self.app / "Frameworks"
        nested = frameworks / "Outer.framework" / "Frameworks" / "Inner.framework"
        nested.mkdir(parents=True)
        dylib = nested / "inner.dylib"
        dylib.write_bytes(b"fake")
        self.sign()
        signed = [Path(c[-1]) for c in self.calls if c[0] == "codesign" and "--sign" in c]
        self.assertEqual(signed, [dylib, nested, frameworks / "Outer.framework", self.app])
        self.assertEqual(self.calls[-1], ["codesign", "--verify", "--deep", "--strict", str(self.app)])
        app_id = TEAM + "." + ios_sign.BUNDLE
        self.assertEqual(self.signed_entitlements, {"application-identifier": app_id,
            "com.apple.developer.team-identifier": TEAM, "get-task-allow": True,
            "keychain-access-groups": [app_id]})

    def test_embedded_profile_preferred_and_directory_fallback_used(self):
        alternate = self.profiles / "alternative.mobileprovision"
        alternate.write_bytes(plistlib.dumps(profile()))
        self.sign()
        decoded = [c[-1] for c in self.calls if c[:2] == ["security", "cms"]]
        self.assertEqual(decoded, [str(self.embedded)])
        self.calls.clear()
        invalid = profile()
        invalid["ProvisionedDevices"] = ["other"]
        self.embedded.write_bytes(plistlib.dumps(invalid))
        self.sign()
        self.assertEqual(self.embedded.read_bytes(), alternate.read_bytes())

    def test_profile_checks_app_team_device_expiration_certificate_and_development(self):
        now = datetime.datetime(2026, 1, 1)
        self.assertEqual(ios_sign.matching_profile(profile(), ios_sign.BUNDLE, TEAM, UDID, {IDENTITY}, now), IDENTITY)
        for mutation in ("app", "team", "device", "expired", "cert", "development", "keychain"):
            with self.subTest(mutation=mutation):
                data = profile()
                if mutation == "app": data["Entitlements"]["application-identifier"] = TEAM + ".other"
                if mutation == "team": data["TeamIdentifier"] = ["OTHER"]
                if mutation == "device": data["ProvisionedDevices"] = ["other"]
                if mutation == "expired": data["ExpirationDate"] = datetime.datetime(2020, 1, 1)
                if mutation == "cert": data["DeveloperCertificates"] = [b"another certificate"]
                if mutation == "development": data["Entitlements"]["get-task-allow"] = False
                if mutation == "keychain": data["Entitlements"]["keychain-access-groups"] = ["OTHER.*"]
                self.assertIsNone(ios_sign.matching_profile(data, ios_sign.BUNDLE, TEAM, UDID, {IDENTITY}, now))

    def test_unmatched_profile_and_unsupported_capabilities_do_not_sign(self):
        for reason in ("profile", "entitlements", "appex"):
            with self.subTest(reason=reason):
                if reason == "profile":
                    bad = profile()
                    bad["ProvisionedDevices"] = ["other"]
                    self.embedded.write_bytes(plistlib.dumps(bad))
                elif reason == "entitlements":
                    self.embedded.write_bytes(plistlib.dumps(profile()))
                    self.config.write_bytes(plistlib.dumps({"aps-environment": "development"}))
                else:
                    self.config.write_bytes(plistlib.dumps({}))
                    (self.app / "Widget.appex").mkdir()
                self.calls.clear()
                with self.assertRaises(RuntimeError): self.sign()
                self.assertFalse(any(c[0] == "codesign" for c in self.calls))

    def test_codesign_errors_show_bounded_reason_without_private_output(self):
        stderr = ("private-udid " + IDENTITY + " errSecInternalComponent secret-profile").encode()
        failure = subprocess.CalledProcessError(1, ["codesign"], stderr=stderr)
        with mock.patch.object(ios_sign.subprocess, "run", side_effect=failure):
            with self.assertRaises(ios_sign.ToolError) as raised:
                ios_sign.command(["codesign", "--sign", IDENTITY])
        message = str(raised.exception)
        self.assertIn("codesign", message)
        self.assertIn("errSecInternalComponent", message)
        for private in ("private-udid", IDENTITY, "secret-profile"):
            self.assertNotIn(private, message)
        with mock.patch.object(ios_sign.subprocess, "run", side_effect=failure):
            with self.assertRaises(ios_sign.ToolError) as raised:
                ios_sign.command(["security", "cms"])
        self.assertNotIn("errSecInternalComponent", str(raised.exception))
        self.assertNotIn(IDENTITY, str(raised.exception))

    def test_cms_failure_skips_candidate(self):
        alternate = self.profiles / "alternative.mobileprovision"
        alternate.write_bytes(plistlib.dumps(profile()))
        def bad_embedded(args):
            if args[:2] == ["security", "cms"] and args[-1] == str(self.embedded):
                raise ios_sign.ToolError("security 失败")
            return self.run_fake(args)
        self.sign(bad_embedded)
        self.assertEqual(self.embedded.read_bytes(), alternate.read_bytes())

    def test_signing_error_stops_before_app(self):
        framework = self.app / "Frameworks" / "Kit.framework"
        framework.mkdir(parents=True)
        def fail(args):
            if args[0] == "codesign":
                self.calls.append(args)
                raise subprocess.CalledProcessError(1, args)
            return self.run_fake(args)
        with self.assertRaises(subprocess.CalledProcessError): self.sign(fail)
        self.assertEqual([Path(c[-1]) for c in self.calls if c[0] == "codesign"], [framework])


if __name__ == "__main__":
    unittest.main()
