#!/bin/sh
set -eu

# Xcode Cloud 克隆后准备。只有 Expo 开发壳归档需要第三方 Node/npm 与 Pods；
# 旧 Swift 产品沿用镜像自带工具，这里不做任何准备，避免两条产品线互相串扰。

EXPO_SCHEME="ETOSExpo Dev Archive"

if [ "${CI_XCODE_SCHEME:-}" != "$EXPO_SCHEME" ]; then
    echo "当前 scheme 不是 Expo 开发壳归档，跳过 Expo 依赖准备。"
    exit 0
fi

ROOT_PATH="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
CLIENT_PATH="$ROOT_PATH/expo-client"
IOS_PATH="$CLIENT_PATH/ios"

# 与本地验证过的工具版本对齐；Node 走官方 tarball 并校验固定摘要，
# 避免云镜像的架构与 Homebrew 状态影响构建。官方 npm 的 shebang 是 env node，
# 因此必须先让下载的 Node 进入 PATH，冷启动时镜像可能完全没有 system Node。
NODE_VERSION="24.18.1"
case "$(uname -m)" in
    arm64)
        NODE_PLATFORM="darwin-arm64"
        NODE_SHA256="1d60b703fe5d7e7072489be8187f430f1a095a658c31e5e1e281331a5873fac3"
        ;;
    x86_64)
        NODE_PLATFORM="darwin-x64"
        NODE_SHA256="f892c7895720f40d3750bde24f3554242d36f23602b5167b5b73ec4d13938aef"
        ;;
    *)
        echo "构建机架构 $(uname -m) 不受支持；只提供 darwin-arm64 与 darwin-x64 的固定 Node 工具链。" >&2
        exit 1
        ;;
esac
NPM_VERSION="12.0.2"

TOOLS_PATH="${CI_DERIVED_DATA_PATH:-$HOME}/etos-expo-ci-tools"
NODE_PATH="$TOOLS_PATH/node-v$NODE_VERSION-$NODE_PLATFORM"
NPM_PATH="$TOOLS_PATH/npm-$NPM_VERSION"

if [ ! -x "$NODE_PATH/bin/node" ]; then
    mkdir -p "$TOOLS_PATH"
    ARCHIVE_PATH="$TOOLS_PATH/node-v$NODE_VERSION-$NODE_PLATFORM.tar.xz"
    curl -fsSL -o "$ARCHIVE_PATH" "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$NODE_PLATFORM.tar.xz"
    printf '%s  %s\n' "$NODE_SHA256" "$ARCHIVE_PATH" | shasum -a 256 -c -
    tar -xf "$ARCHIVE_PATH" -C "$TOOLS_PATH"
    rm -f "$ARCHIVE_PATH"
fi

# Node 24 通过该受支持设置让 npm 与安装脚本（含原生资产下载）遵循环境里的
# HTTP(S)_PROXY；不放宽 TLS 校验。
export NODE_USE_ENV_PROXY=1

export PATH="$NODE_PATH/bin:$PATH"

if [ ! -x "$NPM_PATH/bin/npm" ]; then
    npm install -g "npm@$NPM_VERSION" --prefix "$NPM_PATH"
fi

export PATH="$NPM_PATH/bin:$PATH"

# Xcode 构建阶段不继承本脚本的 PATH；.xcode.env.local 是工程实际读取 Node 的入口。
printf 'export NODE_BINARY=%s\n' "$NODE_PATH/bin/node" > "$IOS_PATH/.xcode.env.local"

cd "$CLIENT_PATH"
npm ci

# ETOS 的 gem 操作和 pod 使用同一个 Ruby；pod 的 shebang 可能指向其他 Ruby。
REQUIRED_POD_VERSION="$(sed -n 's/^COCOAPODS: //p' "$IOS_PATH/Podfile.lock")"
if [ -z "$REQUIRED_POD_VERSION" ]; then
    echo "无法从 $IOS_PATH/Podfile.lock 读取 CocoaPods 版本" >&2
    exit 1
fi
echo "Node $(node --version)，npm $(npm --version)"

# 云端必须严格使用已提交的 Podfile.lock，锁与 Podfile 不一致时失败而不是改写。
cd "$IOS_PATH"
"$ROOT_PATH/ci_scripts/expo_pod.sh" cloud "$TOOLS_PATH" "$REQUIRED_POD_VERSION" install --deployment
