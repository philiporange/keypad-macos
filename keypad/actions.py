"""Action execution module for macro keypad triggers on macOS.

This module maps configured Action dataclasses to actual OS operations: synthesising media keys
and keyboard macros via macOS Quartz framework, launching applications via 'open', running external
scripts, or executing shell commands. OS-specific Quartz calls are lazily imported.
"""

import logging
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

from .config import Action

logger = logging.getLogger(__name__)

# Virtual keycodes for macOS CGEvent system
KEY_CODES: Dict[str, int] = {
    # Letters
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
    "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
    "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
    "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,
    # Digits
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
    "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    # Function keys
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    # Special / Named keys
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
    "backspace": 0x33, "delete": 0x33, "escape": 0x35, "esc": 0x35,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "[": 0x21, "]": 0x1E, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F,
    "/": 0x2C, "\\": 0x2A, "`": 0x32, "-": 0x1B, "=": 0x18,
}

# Bitmask values for Quartz CGEvent modifiers
MODIFIER_MASKS: Dict[str, int] = {
    "cmd": 0x00100000,       # kCGEventFlagMaskCommand
    "command": 0x00100000,
    "shift": 0x00020000,     # kCGEventFlagMaskShift
    "alt": 0x00080000,       # kCGEventFlagMaskAlternate
    "option": 0x00080000,
    "opt": 0x00080000,
    "ctrl": 0x00040000,      # kCGEventFlagMaskControl
    "control": 0x00040000,
}

# Media key code mappings for system events
MEDIA_KEY_MAP: Dict[str, int] = {
    "volume_up": 0,
    "volume_down": 1,
    "brightness_up": 2,
    "brightness_down": 3,
    "mute": 7,
    "play_pause": 16,
    "next": 17,
    "previous": 18,
}


def parse_chord(chord: str) -> Optional[Tuple[int, int]]:
    """Parse key chord string (e.g. 'cmd+shift+4') into (modifier_flags, keycode).

    Logs an error and returns None if the chord is invalid or nonsense.
    """
    if not isinstance(chord, str) or not chord.strip():
        logger.error("Invalid key chord: must be a non-empty string")
        return None

    parts = [p.strip().lower() for p in chord.split("+")]
    modifiers_mask = 0
    main_keycode = None

    for part in parts:
        if part in MODIFIER_MASKS:
            modifiers_mask |= MODIFIER_MASKS[part]
        elif part in KEY_CODES:
            if main_keycode is not None:
                logger.error("Chord has multiple main non-modifier keys: %s", chord)
                return None
            main_keycode = KEY_CODES[part]
        else:
            logger.error("Unknown key or modifier in chord: '%s' in '%s'", part, chord)
            return None

    if main_keycode is None:
        logger.error("No valid main key found in chord: %s", chord)
        return None

    return (modifiers_mask, main_keycode)


def _execute_macro(action: Action) -> None:
    chords = action.keys
    if not chords:
        logger.error("Macro action missing keys")
        return
    if isinstance(chords, str):
        chords = [chords]

    for chord in chords:
        parsed = parse_chord(chord)
        if parsed is None:
            continue
        flags, keycode = parsed
        try:
            import Quartz
            event_down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
            if flags:
                Quartz.CGEventSetFlags(event_down, flags)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)

            event_up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
            if flags:
                Quartz.CGEventSetFlags(event_up, flags)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)
        except Exception as e:
            logger.error("Failed to execute Quartz macro event for chord '%s': %s", chord, e)


def _execute_media(action: Action) -> None:
    control = action.control
    if not control or control not in MEDIA_KEY_MAP:
        logger.error("Unknown or missing media control: %s", control)
        return
    key_code = MEDIA_KEY_MAP[control]
    try:
        import Quartz
        def _post_media_key(down: bool):
            ev = Quartz.NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
                14,  # NSSystemDefined
                (0, 0),
                0xa00 if down else 0xb00,
                0,
                0,
                0,
                8,   # Subtype media key
                (key_code << 16) | ((0x0a if down else 0x0b) << 8),
                -1,
            )
            if ev:
                cg_ev = ev.CGEvent()
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, cg_ev)

        _post_media_key(True)
        _post_media_key(False)
    except Exception as e:
        logger.error("Failed to execute media key event '%s': %s", control, e)


def _execute_app(action: Action) -> None:
    if action.name:
        cmd = ["open", "-a", action.name]
    elif action.path:
        cmd = ["open", action.path]
    else:
        logger.error("App action missing both name and path")
        return
    subprocess.run(cmd, check=True)


def _execute_script(action: Action) -> None:
    if not action.path:
        logger.error("Script action missing path")
        return
    args = action.args or []
    subprocess.run([action.path, *args], check=True)


# Fallback locations checked when 'aerospace' is not on the daemon's PATH
# (launchd agents often run with a minimal PATH).
AEROSPACE_PATHS = ("/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace")


def _aerospace_binary() -> Optional[str]:
    found = shutil.which("aerospace")
    if found:
        return found
    for candidate in AEROSPACE_PATHS:
        if shutil.which(candidate):
            return candidate
    return None


