# Keypad

A lightweight macOS background utility for mapping custom USB and Bluetooth macro keypads (N x M key grid plus K rotary knobs) to user-defined system actions.

## Features

- **Flexible Action Mappings**: Map keypresses and knob rotations/clicks to key macros (Quartz CGEvent), media controls (volume, brightness, playback), app launches, python/shell scripts, and arbitrary shell commands.
- **Menu Bar Status Bar**: Optional menu bar status item with fast config reloading.
- **Robust Reconnection**: Background thread auto-reconnects with exponential backoff if the keypad device is unplugged or disconnected.
- **Diagnostic Utilities**: Built-in CLI commands to list connected HID devices and learn raw report formats.

## Installation

Install dependencies from `requirements.txt`:

```bash
pip install -r requirements.txt
```

## Configuration

Copy the provided example configuration file to your user config directory:

```bash
mkdir -p ~/.config/keypad
cp keypad.example.toml ~/.config/keypad/keypad.toml
```

Edit `~/.config/keypad/keypad.toml` to define your device parameters (`vendor_id`, `product_id`, `usage_page`, `usage`), layout grid size, and action bindings.

Validate your configuration at any time:

```bash
python -m keypad.app check-config
```

## Device Discovery & Learning

List all connected HID devices and their Vendor/Product IDs:

```bash
python -m keypad.app list-devices
```

To determine raw report formats for unmapped keypads, use the `learn` command:

```bash
python -m keypad.app learn --seconds 15
```

## Required macOS System Permissions

To capture raw HID input reports and synthesize global keyboard shortcuts on macOS, grant the following permissions in **System Settings > Privacy & Security**:

1. **Input Monitoring**: Allows reading raw HID input reports from USB/Bluetooth keypads.
2. **Accessibility**: Allows synthesizing global key combination shortcuts and media events via Quartz CGEvents.

## Launch at Login (launchd)

To automatically launch the keypad daemon upon user login, save the following property list snippet to `~/Library/LaunchAgents/com.user.keypad.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.keypad</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/python3</string>
        <string>-m</string>
        <string>keypad.app</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/keypad.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/keypad.stderr.log</string>
</dict>
</plist>
```

Load the LaunchAgent service:

```bash
launchctl load ~/Library/LaunchAgents/com.user.keypad.plist
```
