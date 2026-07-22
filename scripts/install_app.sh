#!/bin/zsh
# Install Keypad as a minimal .app bundle in /Applications.
#
# The bundle wraps this repo's venv (no py2app): its launcher execs
# `.venv/bin/python -m keypad.app run`, so editing the repo updates the
# installed app. LSUIElement keeps it out of the Dock — it lives in the
# menu bar only. Run from anywhere; re-run after moving the repo.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Keypad.app"
PYTHON="$REPO/.venv/bin/python"

[[ -x "$PYTHON" ]] || { echo "venv python not found at $PYTHON" >&2; exit 1; }

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
cp "$REPO/assets/keypad.icns" "$APP/Contents/Resources/keypad.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Keypad</string>
    <key>CFBundleDisplayName</key>       <string>Keypad</string>
    <key>CFBundleIdentifier</key>        <string>com.philiporange.keypad</string>
    <key>CFBundleVersion</key>           <string>0.1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>keypad</string>
    <key>CFBundleIconFile</key>          <string>keypad</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/keypad" <<LAUNCHER
#!/bin/zsh
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
cd "$REPO"
exec "$PYTHON" -m keypad.app run
LAUNCHER
chmod +x "$APP/Contents/MacOS/keypad"

# -- default config ---------------------------------------------------------
CONFIG="$HOME/.config/keypad/keypad.toml"
if [[ ! -f "$CONFIG" ]]; then
  mkdir -p "$(dirname "$CONFIG")"
  cp "$REPO/keypad.example.toml" "$CONFIG"
  echo "Installed default config at $CONFIG (edit the device ids when the keypad arrives)"
fi

echo "Installed $APP"
echo "Launch with: open $APP   (menu-bar icon; no Dock entry)"
