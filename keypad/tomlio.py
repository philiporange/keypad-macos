"""TOML serialization for keypad configuration.

Converts the dict representation used by the config editor back into the
TOML file format that config.load_config parses. Kept separate from the
editor UI so it can be tested without AppKit.
"""

import json
from typing import Any, Optional


def _format_value(val: Any) -> str:
    """Format python primitive values into valid TOML syntax representation."""
    if isinstance(val, bool):
        return "true" if val else "false"
    elif isinstance(val, (int, float)):
        return str(val)
    elif isinstance(val, str):
        return json.dumps(val)
    elif isinstance(val, list):
        items = [_format_value(item) for item in val]
        return f"[{', '.join(items)}]"
    elif isinstance(val, dict):
        return _format_inline_table(val)
    return json.dumps(str(val))


def _format_inline_table(d: dict) -> str:
    """Format dictionary into an inline TOML table string, 'type' key first."""
    if not isinstance(d, dict):
        return "{}"
    keys = list(d.keys())
    if "type" in keys:
        keys.remove("type")
        keys.insert(0, "type")
    items = []
    for k in keys:
        v = d[k]
        if v is None or v == [] or v == "":
            continue
        items.append(f"{k} = {_format_value(v)}")
    return f"{{ {', '.join(items)} }}"


def action_to_dict(action: Any) -> Optional[dict]:
    """Convert an Action dataclass (or dict) to a sparse plain dict."""
    if action is None:
        return None
    d = {}
    if hasattr(action, "__dataclass_fields__"):
        for fname in action.__dataclass_fields__:
            val = getattr(action, fname)
            if isinstance(val, list):
                val = [action_to_dict(v) if hasattr(v, "__dataclass_fields__") else v
                       for v in val]
            if val is not None and val != [] and val != "" and val != 0.0:
                d[fname] = val
    elif isinstance(action, dict):
        for k, v in action.items():
            if v is not None and v != [] and v != "":
                d[k] = v
    if hasattr(action, "type"):
        d["type"] = action.type
    return d if d else None


def dumps_toml(data: dict) -> str:
    """Serialize dictionary representation into standard TOML string for keypad config."""
    lines = []

    # [device]
    dev = data.get("device", {})
    lines.append("[device]")
    vid = dev.get("vendor_id", 0)
    pid = dev.get("product_id", 0)
    if isinstance(vid, str) and vid.startswith("0x"):
        vid = int(vid, 16)
    if isinstance(pid, str) and pid.startswith("0x"):
        pid = int(pid, 16)
    lines.append(f"vendor_id = 0x{vid:04x}")
    lines.append(f"product_id = 0x{pid:04x}")

    for key in ("usage_page", "usage"):
        if dev.get(key) is not None:
            v = dev[key]
            if isinstance(v, str) and v.startswith("0x"):
                v = int(v, 16)
            if isinstance(v, int):
                lines.append(f"{key} = 0x{v:04x}")
            else:
                lines.append(f"{key} = {v}")

    if dev.get("protocol"):
        lines.append(f'protocol = "{dev["protocol"]}"')
    lines.append("")

    # [layout]
    layout = data.get("layout", {})
    lines.append("[layout]")
    lines.append(f"rows = {layout.get('rows', 0)}")
    lines.append(f"cols = {layout.get('cols', 0)}")
    lines.append(f"knobs = {layout.get('knobs', 0)}")
    lines.append("")

    # [app]
    app = data.get("app", {})
    lines.append("[app]")
    lines.append(f"statusbar = {'true' if app.get('statusbar', True) else 'false'}")
    log_level = app.get("log_level", "INFO")
    lines.append(f'log_level = "{log_level}"')
    if app.get("icon") is not None:
        lines.append(f'icon = {json.dumps(app["icon"])}')
    lines.append(f"launch_at_login = {'true' if app.get('launch_at_login') else 'false'}")
    lines.append("")

    # [[key]]
    for k in data.get("keys", []):
        lines.append("[[key]]")
        lines.append(f"row = {k.get('row', 0)}")
        lines.append(f"col = {k.get('col', 0)}")
        act = k.get("action")
        if act:
            lines.append(f"action = {_format_inline_table(act)}")
        lines.append("")

    # [[knob]]
    for kn in data.get("knobs", []):
        lines.append("[[knob]]")
        lines.append(f"index = {kn.get('index', 0)}")
        for evt in ("on_cw", "on_ccw", "on_press"):
            if kn.get(evt):
                lines.append(f"{evt} = {_format_inline_table(kn[evt])}")
        lines.append("")

    return "\n".join(lines)
