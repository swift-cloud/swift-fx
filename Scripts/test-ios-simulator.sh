#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
device=${FX_IOS_SIMULATOR_ID:-$(xcrun simctl list devices available | awk '/iPhone/{gsub(/[()]/, "", $NF); print $NF; exit}')}
if [ -z "$device" ]; then echo "No available iOS Simulator device" >&2; exit 1; fi
app=$(mktemp -d)/FXiOSSmoke.app
work=$(mktemp -d)
trap 'rm -rf "$(dirname "$app")" "$work"' EXIT
mkdir -p "$app/Frameworks"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
framework="$root/Artifacts/FXCore.xcframework/ios-arm64_x86_64-simulator/CFX.framework"
xcrun swiftc -parse-as-library -emit-module -emit-library -module-name FX -target arm64-apple-ios14.0-simulator -sdk "$sdk" -F "$(dirname "$framework")" "$root"/Sources/FX/*.swift -o "$work/libFX.dylib"
cat > "$work/main.swift" <<'SWIFT'
import Foundation
import UIKit
import FX
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("fx-ios-smoke.marker")
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("fx-ios-smoke")
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let agent = try await FXAgent(configuration: .init(apiKey: "ios-smoke", workspace: root, home: root.appendingPathComponent("home")))
                let session = try await agent.createSession()
                try session.id.write(to: marker, atomically: true, encoding: .utf8)
                await agent.close()
            } catch { try? String(describing: error).write(to: marker, atomically: true, encoding: .utf8) }
        }
        return true
    }
}
SWIFT
xcrun swiftc -parse-as-library -target arm64-apple-ios14.0-simulator -sdk "$sdk" -I "$work" -L "$work" -lFX -F "$(dirname "$framework")" -framework CFX "$work/main.swift" -o "$app/FXiOSSmoke"
cp "$work/libFX.dylib" "$app/Frameworks/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>FXiOSSmoke</string><key>CFBundleIdentifier</key><string>cloud.swift.fx.ios-smoke</string><key>CFBundleName</key><string>FXiOSSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1</string><key>MinimumOSVersion</key><string>14.0</string><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
install_name_tool -add_rpath @executable_path/Frameworks "$app/FXiOSSmoke"
codesign --force --sign - "$app/Frameworks/libFX.dylib" "$app" >/dev/null
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" cloud.swift.fx.ios-smoke >/dev/null
sleep 5
container=$(xcrun simctl get_app_container "$device" cloud.swift.fx.ios-smoke data)
marker="$container/tmp/fx-ios-smoke.marker"
test -s "$marker"
echo "iOS simulator session passed: $(cat "$marker")"
