# Notes

## `pmset displaysleepnow` fails with error 1006 when run from the daemon

**Symptom:** A key bound to sleep the displays (directly via
`pmset displaysleepnow`, or via a script that calls it) does nothing.
The daemon log shows the action firing, and pmset prints:

    pmset: Failed to put the display to sleep, error 1006

pmset still exits 0, so `check=True` doesn't catch it.

**What it is NOT (all ruled out by experiment, 2026-07-23):**

- Not timing / key-release activity. Retrying every second for 10 seconds
  after the keypress fails every attempt. The pad's keypresses don't even
  register as HID user activity to macOS (`CGEventSourceSecondsSinceLastEventType`
  keeps counting up through a press), and no keys are seen as held
  (`CGEventSourceKeyState` reports none down).
- Not the script, PATH, or environment. The exact same script succeeds when
  run from a terminal, from `.venv/bin/python` via `subprocess.run`, from
  `launchctl submit`, and via Karabiner's shell_command.
- Not power assertions (`caffeinate -i`, UserIsActive tickles) — pmset
  succeeded from other contexts while those were active.

**What it IS:** `pmset displaysleepnow` fails with error 1006 specifically
when the calling process is a *descendant of the Keypad daemon*
(Keypad.app wrapper → zsh → python → subprocess). Some inherited process
attribute of that chain makes the display-sleep request get refused.
Root cause inside macOS never identified; every other launch context works.

**Fix (in place now):** don't run pmset from the daemon at all. A LaunchAgent
owns the command, and the key binding just pokes launchd, which spawns pmset
as its own clean child:

- `~/Library/LaunchAgents/com.sam.sleepdisplay.plist` — runs
  `/usr/bin/pmset displaysleepnow`, `RunAtLoad=false`, output to
  `/tmp/keypad-sleep.log`. Load once with
  `launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.sam.sleepdisplay.plist`
  (survives reboots once loaded).
- Key binding in `~/.config/keypad/keypad.toml`:

      action = { type = "shell", command = "launchctl kickstart gui/501/com.sam.sleepdisplay" }

**General rule:** if a shell/script action works from a terminal but
mysteriously fails from the keypad daemon — especially anything touching
power management, displays, or other system services — wrap it in a
LaunchAgent and `launchctl kickstart` it instead of running it directly.

**Related:** the same display-sleep script also exists for the keyboard at
`~/Scripts/Sleep Display.command`, triggered by Karabiner (Option-S).
Karabiner's context is fine, so that path calls pmset directly; it also
sleeps 0.5s first so the Option-S keyup doesn't re-wake the display
(a real issue for real keyboards, irrelevant for the pad since its keys
don't register as user activity).
