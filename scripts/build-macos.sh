#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NearDoc.app"
DMG="$ROOT/dist/NearDoc-macOS.dmg"
ZIP="$ROOT/dist/NearDoc-macOS.zip"

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
	<string>NearDoc</string>
	<key>CFBundleExecutable</key>
	<string>NearDoc</string>
	<key>CFBundleIconFile</key>
	<string>LinkBridge.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.shahnawaz.neardoc.mac</string>
	<key>CFBundleName</key>
	<string>NearDoc</string>
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
	<string>NearDoc connects directly to your Android phone on your local network.</string>
</dict>
</plist>
EOF

echo "Compiling NearDoc.app..."
swiftc \
  -module-cache-path "$ROOT/build/module-cache" \
  -parse-as-library \
  -framework AppKit -framework CoreImage -framework Network -framework CryptoKit -framework UserNotifications -framework UniformTypeIdentifiers \
  "$ROOT/macos/Sources/ToolLocator.swift" \
  "$ROOT/macos/Sources/PairingHost.swift" \
  "$ROOT/macos/Sources/PhoneFilesPanel.swift" \
  "$ROOT/macos/Sources/WirelessQrPairer.swift" \
  "$ROOT/macos/Sources/main.swift" \
  -o "$APP/Contents/MacOS/NearDoc"

codesign --force --deep --sign - "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built: $APP"
echo "Packaged: $ZIP"

if hdiutil create -volname "NearDoc" -srcfolder "$APP" -ov -format UDZO "$DMG" 2>/dev/null; then
  echo "Packaged: $DMG"
fi
