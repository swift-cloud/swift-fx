#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
output=${1:-"$root/Artifacts"}
revision=$(cat "$root/FX_REVISION")
source_dir="$root/.build/fx-source"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! command -v zig >/dev/null 2>&1; then echo "Zig 0.16 or later is required" >&2; exit 1; fi
if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
if ! xcodebuild -version >/dev/null 2>&1; then echo "Full Xcode is required" >&2; exit 1; fi
rm -rf "$source_dir"
git clone --quiet https://github.com/vercel-labs/fx.git "$source_dir"
git -C "$source_dir" checkout --quiet "$revision"
git -C "$source_dir" apply --check "$root/Patches/fx-c-api.patch"
git -C "$source_dir" apply "$root/Patches/fx-c-api.patch"
normalize_archive() { archive=$1; destination=$2; objects=$work/objects-$(basename "$destination"); mkdir -p "$objects"; (cd "$objects"; ar -x "$archive"; chmod 644 ./*.o; libtool -static -o "$destination" ./*.o); ranlib "$destination"; }
build_slice() { target=$1; name=$2; prefix="$work/$name"; (cd "$source_dir"; zig build --prefix "$prefix" -Dc-api-surface=core -Doptimize=ReleaseSafe -Dtarget="$target-macos.14.0.0"); normalize_archive "$prefix/lib/libfxcore.a" "$work/libfxcore-$name.a"; }
build_slice aarch64 arm64
build_slice x86_64 x86_64
lipo -create "$work/libfxcore-arm64.a" "$work/libfxcore-x86_64.a" -output "$work/libfxcore.a"
framework="$work/CFX.framework"
mkdir -p "$framework/Headers" "$framework/Modules"
cp "$work/libfxcore.a" "$framework/CFX"
cp "$source_dir/sdk/swift/Sources/CFX/include/fx.h" "$framework/Headers/fx.h"
cat > "$framework/Modules/module.modulemap" <<'MODULE'
framework module CFX {
  umbrella header "fx.h"
  export *
}
MODULE
cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cloud.swift.fx.core</string>
<key>CFBundleName</key><string>CFX</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
PLIST
mkdir -p "$output"
rm -rf "$output/FXCore.xcframework" "$output/FXCore.xcframework.zip" "$output/FXCore.xcframework.zip.sha256"
xcodebuild -create-xcframework -framework "$framework" -output "$output/FXCore.xcframework"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$output/FXCore.xcframework" "$output/FXCore.xcframework.zip"
swift package compute-checksum "$output/FXCore.xcframework.zip" > "$output/FXCore.xcframework.zip.sha256"
echo "Artifact: $output/FXCore.xcframework.zip"
echo "Checksum: $(cat "$output/FXCore.xcframework.zip.sha256")"
