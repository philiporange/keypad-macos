"""Tests for web configuration server and TOML serialization in keypad/webconfig.py.

Verifies HTTP routes (GET / , GET /api/config, GET /api/meta, GET /api/config.toml),
PUT configuration update and on_saved callback execution, validation error handling (HTTP 400),
and dumps_toml round-trip with tomllib.
"""

import json
import sys
import urllib.error
import urllib.request
import pytest

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomllib

from keypad.config import load_config
from keypad.webconfig import ConfigServer, dumps_toml


@pytest.fixture
def sample_config(tmp_path):
    """Write a small test TOML configuration file to tmp_path."""
    cfg_file = tmp_path / "keypad.toml"
    cfg_file.write_text("""
[device]
vendor_id = 0x1234
product_id = 0x5678

[layout]
rows = 2
cols = 2
knobs = 1

[app]
statusbar = true
log_level = "INFO"

[[key]]
row = 0
col = 0
action = { type = "macro", keys = "cmd+c" }

[[knob]]
index = 0
on_cw = { type = "media", control = "volume_up" }
""")
    return cfg_file


def test_get_routes(sample_config):
    """Verify GET endpoints (/ , /api/config, /api/meta, /api/config.toml)."""
    server = ConfigServer(str(sample_config), port=0)
    server.start()
    url = server.url
    try:
        # GET /
        with urllib.request.urlopen(url) as resp:
            assert resp.status == 200
            content = resp.read().decode("utf-8")
            assert "<html" in content.lower()

        # GET /api/config
        with urllib.request.urlopen(url + "api/config") as resp:
            assert resp.status == 200
            data = json.loads(resp.read().decode("utf-8"))
            assert data["device"]["vendor_id"] == 0x1234
            assert data["device"]["product_id"] == 0x5678
            assert data["layout"]["rows"] == 2
            assert data["layout"]["cols"] == 2
            assert data["layout"]["knobs"] == 1
            assert len(data["keys"]) == 1
            assert data["keys"][0]["action"]["type"] == "macro"
            assert data["keys"][0]["action"]["keys"] == "cmd+c"

        # GET /api/meta
        with urllib.request.urlopen(url + "api/meta") as resp:
            assert resp.status == 200
            meta = json.loads(resp.read().decode("utf-8"))
            assert "aerospace" in meta["action_types"]
            assert "volume_up" in meta["media_controls"]
            assert "INFO" in meta["log_levels"]

        # GET /api/config.toml
        with urllib.request.urlopen(url + "api/config.toml") as resp:
            assert resp.status == 200
            toml_text = resp.read().decode("utf-8")
            assert "[device]" in toml_text
            assert "vendor_id = 0x1234" in toml_text
    finally:
        server.stop()


def test_put_valid_config(sample_config):
    """Verify PUT /api/config updates file and fires on_saved callback once."""
    saved_calls = 0

    def on_saved():
        nonlocal saved_calls
        saved_calls += 1

    server = ConfigServer(str(sample_config), on_saved=on_saved, port=0)
    server.start()
    url = server.url
    try:
        # GET current payload
        with urllib.request.urlopen(url + "api/config") as resp:
            payload = json.loads(resp.read().decode("utf-8"))

        # Modify payload: change key (0,0) action, add knob 0 on_ccw
        payload["keys"][0]["action"] = {"type": "media", "control": "play_pause"}
        payload["knobs"][0]["on_ccw"] = {"type": "media", "control": "volume_down"}

        req_data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url + "api/config",
            data=req_data,
            headers={"Content-Type": "application/json"},
            method="PUT",
        )

        with urllib.request.urlopen(req) as resp:
            assert resp.status == 200
            res = json.loads(resp.read().decode("utf-8"))
            assert res.get("ok") is True

        assert saved_calls == 1

        # Verify configuration file reloaded on disk matches changes
        cfg = load_config(sample_config)
        assert cfg.keys[0].action.type == "media"
        assert cfg.keys[0].action.control == "play_pause"
        assert cfg.knobs[0].on_ccw.type == "media"
        assert cfg.knobs[0].on_ccw.control == "volume_down"
    finally:
        server.stop()


def test_put_invalid_config(sample_config):
    """Verify PUT /api/config with invalid payload returns 400 and leaves file unchanged."""
    server = ConfigServer(str(sample_config), port=0)
    server.start()
    url = server.url
    original_text = sample_config.read_text(encoding="utf-8")
    try:
        with urllib.request.urlopen(url + "api/config") as resp:
            payload = json.loads(resp.read().decode("utf-8"))

        # 1. Invalid action type
        bad_payload = json.loads(json.dumps(payload))
        bad_payload["keys"][0]["action"] = {"type": "unknown_action_type_xyz"}
        req_data = json.dumps(bad_payload).encode("utf-8")
        req = urllib.request.Request(
            url + "api/config",
            data=req_data,
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(req)
        assert exc_info.value.code == 400
        err_json = json.loads(exc_info.value.read().decode("utf-8"))
        assert "error" in err_json

        # 2. Row out of range
        bad_row_payload = json.loads(json.dumps(payload))
        bad_row_payload["keys"][0]["row"] = 10
        req_data2 = json.dumps(bad_row_payload).encode("utf-8")
        req2 = urllib.request.Request(
            url + "api/config",
            data=req_data2,
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        with pytest.raises(urllib.error.HTTPError) as exc_info2:
            urllib.request.urlopen(req2)
        assert exc_info2.value.code == 400
        err_json2 = json.loads(exc_info2.value.read().decode("utf-8"))
        assert "error" in err_json2

        # Verify file content is completely unchanged
        assert sample_config.read_text(encoding="utf-8") == original_text
    finally:
        server.stop()


def test_dumps_toml_round_trip():
    """Verify dumps_toml round-trip with tomllib.loads preserves data and hex IDs as ints."""
    data = {
        "device": {"vendor_id": 0x1234, "product_id": 0x5678, "usage_page": 0xFF00, "usage": 1},
        "layout": {"rows": 3, "cols": 4, "knobs": 2},
        "app": {"statusbar": True, "log_level": "DEBUG"},
        "keys": [
            {"row": 0, "col": 1, "action": {"type": "macro", "keys": ["cmd+c", "cmd+v"]}},
            {"row": 2, "col": 3, "action": {"type": "shell", "command": "echo test"}},
        ],
        "knobs": [
            {"index": 0, "on_cw": {"type": "media", "control": "volume_up"}},
            {"index": 1, "on_press": {"type": "media", "control": "mute"}},
        ],
    }

    toml_str = dumps_toml(data)
    parsed = tomllib.loads(toml_str)

    assert parsed["device"]["vendor_id"] == 0x1234
    assert parsed["device"]["product_id"] == 0x5678
    assert parsed["device"]["usage_page"] == 0xFF00
    assert parsed["device"]["usage"] == 1
    assert parsed["layout"]["rows"] == 3
    assert parsed["layout"]["cols"] == 4
    assert parsed["layout"]["knobs"] == 2
    assert parsed["app"]["statusbar"] is True
    assert parsed["app"]["log_level"] == "DEBUG"
    assert len(parsed["key"]) == 2
    assert parsed["key"][0]["action"]["keys"] == ["cmd+c", "cmd+v"]
    assert len(parsed["knob"]) == 2
    assert parsed["knob"][0]["on_cw"]["control"] == "volume_up"
