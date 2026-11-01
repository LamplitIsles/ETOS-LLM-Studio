#!/bin/sh
set -eu

# 仅在 Xcode Cloud 环境优先使用官方仓库路径，便于脚本在云端与本地都可运行。
ROOT_PATH="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
IOS_PLIST_PATH="$ROOT_PATH/ETOS LLM Studio/Config/iOSInfo.plist"

# 主 App 的 Cloud 归档不包含扩展；其他 scheme 仍检查扩展翻译。
if [ "${CI_XCODE_SCHEME:-}" != "ETOS LLM Studio Cloud" ]; then
    python3 "$ROOT_PATH/scripts/sync-extension-localizations.py" --check
fi

# 云端构建写入完整 Commit，界面展示时再截为 7 位；源码向导必须依赖精确版本。
if [ -n "${CI_COMMIT:-}" ]; then
    COMMIT_HASH="$(printf '%s' "$CI_COMMIT" | tr '[:upper:]' '[:lower:]')"
    case "$COMMIT_HASH" in
        *[!0-9a-f]*)
            echo "CI_COMMIT 不是有效的 Git 提交哈希"
            exit 1
            ;;
    esac
    if [ "${#COMMIT_HASH}" -ne 40 ]; then
        echo "CI_COMMIT 必须是完整 40 位 Git 提交哈希"
        exit 1
    fi
else
    COMMIT_HASH="LocalBuild"
fi

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
