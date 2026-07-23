# Keypad

A lightweight macOS background utility for mapping custom USB and Bluetooth macro keypads (N x M key grid plus K rotary knobs) to user-defined system actions.

## Features

- **Flexible Action Mappings**: Map keypresses and knob rotations/clicks to key macros (Quartz CGEvent), media controls (volume, brightness, playback), app launches, python/shell scripts, arbitrary shell commands, and [AeroSpace](https://github.com/nikitabobko/AeroSpace) window-manager commands.
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

### AeroSpace window-manager actions

If you use [AeroSpace](https://github.com/nikitabobko/AeroSpace), any of its CLI
commands can be bound directly with the `aerospace` action type — the value of
`command` is passed to the `aerospace` binary as arguments:

```toml
[[key]]
row = 2
col = 1
action = { type = "aerospace", command = "workspace-back-and-forth" }

[[knob]]
index = 1
on_cw = { type = "aerospace", command = "workspace next --wrap-around" }
on_ccw = { type = "aerospace", command = "workspace prev --wrap-around" }
on_press = { type = "aerospace", command = "balance-sizes" }
```

Useful commands: `workspace <n>`, `workspace next|prev`, `focus left|right|up|down`,
`move left|right`, `fullscreen`, `layout tiles|accordion`, `balance-sizes`,
`workspace-back-and-forth` — see `aerospace --help` for the full list. The binary
is found via `PATH`, falling back to the Homebrew locations
(`/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`), which matters when
running under launchd's minimal environment.

Validate your configuration at any time:

```bash
python -m keypad.app check-config
```

### Configuration window

The easiest way to edit bindings is the native config window: click the
menu-bar icon and choose **Configure…**. It has a General tab (launch at
login, menu-bar icon, log level, device and layout settings), a Keys tab
with a clickable NxM key grid, and a Knobs tab with per-knob cw/ccw/press
editors — all covering every action type. Saving validates the config and
the running daemon reloads its bindings immediately. Without the menu bar:

```bash
python -m keypad.app configure            # opens the window standalone
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
