#!/usr/bin/env bash
set -euo pipefail

# Supply the known App ID prefix explicitly; this does not use a signing identity.
if [[ $# != 1 ]]; then
    printf 'usage: %s <app-identifier-prefix-without-dot>\n' "$0" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
app_identifier_prefix=$1
main_entitlements=.build/etos-tools/entitlements/main.plist
mkdir -p "$(dirname "$main_entitlements")"
python3 - "$app_identifier_prefix" "$main_entitlements" <<'PY'
import plistlib, re, sys
from pathlib import Path

prefix = sys.argv[1]
if not re.fullmatch(r"[A-Za-z0-9]+", prefix):
    sys.exit("invalid App ID prefix; provide its explicit value without a trailing dot")

def expand(value):
    if isinstance(value, str):
        value = value.replace("$(AppIdentifierPrefix)", prefix + ".")
        if "$(" in value:
            sys.exit("main entitlements contain an unsupported Xcode build setting")
        return value
    if isinstance(value, list): return [expand(item) for item in value]
    if isinstance(value, dict): return {key: expand(item) for key, item in value.items()}
    return value

source = Path("ETOS LLM Studio/ETOS LLM Studio iOS App/ETOS LLM Studio iOS App.entitlements")
entitlements = expand(plistlib.loads(source.read_bytes()))
Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    printf 'rcodesign bootstrap currently supports Linux x86_64 only\n' >&2
    exit 1
fi
tool_dir=.build/etos-tools/rcodesign-0.29.0
archive="$tool_dir/tool.tar.gz"
mkdir -p "$tool_dir"
if [[ ! -f $archive ]]; then
    curl --fail --location --output "$archive.download" \
      'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz'
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' 'dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002' "$archive" | sha256sum --check --status
tar -xOf "$archive" 'apple-codesign-0.29.0-x86_64-unknown-linux-musl/rcodesign' > "$tool_dir/rcodesign.new"
chmod +x "$tool_dir/rcodesign.new"
mv "$tool_dir/rcodesign.new" "$tool_dir/rcodesign"

xtool dev build
app=xtool/ETOSApp.app
python3 - "$app/Info.plist" "$app_identifier_prefix" <<'PY'
import plistlib, sys
from pathlib import Path

info_path = Path(sys.argv[1])
prefix = sys.argv[2] + "."
info = plistlib.loads(info_path.read_bytes())
info["AppIdentifierPrefix"] = prefix
info["ETKeychainAccessGroup"] = prefix + "com.ericterminal.els.shared"
info_path.write_bytes(plistlib.dumps(info))
PY
swift build --package-path swiftpm/AssetCompiler --scratch-path .build/etos-tools/assetcompiler -c release --force-resolved-versions
asset_compiler=.build/etos-tools/assetcompiler/release/ETOSAssetCompiler
"$asset_compiler" 'ETOS LLM Studio/ETOS LLM Studio iOS App/Assets.xcassets' "$app"

"$tool_dir/rcodesign" --config-file /dev/null sign --timestamp-url none \
    --entitlements-xml-file "$main_entitlements" \
    --entitlements-xml-file 'PlugIns/ETOSShare.appex:ETOS LLM Studio/ETOS Agent Share/ETOS Agent ShareDebug.entitlements' \
    "$app"
python3 swiftpm/verify-iphone-bundle.py "$app" "$main_entitlements" "$app_identifier_prefix"
