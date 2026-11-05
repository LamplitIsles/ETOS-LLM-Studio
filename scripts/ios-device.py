#!/usr/bin/env python3
"""Build and install the current iOS development app using the existing Mac workspace."""
import argparse
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path.home() / "Library/Caches/ETOS-CFL-4960"
DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/ETOS_LLM_Studio-gbdwtrcvmcilytfthkwwgrxdjqbe"
APP = DERIVED / "Build/Products/Cloud-iphoneos/ETOS LLM Studio App.app"
MANIFEST = CACHE / "latest-build.json"
BUNDLE = "io.guion.etos.cfl4960"
TEAM = "RL5WAW5828"
EXECUTABLE = "ETOS LLM Studio App"
DYLIB = "ETOS LLM Studio App.debug.dylib"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temp = Path(output.name)
        try:
            json.dump(data, output)
            output.flush()
            os.fsync(output.fileno())
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)


def app_hashes():
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE or info.get("CFBundleExecutable") != EXECUTABLE:
        raise RuntimeError("App 标识或可执行文件不匹配。")
    if (APP / "PlugIns").exists():
        raise RuntimeError("当前 App 包含未预期的扩展。")
    return {"executable": digest(APP / EXECUTABLE), "dylib": digest(APP / DYLIB)}


def source_identity():
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    diff = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=ROOT)
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT)
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    fingerprint = hashlib.sha256(diff + b"\0" + status)
    for name in sorted(filter(None, untracked.split(b"\0"))):
        stat = (ROOT / os.fsdecode(name)).lstat()
        fingerprint.update(name + b"\0" + f"{stat.st_mode}:{stat.st_size}:{stat.st_mtime_ns}".encode())
    return {"revision": revision, "worktree": fingerprint.hexdigest()}


def build():
    MANIFEST.unlink(missing_ok=True)
    source = source_identity()
    print("正在构建 ETOS；复用已有 Xcode 构建和依赖缓存。", flush=True)
    subprocess.run([
        "xcodebuild", "-workspace", "ETOS LLM Studio.xcworkspace",
        "-scheme", "ETOS LLM Studio App", "-configuration", "Cloud",
        "-destination", "generic/platform=iOS", "-derivedDataPath", str(DERIVED),
        "-clonedSourcePackagesDirPath", str(DERIVED / "SourcePackages"),
        "-disableAutomaticPackageResolution", "-jobs", "2",
        "SWIFT_OPTIMIZATION_LEVEL=-Onone", "SWIFT_COMPILATION_MODE=incremental",
        "CODE_SIGNING_ALLOWED=NO", "build",
    ], cwd=ROOT, check=True)
    hashes = app_hashes()
    if source_identity() != source:
        raise RuntimeError("构建过程中源码状态发生变化，请重新构建。")
    build_id = hashlib.sha256((hashes["executable"] + hashes["dylib"]).encode()).hexdigest()
    save_json(MANIFEST, {"build_id": build_id, "hashes": hashes, "source": source})
    print("构建完成。安装：python3 scripts/ios-device.py install", flush=True)


def select_device(devices, requested):
    eligible = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
                and d.get("deviceProperties", {}).get("developerModeStatus") == "enabled"
                and d.get("connectionProperties", {}).get("pairingState") == "paired"]
    if requested:
        eligible = [d for d in eligible if d.get("identifier") == requested]
    if not eligible:
        raise RuntimeError("没有找到已配对且开启开发者模式的 iPhone。")
    if len(eligible) > 1:
        raise RuntimeError("找到多台符合条件的 iPhone，请用 --device 指定。")
    return eligible[0]


def install(requested):
    if not MANIFEST.exists():
        raise RuntimeError("没有已准备的构建，请先运行 python3 scripts/ios-device.py build。")
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("source") != source_identity():
        raise RuntimeError("源码状态与构建时不同，请重新构建。")
    if manifest.get("hashes") != app_hashes():
        raise RuntimeError("构建产物已改变，请重新运行构建，避免安装错误版本。")
    build_id = manifest.get("build_id", "")
    if not re.fullmatch(r"[0-9a-f]{64}", build_id):
        raise RuntimeError("构建记录无效，请重新构建。")
    marker = CACHE / ("ios-install-" + build_id + ".json")
    if marker.exists() and json.loads(marker.read_text()).get("state") != "succeeded":
        raise RuntimeError("此构建的安装结果未知；请先确认手机上的安装状态，不要重复提交。")
    print("正在检查证书、设备和描述文件。", flush=True)
    identity_output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True, timeout=30)
    identities = set(re.findall(r"\b[0-9A-F]{40}\b", identity_output))
    with tempfile.TemporaryDirectory(prefix="etos-device-install-") as scratch:
        scratch = Path(scratch)
        device_json = scratch / "devices.json"
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", str(device_json)], check=True, timeout=30)
        device = select_device(json.loads(device_json.read_text())["result"]["devices"], requested)
        udid = device["hardwareProperties"]["udid"]
        selected = None
        profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        for path in profile_dir.glob("*.mobileprovision"):
            result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, timeout=30)
            if result.returncode:
                continue
            profile = plistlib.loads(result.stdout)
            ent = profile.get("Entitlements", {})
            if (ent.get("application-identifier") != TEAM + "." + BUNDLE
                or ent.get("com.apple.developer.team-identifier") != TEAM
                or ent.get("get-task-allow") is not True
                or udid not in profile.get("ProvisionedDevices", [])
                or not any(fnmatch.fnmatchcase(TEAM + "." + BUNDLE, pattern)
                           for pattern in ent.get("keychain-access-groups", []))):
                continue
            expires = profile.get("ExpirationDate")
            now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            if not expires or expires <= now:
                continue
            matches = [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])
                       if hashlib.sha1(cert).hexdigest().upper() in identities]
            if len(matches) == 1:
                selected = (path, matches[0])
                break
        if not selected:
            raise RuntimeError("没有匹配此 App、证书和 iPhone 的有效开发描述文件。")
        profile_path, identity = selected
        entitlements = {"application-identifier": TEAM + "." + BUNDLE,
                        "com.apple.developer.team-identifier": TEAM,
                        "get-task-allow": True, "keychain-access-groups": [TEAM + "." + BUNDLE]}
        ent_path = scratch / "entitlements.plist"
        ent_path.write_bytes(plistlib.dumps(entitlements))
        shutil.copyfile(profile_path, APP / "embedded.mobileprovision")
        print("正在签名。", flush=True)
        for code in sorted((APP / "Frameworks").glob("*.framework")) + sorted(APP.glob("*.dylib")):
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(code)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(code)], check=True)
        subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", "--entitlements", str(ent_path), str(APP)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
        manifest["hashes"] = app_hashes()
        save_json(MANIFEST, manifest)
        print("签名通过，正在安装；不会启动 App。", flush=True)
        save_json(marker, {"state": "submitted"})
        subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", device["identifier"], str(APP), "--timeout", "120"], check=True)
        save_json(marker, {"state": "succeeded"})
        print("安装完成，App 未启动。", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "install"])
    parser.add_argument("--device", help="多台 iPhone 连接时指定设备标识")
    args = parser.parse_args()
    if args.action == "build" and args.device:
        parser.error("--device 仅用于 install")
    if not DERIVED.is_dir() or not CACHE.is_dir():
        raise RuntimeError("既有构建缓存不存在；请先确认工作环境。")
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    with (CACHE / "ios-device.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "build":
            build()
        else:
            install(args.device)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
