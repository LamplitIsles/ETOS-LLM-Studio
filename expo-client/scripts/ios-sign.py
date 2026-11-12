#!/usr/bin/env python3
"""Sign an existing Expo iOS app with an already provisioned development identity."""
import argparse
import datetime
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

BUNDLE = "studio.etos.expo.dev"


class ToolError(RuntimeError):
    pass


def command(args):
    try:
        return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120).stdout
    except subprocess.TimeoutExpired:
        raise ToolError("{} 执行超时。".format(args[0])) from None
    except subprocess.CalledProcessError as error:
        reason = ""
        if args[0] == "codesign":
            stderr = (error.stderr or b"").decode("utf-8", errors="replace")
            match = re.search(r"\b(?:errSec[A-Za-z]{1,50}|CSSMERR_[A-Z0-9_]{1,50})\b", stderr)
            if match:
                reason = ": " + match.group(0)
            elif "User interaction is not allowed" in stderr:
                reason = ": 钥匙串不允许用户交互"
        raise ToolError("{} 失败（退出码 {}）{}。".format(args[0], error.returncode, reason)) from None


def matching_profile(data, bundle, team, udid, identities, now):
    entitlements = data.get("Entitlements", {})
    app_id = team + "." + bundle
    expires = data.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        return None
    if expires.tzinfo is not None:
        expires = expires.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    if (expires <= now or team not in data.get("TeamIdentifier", [])
            or entitlements.get("com.apple.developer.team-identifier") != team
            or entitlements.get("get-task-allow") is not True
            or udid not in data.get("ProvisionedDevices", [])
            or not fnmatch.fnmatchcase(app_id, entitlements.get("application-identifier", ""))
            or not any(fnmatch.fnmatchcase(app_id, pattern) for pattern in entitlements.get("keychain-access-groups", []))):
        return None
    for cert in data.get("DeveloperCertificates", []):
        digest = hashlib.sha1(cert).hexdigest().upper()
        if digest in identities:
            return digest
    return None


def sign(app, device_file, team, entitlements_file, profile_dir, run=command):
    print("正在检查已有 App、设备和开发签名。", flush=True)
    if not app.is_dir():
        raise RuntimeError("未找到已有 App 产物，请先运行对应的 ios:build 命令。")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = info.get("CFBundleExecutable")
    if (info.get("CFBundleIdentifier") != BUNDLE or not isinstance(executable, str)
            or Path(executable).name != executable or not (app / executable).is_file()):
        raise RuntimeError("App 标识或可执行文件无效，请先重新构建。")
    if any(app.rglob("*.appex")):
        raise RuntimeError("App 包含不支持的扩展，无法签名。")
    configured = plistlib.loads(entitlements_file.read_bytes())
    if not isinstance(configured, dict) or configured:
        raise RuntimeError("原生工程配置了非空 entitlements；此签名工具不支持，请在 Xcode 中处理。")
    udid = json.loads(device_file.read_text()).get("udid")
    if not isinstance(udid, str) or not udid.strip():
        raise RuntimeError("设备缺少 UDID，无法匹配开发描述文件。")
    identities = set(re.findall(r"\b[0-9A-F]{40}\b", run(["security", "find-identity", "-v", "-p", "codesigning"]).decode()))
    embedded = app / "embedded.mobileprovision"
    paths = ([embedded] if embedded.is_file() else []) + sorted(profile_dir.glob("*.mobileprovision"))
    selected = None
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    for path in paths:
        try:
            profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
            identity = matching_profile(profile, BUNDLE, team, udid, identities, now)
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError, ToolError):
            continue
        if identity:
            selected = (path, identity)
            break
    if not selected:
        raise RuntimeError("没有匹配此 App、iPhone 和证书的有效开发描述文件；请先在 Mac Xcode 中准备开发签名。")
    profile_path, identity = selected
    app_id = team + "." + BUNDLE
    entitlements = {"application-identifier": app_id, "com.apple.developer.team-identifier": team,
                    "get-task-allow": True, "keychain-access-groups": [app_id]}
    with tempfile.TemporaryDirectory(prefix="etos-expo-sign-") as temp:
        ent_path = Path(temp) / "entitlements.plist"
        ent_path.write_bytes(plistlib.dumps(entitlements))
        if profile_path != embedded:
            shutil.copyfile(profile_path, embedded)
        nested = [p for p in app.rglob("*") if (p.is_dir() and p.suffix == ".framework")
                  or (p.is_file() and p.suffix == ".dylib")]
        nested.sort(key=lambda p: (-len(p.parts), str(p)))
        print("正在签名嵌套代码和 App。", flush=True)
        for code in nested:
            run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(code)])
        run(["codesign", "--force", "--sign", identity, "--timestamp=none", "--entitlements", str(ent_path), str(app)])
        print("正在验证 App 签名。", flush=True)
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
    print("已有 App 签名验证通过，准备安装。", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--device-file", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    args = parser.parse_args()
    profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    sign(args.app, args.device_file, args.team, args.entitlements, profile_dir)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        if isinstance(error, subprocess.SubprocessError):
            raise SystemExit("签名或签名验证失败；请检查 Mac 开发签名后重试。")
        raise SystemExit(str(error))
