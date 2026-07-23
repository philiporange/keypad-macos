"""Localhost HTTP server and browser-based configuration editor backend for Keypad.

Provides a thread-safe HTTP server using stdlib http.server to expose config editing routes:
- GET /: serves static single-file web editor interface (index.html)
- GET /api/config: returns JSON representation of current TOML config
- GET /api/meta: returns metadata constants (action_types, media_controls, log_levels)
- GET /api/config.toml: returns raw text content of current TOML file
- PUT /api/config: validates, updates, and atomically replaces TOML configuration file
"""

import json
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from . import config


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
        items = [f"{k} = {_format_value(v)}" for k, v in val.items() if v is not None]
        return f"{{ {', '.join(items)} }}"
    return json.dumps(str(val))


def _format_inline_table(d: dict) -> str:
    """Format dictionary into an inline TOML table string."""
    if not isinstance(d, dict):
        return "{}"
    items = []
    keys = list(d.keys())
    if "type" in keys:
        keys.remove("type")
        keys.insert(0, "type")
    for k in keys:
        v = d[k]
        if v is None:
            continue
        if isinstance(v, list) and len(v) == 0:
            continue
        if isinstance(v, str) and v == "":
            continue
        items.append(f"{k} = {_format_value(v)}")
    return f"{{ {', '.join(items)} }}"


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

    if dev.get("usage_page") is not None:
        up = dev["usage_page"]
        if isinstance(up, str) and up.startswith("0x"):
            up = int(up, 16)
        if isinstance(up, int):
            lines.append(f"usage_page = 0x{up:04x}")
        else:
            lines.append(f"usage_page = {up}")

    if dev.get("usage") is not None:
        u = dev["usage"]
        if isinstance(u, str) and u.startswith("0x"):
            u = int(u, 16)
        if isinstance(u, int):
            lines.append(f"usage = 0x{u:04x}")
        else:
            lines.append(f"usage = {u}")

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
        if kn.get("on_cw"):
            lines.append(f"on_cw = {_format_inline_table(kn['on_cw'])}")
        if kn.get("on_ccw"):
            lines.append(f"on_ccw = {_format_inline_table(kn['on_ccw'])}")
        if kn.get("on_press"):
            lines.append(f"on_press = {_format_inline_table(kn['on_press'])}")
        lines.append("")

    return "\n".join(lines)


def _action_to_dict(action: Any) -> Optional[dict]:
    if action is None:
        return None
    d = {}
    if hasattr(action, "__dataclass_fields__"):
        for fname in action.__dataclass_fields__:
            val = getattr(action, fname)
            if val is not None and val != [] and val != "":
                d[fname] = val
    elif isinstance(action, dict):
        for k, v in action.items():
            if v is not None and v != [] and v != "":
                d[k] = v
    if hasattr(action, "type"):
        d["type"] = action.type
    return d if d else None