def _execute_aerospace(action: Action) -> None:
    if not action.command:
        logger.error("Aerospace action missing command")
        return
    binary = _aerospace_binary()
    if binary is None:
        logger.error("AeroSpace CLI not found (install AeroSpace or add it to PATH)")
        return
    subprocess.run([binary, *shlex.split(action.command)], check=True)


def _execute_shell(action: Action) -> None:
    if not action.command:
        logger.error("Shell action missing command")
        return
    subprocess.run(action.command, shell=True, check=True)


def _execute_url(action: Action) -> None:
    if not action.url:
        logger.error("URL action missing url")
        return
    subprocess.run(["open", action.url], check=True)


# CGEventKeyboardSetUnicodeString accepts a limited buffer per event.
_TEXT_CHUNK = 20


def _execute_text(action: Action) -> None:
    if not action.text:
        logger.error("Text action missing text")
        return
    import Quartz
    for i in range(0, len(action.text), _TEXT_CHUNK):
        chunk = action.text[i:i + _TEXT_CHUNK]
        for down in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(ev, len(chunk), chunk)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _execute_applescript(action: Action) -> None:
    if not action.source:
        logger.error("AppleScript action missing source")
        return
    subprocess.run(["/usr/bin/osascript", "-e", action.source], check=True)


def _execute_shortcut(action: Action) -> None:
    if not action.name:
        logger.error("Shortcut action missing name")
        return
    subprocess.run(["/usr/bin/shortcuts", "run", action.name], check=True)


def _run_osascript(source: str) -> None:
    subprocess.run(["/usr/bin/osascript", "-e", source], check=True)


def _launchd_oneshot(label: str, argv: list) -> None:
    """Run a command as a one-shot launchd agent instead of a daemon child.

    Power-management commands (pmset displaysleepnow and friends) fail with
    error 1006 when the calling process is a descendant of this daemon; see
    NOTES.md. launchd spawns the command in its own clean context, where it
    works. The agent plist is created and bootstrapped on first use.
    """
    plist = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    if not plist.exists():
        program = "".join(f"\t\t<string>{a}</string>\n" for a in argv)
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
            ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            f"\t<key>Label</key>\n\t<string>{label}</string>\n"
            f"\t<key>ProgramArguments</key>\n\t<array>\n{program}\t</array>\n"
            "\t<key>RunAtLoad</key>\n\t<false/>\n"
            "</dict>\n</plist>\n"
        )
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootstrap", domain, str(plist)],
                   capture_output=True)  # already-loaded is fine
    subprocess.run(["launchctl", "kickstart", f"{domain}/{label}"], check=True)


SYSTEM_COMMANDS = {
    "lock_screen": lambda: subprocess.run(
        ["/System/Library/PrivateFrameworks/login.framework/Versions/Current/Resources/CGSession",
         "-suspend"], check=True),
    "display_sleep": lambda: _launchd_oneshot(
        "com.keypad.displaysleep", ["/usr/bin/pmset", "displaysleepnow"]),
    "system_sleep": lambda: _launchd_oneshot(
        "com.keypad.systemsleep", ["/usr/bin/pmset", "sleepnow"]),
    "screensaver": lambda: subprocess.run(
        ["open", "-a", "ScreenSaverEngine"], check=True),
    "mission_control": lambda: subprocess.run(
        ["open", "-a", "Mission Control"], check=True),
    "launchpad": lambda: subprocess.run(
        ["open", "-a", "Launchpad"], check=True),
    "show_desktop": lambda: _run_osascript(
        'tell application "System Events" to key code 103'),
    "toggle_dark_mode": lambda: _run_osascript(
        'tell application "System Events" to tell appearance preferences '
        "to set dark mode to not dark mode"),
}


def _execute_system(action: Action) -> None:
    handler = SYSTEM_COMMANDS.get(action.command or "")
    if handler is None:
        logger.error("Unknown system command: %s", action.command)
        return
    handler()


def _execute_volume(action: Action) -> None:
    if action.level is None:
        logger.error("Volume action missing level")
        return
    _run_osascript(f"set volume output volume {int(action.level)}")


def _execute_notification(action: Action) -> None:
    if not action.text:
        logger.error("Notification action missing text")
        return
    source = f"display notification {_applescript_quote(action.text)}"
    if action.title:
        source += f" with title {_applescript_quote(action.title)}"
    _run_osascript(source)


def _applescript_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _execute_sequence(action: Action) -> None:
    for i, step in enumerate(action.steps):
        if i and action.delay:
            time.sleep(action.delay)
        execute(step)


_EXECUTORS = {
    "macro": _execute_macro,
    "media": _execute_media,
    "app": _execute_app,
    "script": _execute_script,
    "shell": _execute_shell,
    "aerospace": _execute_aerospace,
    "url": _execute_url,
    "text": _execute_text,
    "applescript": _execute_applescript,
    "shortcut": _execute_shortcut,
    "system": _execute_system,
    "volume": _execute_volume,
    "notification": _execute_notification,
    "sequence": _execute_sequence,
}


def execute(action: Action) -> None:
    """Execute configured Action object safely without raising unhandled exceptions."""
    try:
        executor = _EXECUTORS.get(action.type)
        if executor is None:
            logger.error("Unknown action type: %s", action.type)
            return
        executor(action)
    except Exception as e:
        logger.error("Exception occurred executing action type '%s': %s", getattr(action, 'type', None), e)
