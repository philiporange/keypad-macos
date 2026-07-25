# Seize Option (design)

Status: **proposed — not implemented**. This documents how an opt-in
"seize" mode for test mode would work, so it can be picked up later
without re-deriving the design.

## Problem

The config window's **Suspend actions (test mode)** switch stops the
daemon from *executing* bindings, but the pad's keystrokes still reach
macOS like any keyboard input: the focused app receives F13–F24, some
apps beep on unhandled function keys, and on other layers the pad types
real characters into whatever has focus. The config window swallows
F13–F24 aimed at itself, but input delivered to any *other* app is
outside its control.

## The mechanism

IOKit allows a client to open a HID device with **exclusive access**
(`kIOHIDOptionsTypeSeizeDevice`). While seized:

- the seizing client continues to receive input reports (highlighting
  in the config window keeps working);
- the system and every other client stop receiving events from that
  device — nothing is typed anywhere, nothing beeps, no focus moves;
- if the seizing process exits or crashes, **the kernel releases the
  seize automatically**, so a wedged daemon cannot permanently mute the
  pad.

This is exactly how Karabiner-Elements takes over keyboards (its
grabber seizes the device, filters events, and re-posts them through a
virtual keyboard) — hence "the Karabiner option". Note the corollary
already observed in this setup: **only one client can seize a device**.
If Karabiner grabs the pad, the daemon's open fails with
`kIOReturnExclusiveAccess` (this is why the wired pad must be listed as
ignored in Karabiner's settings), and vice versa: if Karabiner is ever
re-enabled for the pad, our seize will fail and must degrade
gracefully.

Scope safety: the daemon's `IOHIDManager` matching dictionaries are
restricted to the configured VID/PID (+ usage page/usage), so a seize
can only ever capture the pad itself — never the user's real keyboard.

## Configuration

Opt-in via the `[app]` section (default `false`); optionally surfaced
as a checkbox in the General tab next to the other app settings:

```toml
[app]
statusbar = false
log_level = "INFO"
# While "Suspend actions (test mode)" is on, also capture the pad
# exclusively so its input never reaches macOS (no stray keystrokes,
# no beeps in other apps). Requires nothing else (Karabiner, another
# daemon instance) to be grabbing the device.
test_mode_seize = true
```

Why opt-in: seizing an input device is invasive, and a failure to
release (or an unexpected interaction with other HID software) makes
the pad appear dead system-wide. The default behavior should stay
observable-only.

## Implementation sketch

### 1. Config (`Config.swift`)

```swift
public struct Config: Equatable {
    // ...existing fields...
    /// While test mode suspends actions, also seize the devices so
    /// their input never reaches macOS. Default false.
    public var testModeSeize: Bool
}

// in loadConfig(), alongside statusbar/logLevel parsing:
let testModeSeize = appTable?["test_mode_seize"]?.bool ?? false
```

`TOMLWrite.dumpsTOML` gains the mirror line (emit only when `true` to
keep existing files byte-stable).

### 2. Listener (`HIDListener.swift`)

`start()` learns an exclusivity flag; a `setExclusive(_:)` transition
tears the manager down and rebuilds it with the other open options.
Manager-level open options also apply to devices matched *later*, so a
pad replugged mid-seize is seized on arrival.

```swift
public private(set) var isExclusive = false

public func start(exclusive: Bool = false) {
    // ...existing manager/matching/callback setup...
    let options = exclusive
        ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        : IOOptionBits(kIOHIDOptionsTypeNone)
    let openStatus = IOHIDManagerOpen(mgr, options)
    if openStatus == kIOReturnExclusiveAccess {
        // Another client (e.g. Karabiner) already holds the device.
        // Degrade: fall back to non-exclusive listening so highlight
        // still works, and report the failure to the UI.
        logger.warning("Seize refused (exclusive access held elsewhere); falling back to listen-only")
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        onSeizeUnavailable?()
    }
    isExclusive = exclusive && openStatus == kIOReturnSuccess
}

/// Switch between listen-only and seized without losing callbacks.
public func setExclusive(_ exclusive: Bool) {
    guard isRunning, exclusive != isExclusive else { return }
    stop()
    start(exclusive: exclusive)
}
```

### 3. Wiring (`EventMonitor` + `AppMain.swift`)

`EventMonitor.actionsSuspended` is already the single source of truth
for test mode (UI toggle, auto-reset on window close, cross-process
distributed-notification sync). Seizing piggybacks on it:

```swift
// EventMonitor
public var onSuspendChanged: ((Bool) -> Void)?
public var actionsSuspended: Bool = false {
    didSet {
        guard actionsSuspended != oldValue else { return }
        onSuspendChanged?(actionsSuspended)
        // ...existing distributed-notification post...
    }
}

// StatusbarAppDelegate.applicationDidFinishLaunching
EventMonitor.shared.onSuspendChanged = { [weak self] suspended in
    guard let self, let cfg = self.config, cfg.testModeSeize else { return }
    self.listeners.forEach { $0.setExclusive(suspended) }
}
```

Because every path that ends test mode already sets
`actionsSuspended = false` (toggle off, window close, standalone window
quit), release is automatic; the kernel's process-exit cleanup covers
crashes.

### 4. Which process seizes

- **Daemon mode** (config window inside the daemon): the daemon's own
  listeners seize. The standalone case does not apply.
- **Standalone `keypad configure` with a daemon running**: the daemon
  must do the seizing (it receives the suspend state over the existing
  distributed notification). The standalone window's listen-only
  monitors will stop receiving reports while the daemon holds the
  seize — acceptable, but the better variant is a second notification
  ("who seizes") so only one process attempts it. Simplest correct
  rule: **a process only seizes if it executes actions** (the daemon),
  and a daemon-less standalone window seizes with its own monitors.

### 5. UI feedback

The footer already shows "· actions suspended"; with seizing active it
should say "· input captured" instead, and if the seize was refused
(`onSeizeUnavailable`) show "· seize unavailable — input still reaches
other apps" so the user is never misled about what a test press will
do.

## Failure modes and caveats

| Scenario | Behavior |
|---|---|
| Karabiner (or anything) re-grabs the pad | Seize open fails with `kIOReturnExclusiveAccess`; fall back to listen-only + UI notice |
| Daemon crashes while seized | Kernel releases the seize; pad works normally again |
| Pad replugged during test mode | Manager re-matches and the open options re-apply — still seized |
| Config reload mid-test-mode | `setupListener` rebuilds listeners; it must consult `actionsSuspended` + `testModeSeize` to restore the seize state |
| Input Monitoring not granted | Seize open fails like a normal open; existing permission prompt flow applies |

## Why this is not implemented yet

The local F13–F24 swallow in the config window plus action suspension
covers the actual testing workflow (window focused). Seizing adds
value only for presses made while *other* apps are focused during test
mode — worth having, but not at the cost of rushing exclusive-access
edge cases. Implement when the need is felt, following this document.
