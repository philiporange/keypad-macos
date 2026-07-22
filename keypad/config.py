"""Configuration loader and validator for macro keypad bindings using TOML format.

This module parses and validates TOML configuration files specifying device identifiers,
grid layout dimensions, statusbar settings, and mappings for key grid coordinates and knob
rotations/clicks to specific executable actions (macro, media, app, script, shell).
"""

import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Union


class ConfigError(Exception):
    """Raised when configuration file parsing or validation fails."""
    pass


@dataclass
class Action:
    """Represents an executable action triggered by a key or knob event."""
    type: str  # 'macro' | 'media' | 'app' | 'script' | 'shell' | 'aerospace'
    keys: Optional[Union[str, List[str]]] = None
    control: Optional[str] = None
    name: Optional[str] = None
    path: Optional[str] = None
    args: List[str] = field(default_factory=list)
    command: Optional[str] = None


@dataclass
class Device:
    """HID Device specifications."""
    vendor_id: int
    product_id: int
    usage_page: Optional[int] = None
    usage: Optional[int] = None


@dataclass
class Layout:
    """Keypad layout dimensions."""
    rows: int
    cols: int
    knobs: int


@dataclass
class KeyBinding:
    """Mapping from row/col coordinates to an action."""
    row: int
    col: int
    action: Action


@dataclass
class KnobBinding:
    """Mapping from a knob index to clockwise, counter-clockwise, and press actions."""
    index: int
    on_cw: Optional[Action] = None
    on_ccw: Optional[Action] = None
    on_press: Optional[Action] = None


@dataclass
class Config:
    """Complete application configuration object."""
    device: Device
    layout: Layout
    keys: List[KeyBinding] = field(default_factory=list)
    knobs: List[KnobBinding] = field(default_factory=list)
    statusbar: bool = True
    log_level: str = "INFO"


VALID_MEDIA_CONTROLS = {
    "play_pause",
    "next",
    "previous",
    "volume_up",
    "volume_down",
    "mute",
    "brightness_up",
    "brightness_down",
}

VALID_ACTION_TYPES = {"macro", "media", "app", "script", "shell", "aerospace"}


