#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Bridge.app"
DMG="$ROOT/dist/Bridge-macOS.dmg"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist" "$ROOT/build/module-cache"

if [ -f "$ROOT/macos/Resources/Bridge.icns" ]; then
  cp "$ROOT/macos/Resources/Bridge.icns" "$APP/Contents/Resources/LinkBridge.icns"
fi
if [ -f "$ROOT/macos/Resources/BridgeLogo.png" ]; then
  cp "$ROOT/macos/Resources/BridgeLogo.png" "$APP/Contents/Resources/LinkBridgeLogo.png"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Bridge</string>
	<key>CFBundleExecutable</key>
	<string>Bridge</string>
	<key>CFBundleIconFile</key>
	<string>LinkBridge.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.shahnawaz.bridge.mac</string>
	<key>CFBundleName</key>
	<string>Bridge</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1.0.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.3</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_adb-tls-pairing._tcp</string>
		<string>_adb-tls-connect._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Bridge connects directly to your Android phone on your local network.</string>
</dict>
</plist>
EOF

echo "Compiling Bridge.app..."
swiftc \
  -module-cache-path "$ROOT/build/module-cache" \
  -parse-as-library \
  -framework AppKit -framework CoreImage -framework Network -framework CryptoKit -framework UserNotifications -framework UniformTypeIdentifiers \
  "$ROOT/macos/Sources/ToolLocator.swift" \
  "$ROOT/macos/Sources/PairingHost.swift" \
  "$ROOT/macos/Sources/PhoneFilesPanel.swift" \
  "$ROOT/macos/Sources/WirelessQrPairer.swift" \
  "$ROOT/macos/Sources/main.swift" \
  -o "$APP/Contents/MacOS/Bridge"

codesign --force --deep --sign - "$APP"

echo "Packaging Bridge-macOS.dmg..."
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Bridge" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Built: $APP"
echo "Packaged: $DMG"
