#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/PhoneBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/PhoneBridge "$APP/Contents/MacOS/PhoneBridge"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhoneBridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.piyush.phonebridge</string>
    <key>CFBundleName</key><string>PhoneBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PhoneBridge receives notifications from your Android phone over the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_phonenotif._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