def _parse_action(data: Any) -> Action:
    if not isinstance(data, dict):
        raise ConfigError(f"Action must be a dictionary/table, got {type(data).__name__}")
    
    action_type = data.get("type")
    if not action_type or action_type not in VALID_ACTION_TYPES:
        raise ConfigError(f"Invalid or missing action type: {action_type}")

    if action_type == "macro":
        keys = data.get("keys")
        if not keys or not (isinstance(keys, str) or (isinstance(keys, list) and all(isinstance(k, str) for k in keys))):
            raise ConfigError("Macro action requires 'keys' string or list of strings")
        return Action(type="macro", keys=keys)

    elif action_type == "media":
        control = data.get("control")
        if not control or control not in VALID_MEDIA_CONTROLS:
            raise ConfigError(f"Media action requires valid 'control', got {control}")
        return Action(type="media", control=control)

    elif action_type == "app":
        name = data.get("name")
        path = data.get("path")
        if not name and not path:
            raise ConfigError("App action requires 'name' or 'path'")
        if name and not isinstance(name, str):
            raise ConfigError("App action 'name' must be a string")
        if path and not isinstance(path, str):
            raise ConfigError("App action 'path' must be a string")
        return Action(type="app", name=name, path=path)

    elif action_type == "script":
        path = data.get("path")
        if not path or not isinstance(path, str):
            raise ConfigError("Script action requires string 'path'")
        args = data.get("args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ConfigError("Script action 'args' must be a list of strings")
        return Action(type="script", path=path, args=args)

    elif action_type == "shell":
        command = data.get("command")
        if not command or not isinstance(command, str):
            raise ConfigError("Shell action requires string 'command'")
        return Action(type="shell", command=command)

    elif action_type == "aerospace":
        command = data.get("command")
        if not command or not isinstance(command, str):
            raise ConfigError(
                "Aerospace action requires string 'command' (e.g. 'workspace 3')"
            )
        return Action(type="aerospace", command=command)

    raise ConfigError(f"Unsupported action type: {action_type}")


def load_config(path: Union[str, Path]) -> Config:
    """Load, parse, and validate TOML configuration from file path."""
    file_path = Path(path).expanduser()
    if not file_path.exists():
        raise ConfigError(f"Configuration file not found: {file_path}")

    try:
        with open(file_path, "rb") as f:
            data = tomllib.load(f)
    except Exception as e:
        raise ConfigError(f"Error parsing TOML configuration: {e}") from e

    if not isinstance(data, dict):
        raise ConfigError("Configuration root must be a table")

    # Validate [device]
    device_table = data.get("device")
    if not isinstance(device_table, dict):
        raise ConfigError("Missing or invalid [device] section")
    
    vendor_id = device_table.get("vendor_id")
    product_id = device_table.get("product_id")
    if vendor_id is None or not isinstance(vendor_id, int):
        raise ConfigError("Device vendor_id must be an integer")
    if product_id is None or not isinstance(product_id, int):
        raise ConfigError("Device product_id must be an integer")
    
    usage_page = device_table.get("usage_page")
    if usage_page is not None and not isinstance(usage_page, int):
        raise ConfigError("Device usage_page must be an integer")
    usage = device_table.get("usage")
    if usage is not None and not isinstance(usage, int):
        raise ConfigError("Device usage must be an integer")

    device = Device(
        vendor_id=vendor_id,
        product_id=product_id,
        usage_page=usage_page,
        usage=usage,
    )

    # Validate [layout]
    layout_table = data.get("layout")
    if not isinstance(layout_table, dict):
        raise ConfigError("Missing or invalid [layout] section")

    rows = layout_table.get("rows")
    cols = layout_table.get("cols")
    knobs = layout_table.get("knobs")

    if rows is None or not isinstance(rows, int) or rows <= 0:
        raise ConfigError("Layout rows must be a positive integer")
    if cols is None or not isinstance(cols, int) or cols <= 0:
        raise ConfigError("Layout cols must be a positive integer")
    if knobs is None or not isinstance(knobs, int) or knobs < 0:
        raise ConfigError("Layout knobs must be a non-negative integer")

    layout = Layout(rows=rows, cols=cols, knobs=knobs)

    # Validate [[key]]
    key_bindings: List[KeyBinding] = []
    seen_keys = set()
    raw_keys = data.get("key", [])
    if not isinstance(raw_keys, list):
        raise ConfigError("[[key]] must be a list of tables")

    for entry in raw_keys:
        if not isinstance(entry, dict):
            raise ConfigError("Key entry must be a table")
        r = entry.get("row")
        c = entry.get("col")
        if r is None or not isinstance(r, int) or not (0 <= r < layout.rows):
            raise ConfigError(f"Key binding row {r} out of range [0, {layout.rows - 1}]")
        if c is None or not isinstance(c, int) or not (0 <= c < layout.cols):
            raise ConfigError(f"Key binding col {c} out of range [0, {layout.cols - 1}]")
        
        if (r, c) in seen_keys:
            raise ConfigError(f"Duplicate key binding for row {r}, col {c}")
        seen_keys.add((r, c))

        action_data = entry.get("action")
        if not action_data:
            raise ConfigError(f"Key binding at ({r}, {c}) missing action")
        action = _parse_action(action_data)
        key_bindings.append(KeyBinding(row=r, col=c, action=action))

    # Validate [[knob]]
    knob_bindings: List[KnobBinding] = []
    seen_knobs = set()
    raw_knobs = data.get("knob", [])
    if not isinstance(raw_knobs, list):
        raise ConfigError("[[knob]] must be a list of tables")

    for entry in raw_knobs:
        if not isinstance(entry, dict):
            raise ConfigError("Knob entry must be a table")
        idx = entry.get("index")
        if idx is None or not isinstance(idx, int) or not (0 <= idx < layout.knobs):
            raise ConfigError(f"Knob index {idx} out of range [0, {layout.knobs - 1}]")

        if idx in seen_knobs:
            raise ConfigError(f"Duplicate knob binding for index {idx}")
        seen_knobs.add(idx)

        on_cw = _parse_action(entry["on_cw"]) if "on_cw" in entry else None
        on_ccw = _parse_action(entry["on_ccw"]) if "on_ccw" in entry else None
        on_press = _parse_action(entry["on_press"]) if "on_press" in entry else None

        knob_bindings.append(
            KnobBinding(index=idx, on_cw=on_cw, on_ccw=on_ccw, on_press=on_press)
        )

    # Validate [app]
    app_table = data.get("app", {})
    if not isinstance(app_table, dict):
        raise ConfigError("[app] section must be a table")

    statusbar = app_table.get("statusbar", True)
    if not isinstance(statusbar, bool):
        raise ConfigError("app.statusbar must be a boolean")

    log_level = app_table.get("log_level", "INFO")
    if not isinstance(log_level, str):
        raise ConfigError("app.log_level must be a string")

    return Config(
        device=device,
        layout=layout,
        keys=key_bindings,
        knobs=knob_bindings,
        statusbar=statusbar,
        log_level=log_level.upper(),
    )
