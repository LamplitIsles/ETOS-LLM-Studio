import importlib.util
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ios_device", Path(__file__).parents[1] / "ios-device.py")
ios_device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios_device)


class IOSDeviceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.app = root / "test.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": ios_device.BUNDLE,
            "CFBundleExecutable": ios_device.EXECUTABLE,
        }))
        (self.app / ios_device.EXECUTABLE).write_bytes(b"test executable")
        (self.app / ios_device.DYLIB).write_bytes(b"test dylib")
        self.manifest = root / "latest-build.json"
        for name, value in (("APP", self.app), ("CACHE", root), ("MANIFEST", self.manifest)):
            active = patch.object(ios_device, name, value)
            active.start()
            self.addCleanup(active.stop)

    def prepare_manifest(self):
        ios_device.save_json(self.manifest, {
            "build_id": "a" * 64,
            "hashes": ios_device.app_hashes(),
            "source": {"revision": "test", "worktree": "test"},
        })

    def test_changed_build_is_rejected_before_signing(self):
        self.prepare_manifest()
        (self.app / ios_device.DYLIB).write_bytes(b"changed")
        with patch.object(ios_device, "source_identity", return_value={"revision": "test", "worktree": "test"}), \
             patch.object(ios_device.subprocess, "check_output") as command:
            with self.assertRaisesRegex(RuntimeError, "构建产物已改变"):
                ios_device.install(None)
            command.assert_not_called()

    def test_unknown_install_is_not_replayed(self):
        self.prepare_manifest()
        ios_device.save_json(ios_device.CACHE / ("ios-install-" + "a" * 64 + ".json"), {"state": "submitted"})
        with patch.object(ios_device, "source_identity", return_value={"revision": "test", "worktree": "test"}), \
             patch.object(ios_device.subprocess, "check_output") as command:
            with self.assertRaisesRegex(RuntimeError, "安装结果未知"):
                ios_device.install(None)
            command.assert_not_called()

    def test_changed_source_is_rejected(self):
        self.prepare_manifest()
        with patch.object(ios_device, "source_identity", return_value={"revision": "new", "worktree": "new"}):
            with self.assertRaisesRegex(RuntimeError, "源码状态"):
                ios_device.install(None)

    def test_paired_iphone_does_not_need_a_preconnected_tunnel(self):
        device = {
            "identifier": "fake-device",
            "hardwareProperties": {"deviceType": "iPhone", "productType": "iPhone14,6"},
            "deviceProperties": {"developerModeStatus": "enabled", "bootState": "booted", "osVersionNumber": "27.0.1"},
            "connectionProperties": {"transportType": "wired", "pairingState": "paired", "tunnelState": "disconnected"},
        }
        self.assertEqual(ios_device.select_device([device], None), device)

    def test_multiple_eligible_phones_require_explicit_selection(self):
        def device(identifier, tunnel):
            return {"identifier": identifier, "hardwareProperties": {"deviceType": "iPhone"},
                    "deviceProperties": {"developerModeStatus": "enabled"},
                    "connectionProperties": {"pairingState": "paired", "tunnelState": tunnel}}
        devices = [device("a", "connected"), device("b", "disconnected")]
        with self.assertRaisesRegex(RuntimeError, "多台.*--device"):
            ios_device.select_device(devices, None)
        self.assertEqual(ios_device.select_device(devices, "b")["identifier"], "b")
        with self.assertRaisesRegex(RuntimeError, "没有找到"):
            ios_device.select_device(devices, "missing")

    def test_unpaired_disabled_and_non_iphone_devices_are_not_candidates(self):
        def device(identifier, kind="iPhone", developer="enabled", pairing="paired"):
            return {"identifier": identifier, "hardwareProperties": {"deviceType": kind},
                    "deviceProperties": {"developerModeStatus": developer},
                    "connectionProperties": {"pairingState": pairing, "tunnelState": "connected"}}
        rejected = [device("unpaired", pairing="unpaired"), device("disabled", developer="disabled"),
                    device("ipad", kind="iPad"), device("unknown-pairing", pairing=None)]
        with self.assertRaisesRegex(RuntimeError, "没有找到"):
            ios_device.select_device(rejected, None)
        for phone in rejected:
            with self.subTest(identifier=phone["identifier"]):
                with self.assertRaisesRegex(RuntimeError, "没有找到"):
                    ios_device.select_device([device("valid"), phone], phone["identifier"])

    def test_install_result_and_replay_guard(self):
        self.prepare_manifest()
        root = ios_device.CACHE
        profiles = root / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        profiles.mkdir(parents=True)
        (profiles / "test.mobileprovision").write_bytes(b"fake")
        certificate = b"fake certificate"
        identity = hashlib.sha1(certificate).hexdigest().upper()
        profile = plistlib.dumps({
            "Entitlements": {"application-identifier": ios_device.TEAM + "." + ios_device.BUNDLE,
                             "com.apple.developer.team-identifier": ios_device.TEAM,
                             "get-task-allow": True,
                             "keychain-access-groups": [ios_device.TEAM + "." + ios_device.BUNDLE]},
            "ProvisionedDevices": ["fake-udid"], "DeveloperCertificates": [certificate],
            "ExpirationDate": datetime.datetime(2099, 1, 1),
        })
        devices = {"result": {"devices": [{"identifier": "fake-device",
                    "hardwareProperties": {"deviceType": "iPhone", "udid": "fake-udid"},
                    "deviceProperties": {"developerModeStatus": "enabled"},
                    "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"}}]}}
        marker = root / ("ios-install-" + "a" * 64 + ".json")
        fail_install = [True]

        def run(command, **kwargs):
            if command[:4] == ["xcrun", "devicectl", "list", "devices"]:
                Path(command[command.index("--json-output") + 1]).write_text(json.dumps(devices))
            if command[:3] == ["security", "cms", "-D"]:
                return subprocess.CompletedProcess(command, 0, stdout=profile)
            if command[:4] == ["xcrun", "devicectl", "device", "install"]:
                self.assertEqual(json.loads(marker.read_text())["state"], "submitted")
                if fail_install[0]:
                    raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(ios_device.Path, "home", return_value=root), \
             patch.object(ios_device, "source_identity", return_value={"revision": "test", "worktree": "test"}), \
             patch.object(ios_device.subprocess, "check_output", return_value=identity), \
             patch.object(ios_device.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                ios_device.install(None)
            self.assertEqual(json.loads(marker.read_text())["state"], "submitted")
            with self.assertRaisesRegex(RuntimeError, "安装结果未知"):
                ios_device.install(None)
            marker.unlink()
            fail_install[0] = False
            ios_device.install(None)
            self.assertEqual(json.loads(marker.read_text())["state"], "succeeded")
            ios_device.install(None)


if __name__ == "__main__":
    unittest.main()
