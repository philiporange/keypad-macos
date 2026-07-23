"""Launch-at-login management via macOS login items.

Uses System Events (AppleScript) to add or remove the app bundle as a login
item. This requires the Automation permission for System Events the first
time it runs; macOS prompts for it.
"""

import logging
import subprocess

logger = logging.getLogger(__name__)

APP_PATH = "/Applications/Keypad.app"
APP_NAME = "Keypad"


def _osascript(source: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/usr/bin/osascript", "-e", source], capture_output=True, text=True
    )


def is_enabled() -> bool:
    """Whether the app is currently registered as a login item."""
    result = _osascript(
        'tell application "System Events" to get the name of every login item'
    )
    if result.returncode != 0:
        logger.error("Failed to read login items: %s", result.stderr.strip())
        return False
    names = [n.strip() for n in result.stdout.split(",")]
    return APP_NAME in names


def set_enabled(enabled: bool) -> bool:
    """Add or remove the login item. Returns True on success."""
    if enabled == is_enabled():
        return True
    if enabled:
        source = (
            'tell application "System Events" to make new login item at end '
            f'with properties {{path:"{APP_PATH}", hidden:false}}'
        )
    else:
        source = (
            f'tell application "System Events" to delete login item "{APP_NAME}"'
        )
    result = _osascript(source)
    if result.returncode != 0:
        logger.error(
            "Failed to %s login item: %s",
            "add" if enabled else "remove",
            result.stderr.strip(),
        )
        return False
    return True
