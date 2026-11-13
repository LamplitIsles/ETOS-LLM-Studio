#!/bin/sh
set -eu

MODE="$1"
TOOLS_PATH="$2"
POD_VERSION="$3"
shift 3
ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"

# Inherited Ruby startup options can activate a different JSON before Bundler.
unset RUBYOPT RUBYLIB
case "$MODE" in
    local)
        RUBY_COMMAND="$(command -v ruby)" || { echo "PATH 中找不到 Ruby 3.3；请先配置 Ruby 3.3。" >&2; exit 1; }
        # Resolve version-manager shims to the actual Ruby and its matching gem executable.
        RUBY="$("$RUBY_COMMAND" -rrbconfig -e 'print RbConfig.ruby')" || { echo "无法确定 Ruby 的实际路径：$RUBY_COMMAND" >&2; exit 1; }
        [ -x "$RUBY" ] || { echo "Ruby 的实际路径不可执行：$RUBY" >&2; exit 1; }
        ;;
    cloud)
        command -v brew >/dev/null 2>&1 || { echo "找不到 Homebrew，无法准备 Ruby 3.3。" >&2; exit 1; }
        RUBY_PREFIX="$(brew --prefix ruby@3.3)"
        if [ ! -x "$RUBY_PREFIX/bin/ruby" ]; then
            brew install ruby@3.3
            RUBY_PREFIX="$(brew --prefix ruby@3.3)"
        fi
        RUBY="$RUBY_PREFIX/bin/ruby"
        [ -x "$RUBY" ] || { echo "Homebrew 未提供 Ruby 3.3：$RUBY" >&2; exit 1; }
        ;;
    *) echo "未知 CocoaPods 准备模式：$MODE" >&2; exit 1 ;;
esac

if ! "$RUBY" -e 'abort "需要 Ruby 3.3，实际为 #{RUBY_VERSION}" unless RUBY_VERSION.start_with?("3.3.")'; then
    echo "Ruby 3.3 检查失败：$RUBY" >&2
    exit 1
fi

export GEM_HOME="$TOOLS_PATH/ruby-gems"
export GEM_PATH="$GEM_HOME"
export GEM_SPEC_CACHE="$TOOLS_PATH/gem-spec-cache"
export BUNDLE_PATH="$GEM_HOME"
export BUNDLE_PATH__SYSTEM=false
export BUNDLE_DISABLE_SHARED_GEMS=true
export BUNDLE_USER_HOME="$TOOLS_PATH/bundler"
export BUNDLE_IGNORE_CONFIG=1
export BUNDLE_GEMFILE="$ROOT_PATH/expo-client/Gemfile"
export BUNDLE_FROZEN=true

# mise 的 RubyGems 安装 hook 会调用 mise reshim。gem 只供此目录使用，
# 在安装子进程拦截该调用，避免改写用户 shims；其他 mise 命令直接失败。
mkdir -p "$TOOLS_PATH/bin"
cat > "$TOOLS_PATH/bin/mise" <<'EOF'
#!/bin/sh
[ "$1" = reshim ] || { echo "意外的 mise 调用：$*" >&2; exit 1; }
EOF
chmod +x "$TOOLS_PATH/bin/mise"

if ! "$RUBY" -e 'gem "bundler", "= 2.4.22"' >/dev/null 2>&1; then
    PATH="$TOOLS_PATH/bin:$PATH" "$RUBY" "$(dirname "$RUBY")/gem" install --config-file /dev/null --no-document --install-dir "$GEM_HOME" bundler:2.4.22
fi
if ! "$RUBY" -e 'gem "bundler", "= 2.4.22"; load Gem.bin_path("bundler", "bundle", "2.4.22")' -- check >/dev/null 2>&1; then
    PATH="$TOOLS_PATH/bin:$PATH" "$RUBY" -e 'gem "bundler", "= 2.4.22"; load Gem.bin_path("bundler", "bundle", "2.4.22")' -- install
fi

exec "$RUBY" "$ROOT_PATH/ci_scripts/expo_pod.rb" "$POD_VERSION" "$@"
