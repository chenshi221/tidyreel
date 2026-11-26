#!/bin/sh
# Build the native macOS Swift app bundle (arm64).
# If tmdb.local.json exists at repo root (gitignored), its TMDB_TOKEN is embedded into
# the app bundle's Info.plist as TIDYREEL_DEFAULT_TMDB_TOKEN; user Settings key overrides it.
# Usage: tool/build_macos.sh [release|debug]
set -e
export PATH=/opt/homebrew/opt/git/bin:$PATH
cd "$(dirname "$0")/.."

mode="${1:-release}"
case "$mode" in
  release) cap="Release" ;;
  debug)   cap="Debug" ;;
  *)
    echo "用法：tool/build_macos.sh [release|debug]" >&2
    exit 1
    ;;
esac

if [ "$mode" = "release" ]; then
  swift build -c "$mode" --arch arm64 --product tidyreel -Xswiftc -Osize
else
  swift build -c "$mode" --arch arm64 --product tidyreel
fi

if [ -x ".build/arm64-apple-macosx/$mode/tidyreel" ]; then
  bin_path=".build/arm64-apple-macosx/$mode/tidyreel"
elif [ -x ".build/$mode/tidyreel" ]; then
  bin_path=".build/$mode/tidyreel"
else
  bin_path="$(swift build -c "$mode" --arch arm64 --show-bin-path)/tidyreel"
fi
app_dir="build/$cap/tidyreel.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

cp "$bin_path" "$app_dir/Contents/MacOS/tidyreel"
chmod +x "$app_dir/Contents/MacOS/tidyreel"
if [ "$mode" = "release" ]; then
  strip "$app_dir/Contents/MacOS/tidyreel" 2>/dev/null || true
fi

cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

if [ -f tmdb.local.json ]; then
  python3 - "$app_dir/Contents/Info.plist" <<'PY'
import json, plistlib, sys
plist_path = sys.argv[1]
with open("tmdb.local.json", "r", encoding="utf-8") as f:
    data = json.load(f)
token = str(data.get("TMDB_TOKEN", "")).strip()
if token:
    with open(plist_path, "rb") as pf:
        plist = plistlib.load(pf)
    plist["TIDYREEL_DEFAULT_TMDB_TOKEN"] = token
    with open(plist_path, "wb") as pf:
        plistlib.dump(plist, pf)
PY
fi

codesign --force --deep --sign - --entitlements Resources/Tidyreel.entitlements "$app_dir"
echo "Built: $(pwd)/$app_dir"
