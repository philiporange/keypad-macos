#!/bin/zsh
# Build the Swift Keypad binary and install it as /Applications/Keypad.app.
#
# Unlike the old Python wrapper bundle, this is a self-contained app: the
# release binary is copied into the bundle, ad-hoc signed with a stable
# bundle identifier so TCC permission grants (Input Monitoring,
# Accessibility, Automation) and SMAppService registration survive
# rebuilds. Re-run after code changes.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Keypad.app"
BUNDLE_ID="com.philiporange.keypad"

swift build -c release --package-path "$REPO"
BIN="$REPO/.build/release/Keypad"

# -- icon: build keypad.icns from the PNG artwork --------------------------
ICONSET="$(mktemp -d)/keypad.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$REPO/assets/keypad.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$REPO/assets/keypad.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$REPO/assets/keypad.icns"

# -- bundle -----------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keypad"
cp "$REPO/assets/keypad.icns" "$APP/Contents/Resources/keypad.icns"
cp "$REPO/assets/statusbar.png" "$APP/Contents/Resources/statusbar.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Keypad</string>
	<key>CFBundleDisplayName</key>
	<string>Keypad</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleVersion</key>
	<string>2.0</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0</string>
	<key>CFBundleExecutable</key>
	<string>Keypad</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>keypad</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Keypad runs AppleScript-based actions (notifications, volume, dark mode) when keys are pressed.</string>
</dict>
</plist>
PLIST

# A real signing identity (not ad-hoc) keeps the TCC designated requirement
# stable across rebuilds — ad-hoc pins permissions to one build's cdhash,
# invalidating Input Monitoring/Accessibility grants on every rebuild.
SIGN_IDENTITY="${KEYPAD_SIGN_IDENTITY:-Apple Development: Philip Orange (G4247D8TYC)}"
codesign --force --options runtime --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP" \
  || codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Installed $APP"
echo "Grant Input Monitoring and Accessibility to Keypad.app in System Settings on first run."
