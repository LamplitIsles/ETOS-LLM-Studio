#!/bin/sh
set -eu

# 仅在 Xcode Cloud 环境优先使用官方仓库路径，便于脚本在云端与本地都可运行。
ROOT_PATH="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
IOS_PLIST_PATH="$ROOT_PATH/ETOS LLM Studio/Config/iOSInfo.plist"

# 云端构建写入完整 Commit，界面展示时再截为 7 位；源码向导必须依赖精确版本。
# CI_COMMIT 缺失时输出 LocalBuild，仅供旧 Swift 产品的本地路径；Expo 分支另行拒绝空值。
commit_hash() {
    if [ -n "${CI_COMMIT:-}" ]; then
        COMMIT_HASH="$(printf '%s' "$CI_COMMIT" | tr '[:upper:]' '[:lower:]')"
        case "$COMMIT_HASH" in
            *[!0-9a-f]*)
                echo "CI_COMMIT 不是有效的 Git 提交哈希" >&2
                exit 1
                ;;
        esac
        if [ "${#COMMIT_HASH}" -ne 40 ]; then
            echo "CI_COMMIT 必须是完整 40 位 Git 提交哈希" >&2
            exit 1
        fi
        printf '%s\n' "$COMMIT_HASH"
    else
        printf 'LocalBuild\n'
    fi
}

# Expo 开发壳：Debug 编译，归档由 Xcode Cloud 的 App Store 分发签名完成。
# 不使用 Info.plist 里的 PlistBuddy 步骤，也不运行旧 Swift 产品的扩展本地化检查。
EXPO_SCHEME="ETOSExpo Dev Archive"

if [ "${CI_XCODE_SCHEME:-}" = "$EXPO_SCHEME" ]; then
    EXPO_PLIST_PATH="$ROOT_PATH/expo-client/ios/ETOSExpo/Info.plist"
    BUILD_NUMBER="${CI_BUILD_NUMBER:-}"
    case "$BUILD_NUMBER" in
        ''|*[!0-9]*|0|0*)
            echo "CI_BUILD_NUMBER 必须是正整数构建号：${BUILD_NUMBER}" >&2
            exit 1
            ;;
    esac
    if [ -z "${CI_COMMIT:-}" ]; then
        echo "缺少 CI_COMMIT：Expo 开发壳归档必须携带来源提交。" >&2
        exit 1
    fi
    COMMIT_HASH="$(commit_hash)"
    if [ ! -f "$EXPO_PLIST_PATH" ]; then
        echo "未找到 plist 文件：$EXPO_PLIST_PATH" >&2
        exit 1
    fi
    python3 - "$EXPO_PLIST_PATH" "$BUILD_NUMBER" "$COMMIT_HASH" <<'PY'
import plistlib
import sys

path, build_number, commit_hash = sys.argv[1:4]
with open(path, 'rb') as handle:
    plist = plistlib.load(handle)
plist['CFBundleVersion'] = build_number
plist['ETCommitHash'] = commit_hash
with open(path, 'wb') as handle:
    plistlib.dump(plist, handle, sort_keys=False)
PY
    echo "已写入 CFBundleVersion=$BUILD_NUMBER、ETCommitHash=$COMMIT_HASH -> $EXPO_PLIST_PATH"
    exit 0
fi

# 主 App 的 Cloud 归档不包含扩展；其他 scheme 仍检查扩展翻译。
if [ "${CI_XCODE_SCHEME:-}" != "ETOS LLM Studio Cloud" ]; then
    python3 "$ROOT_PATH/scripts/sync-extension-localizations.py" --check
fi

COMMIT_HASH="$(commit_hash)"

write_commit_hash() {
    plist_path="$1"

    if [ ! -f "$plist_path" ]; then
        echo "未找到 plist 文件：$plist_path"
        exit 1
    fi

    if /usr/libexec/PlistBuddy -c "Print :ETCommitHash" "$plist_path" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :ETCommitHash $COMMIT_HASH" "$plist_path"
    else
        /usr/libexec/PlistBuddy -c "Add :ETCommitHash string $COMMIT_HASH" "$plist_path"
    fi

    echo "已写入 ETCommitHash=$COMMIT_HASH -> $plist_path"
}

write_commit_hash "$IOS_PLIST_PATH"