def _create_request_handler(config_path: str, on_saved: Optional[Callable[[], None]]) -> type:
    class ConfigRequestHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:
            """Suppress per-request HTTP server logging."""
            pass

        def _send_json(self, status_code: int, payload: Any) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_text(self, status_code: int, content_type: str, body_text: str) -> None:
            body = body_text.encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            parsed_path = self.path.split("?")[0]
            if parsed_path in ("/", "/index.html"):
                html_file = Path(__file__).parent / "static" / "index.html"
                if not html_file.exists():
                    self._send_json(404, {"error": "Index file not found"})
                    return
                try:
                    content = html_file.read_text(encoding="utf-8")
                    self._send_text(200, "text/html; charset=utf-8", content)
                except Exception as e:
                    self._send_json(500, {"error": str(e)})

            elif parsed_path == "/api/config":
                try:
                    cfg = config.load_config(config_path)
                    res = {
                        "device": {
                            "vendor_id": cfg.device.vendor_id,
                            "product_id": cfg.device.product_id,
                            "usage_page": cfg.device.usage_page,
                            "usage": cfg.device.usage,
                            "protocol": cfg.device.protocol,
                        },
                        "layout": {
                            "rows": cfg.layout.rows,
                            "cols": cfg.layout.cols,
                            "knobs": cfg.layout.knobs,
                        },
                        "app": {
                            "statusbar": cfg.statusbar,
                            "log_level": cfg.log_level,
                            "icon": getattr(cfg, "icon", None),
                        },
                        "keys": [
                            {
                                "row": k.row,
                                "col": k.col,
                                "action": _action_to_dict(k.action),
                            }
                            for k in cfg.keys
                        ],
                        "knobs": [
                            {
                                "index": kn.index,
                                "on_cw": _action_to_dict(kn.on_cw),
                                "on_ccw": _action_to_dict(kn.on_ccw),
                                "on_press": _action_to_dict(kn.on_press),
                            }
                            for kn in cfg.knobs
                        ],
                    }
                    self._send_json(200, res)
                except Exception as e:
                    self._send_json(400, {"error": str(e)})

            elif parsed_path == "/api/meta":
                action_types = list(getattr(config, "VALID_ACTION_TYPES", ["macro", "media", "app", "script", "shell"]))
                if "aerospace" not in action_types:
                    action_types.append("aerospace")
                media_controls = list(getattr(config, "VALID_MEDIA_CONTROLS", ["play_pause", "next", "previous", "volume_up", "volume_down", "mute", "brightness_up", "brightness_down"]))
                log_levels = ["DEBUG", "INFO", "WARNING", "ERROR"]

                self._send_json(200, {
                    "action_types": action_types,
                    "media_controls": media_controls,
                    "log_levels": log_levels,
                })

            elif parsed_path == "/api/config.toml":
                try:
                    content = Path(config_path).read_text(encoding="utf-8")
                    self._send_text(200, "text/plain; charset=utf-8", content)
                except Exception as e:
                    self._send_json(500, {"error": str(e)})

            else:
                self._send_json(404, {"error": "Not Found"})

        def do_PUT(self) -> None:
            parsed_path = self.path.split("?")[0]
            if parsed_path != "/api/config":
                self._send_json(404, {"error": "Not Found"})
                return

            try:
                content_len = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_len).decode("utf-8")
                data = json.loads(body)
            except Exception as e:
                self._send_json(400, {"error": f"Invalid JSON payload: {e}"})
                return

            try:
                toml_text = dumps_toml(data)
                tmp_fd, tmp_path = tempfile.mkstemp(prefix="keypad_cfg_", suffix=".toml")
                with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                    f.write(toml_text)

                # Validate generated config file
                config.load_config(tmp_path)

                # Atomically replace target config file
                os.replace(tmp_path, config_path)
                if on_saved is not None:
                    on_saved()

                self._send_json(200, {"ok": True})
            except config.ConfigError as e:
                if 'tmp_path' in locals() and os.path.exists(tmp_path):
                    os.unlink(tmp_path)
                self._send_json(400, {"error": str(e)})
                return
            except Exception as e:
                if 'tmp_path' in locals() and os.path.exists(tmp_path):
                    os.unlink(tmp_path)
                self._send_json(400, {"error": str(e)})
                return

    return ConfigRequestHandler


class ConfigServer:
    """Localhost HTTP server for managing keypad TOML configuration."""

    def __init__(
        self,
        config_path: str,
        on_saved: Optional[Callable[[], None]] = None,
        host: str = "127.0.0.1",
        port: int = 0,
    ):
        self.config_path = str(Path(config_path).expanduser().resolve())
        self.on_saved = on_saved
        self.host = host
        self.port = port
        self._server: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        """Bind HTTP server on host:port and launch daemon worker thread."""
        handler_cls = _create_request_handler(self.config_path, self.on_saved)
        self._server = ThreadingHTTPServer((self.host, self.port), handler_cls)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self) -> str:
        """Return root HTTP URL with bound port."""
        if not self._server:
            return ""
        actual_port = self._server.server_port
        return f"http://{self.host}:{actual_port}/"

    def stop(self) -> None:
        """Cleanly shut down server and close socket listener."""
        if self._server:
            self._server.shutdown()
            self._server.server_close()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
