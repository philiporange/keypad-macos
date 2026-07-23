# Keypad

A lightweight macOS menu-bar app (native Swift) for mapping custom USB and Bluetooth macro keypads (N x M key grid plus K rotary knobs) to user-defined system actions.

## Features

- **Flexible Action Mappings**: Map keypresses and knob rotations/clicks to key macros (CGEvent), media controls (volume, brightness, playback), app launches, scripts, shell commands, [AeroSpace](https://github.com/nikitabobko/AeroSpace) window-manager commands, URLs, typed text, AppleScript, macOS Shortcuts, system commands (lock screen, display sleep, dark mode, ...), absolute volume, notifications, and multi-step sequences.
- **Native Configuration Window**: SwiftUI editor with General/Keys/Knobs tabs covering every action type.
- **Launch at Login**: One toggle, backed by `SMAppService` — no login-item scripting, no permission prompts.
- **Menu Bar Status Item**: Template icon with Configure/Reload/Quit; devices reconnect automatically via IOHIDManager.
- **Diagnostic CLI**: Subcommands to validate config, list connected HID devices, and learn raw report formats.

## Build & Install

Requires Xcode command-line tools (Swift 6). Build the binary, assemble the
signed app bundle, and install it to `/Applications`:

```bash
./scripts/build_app.sh
open -a Keypad
```

The script signs with an Apple Development identity (override with
`KEYPAD_SIGN_IDENTITY`) so that TCC permission grants survive rebuilds;
ad-hoc signing would pin them to a single build's cdhash.

Run tests with `swift test`.

## Configuration

Copy the provided example configuration file to your user config directory:

```bash
mkdir -p ~/.config/keypad
cp keypad.example.toml ~/.config/keypad/keypad.toml
```

Edit `~/.config/keypad/keypad.toml` to define your device parameters (`vendor_id`, `product_id`, `usage_page`, `usage`, `protocol`), layout grid size, and action bindings — `keypad.example.toml` documents every action type.

### Configuration window

The easiest way to edit bindings is the native config window: click the
menu-bar icon and choose **Configure…**. It has a General tab (launch at
login, menu-bar icon, log level, device and layout settings), a Keys tab
with a clickable NxM key grid, and a Knobs tab with per-knob cw/ccw/press
editors — all covering every action type. Where it makes sense the editor
offers a dropdown of preset commands with a **Custom…** free-text option:
common AeroSpace commands, common macro chords, your installed
applications, and your Shortcuts (discovered via `shortcuts list`).
Saving validates the config and the running app reloads its bindings
immediately. Without the menu bar:

```bash
/Applications/Keypad.app/Contents/MacOS/Keypad configure
```

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
(`/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`).

## CLI

The app binary doubles as a CLI (add an alias if you use it often):

```bash
KEYPAD=/Applications/Keypad.app/Contents/MacOS/Keypad
$KEYPAD check-config              # validate config and print bindings
$KEYPAD list-devices              # list connected HID devices
$KEYPAD learn --seconds 15        # print raw reports to map a new pad
$KEYPAD run --no-statusbar        # headless daemon, no menu bar item
```

## Required macOS System Permissions

Granted once on first run (the app requests both, and the grants persist
across rebuilds thanks to the stable code-signing identity):

1. **Input Monitoring**: reading raw HID input reports from USB/Bluetooth keypads.
2. **Accessibility**: synthesizing key macros and media events via CGEvents.

System commands `show_desktop` and `toggle_dark_mode` additionally use
System Events (AppleScript) and prompt for Automation on first use.
`display_sleep` and `system_sleep` run via a one-shot launchd agent —
`pmset` fails with error 1006 when called from a daemon child; see NOTES.md.
