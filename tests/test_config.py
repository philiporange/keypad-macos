"""Tests for configuration file loading and validation in keypad/config.py.

Verifies TOML parsing into dataclasses, action type parsing, error handling for invalid action types,
out-of-range coordinates, duplicate bindings, and missing required fields.
"""

import pytest
from keypad.config import Config, ConfigError, load_config


def test_valid_config_parses(tmp_path):
    """Verify that a valid TOML configuration parses into correct dataclasses."""
    cfg_file = tmp_path / "valid.toml"
    cfg_file.write_text("""
[device]
vendor_id = 4660
product_id = 22136
usage_page = 65280
usage = 1

[layout]
rows = 3
cols = 3
knobs = 2

[app]
statusbar = false
log_level = "DEBUG"

[[key]]
row = 0
col = 0
action = { type = "macro", keys = "cmd+shift+4" }

[[knob]]
index = 0
on_cw = { type = "media", control = "volume_up" }
""")

    cfg = load_config(cfg_file)
    assert isinstance(cfg, Config)
    assert cfg.device.vendor_id == 4660
    assert cfg.device.product_id == 22136
    assert cfg.device.usage_page == 65280
    assert cfg.device.usage == 1
    assert cfg.layout.rows == 3
    assert cfg.layout.cols == 3
    assert cfg.layout.knobs == 2
    assert cfg.statusbar is False
    assert cfg.log_level == "DEBUG"
    assert len(cfg.keys) == 1
    assert cfg.keys[0].row == 0
    assert cfg.keys[0].col == 0
    assert cfg.keys[0].action.type == "macro"
    assert cfg.keys[0].action.keys == "cmd+shift+4"
    assert len(cfg.knobs) == 1
    assert cfg.knobs[0].index == 0
    assert cfg.knobs[0].on_cw.type == "media"
    assert cfg.knobs[0].on_cw.control == "volume_up"


def test_every_action_type(tmp_path):
    """Verify that all supported action types parse correctly."""
    cfg_file = tmp_path / "actions.toml"
    cfg_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 2
cols = 3
knobs = 1

[[key]]
row = 0
col = 0
action = { type = "macro", keys = ["cmd+c", "cmd+v"] }

[[key]]
row = 0
col = 1
action = { type = "media", control = "play_pause" }

[[key]]
row = 0
col = 2
action = { type = "app", name = "Safari" }

[[key]]
row = 1
col = 0
action = { type = "app", path = "/Applications/Notes.app" }

[[key]]
row = 1
col = 1
action = { type = "script", path = "/bin/ls", args = ["-la"] }

[[key]]
row = 1
col = 2
action = { type = "shell", command = "echo test" }

[[knob]]
index = 0
on_cw = { type = "aerospace", command = "workspace next" }
""")

    cfg = load_config(cfg_file)
    assert len(cfg.keys) == 6
    assert cfg.knobs[0].on_cw.type == "aerospace"
    assert cfg.knobs[0].on_cw.command == "workspace next"
    assert cfg.keys[0].action.keys == ["cmd+c", "cmd+v"]
    assert cfg.keys[1].action.control == "play_pause"
    assert cfg.keys[2].action.name == "Safari"
    assert cfg.keys[3].action.path == "/Applications/Notes.app"
    assert cfg.keys[4].action.path == "/bin/ls"
    assert cfg.keys[4].action.args == ["-la"]
    assert cfg.keys[5].action.command == "echo test"


def test_invalid_action_type(tmp_path):
    """Verify that an invalid action type raises ConfigError."""
    cfg_file = tmp_path / "invalid_action.toml"
    cfg_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 1
cols = 1
knobs = 0

[[key]]
row = 0
col = 0
action = { type = "invalid_type" }
""")

    with pytest.raises(ConfigError):
        load_config(cfg_file)


def test_out_of_range_row_col(tmp_path):
    """Verify that out-of-range key row/col or knob index raises ConfigError."""
    cfg_file = tmp_path / "out_of_range_key.toml"
    cfg_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 2
cols = 2
knobs = 1

[[key]]
row = 2
col = 0
action = { type = "shell", command = "ls" }
""")
    with pytest.raises(ConfigError):
        load_config(cfg_file)

    knob_file = tmp_path / "out_of_range_knob.toml"
    knob_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 2
cols = 2
knobs = 1

[[knob]]
index = 1
on_cw = { type = "media", control = "volume_up" }
""")
    with pytest.raises(ConfigError):
        load_config(knob_file)


def test_duplicate_key_binding(tmp_path):
    """Verify that duplicate key or knob bindings raise ConfigError."""
    key_file = tmp_path / "dup_key.toml"
    key_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 2
cols = 2
knobs = 1

[[key]]
row = 0
col = 0
action = { type = "shell", command = "ls" }

[[key]]
row = 0
col = 0
action = { type = "shell", command = "pwd" }
""")
    with pytest.raises(ConfigError):
        load_config(key_file)

    knob_file = tmp_path / "dup_knob.toml"
    knob_file.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 2
cols = 2
knobs = 2

[[knob]]
index = 0
on_cw = { type = "media", control = "volume_up" }

[[knob]]
index = 0
on_ccw = { type = "media", control = "volume_down" }
""")
    with pytest.raises(ConfigError):
        load_config(knob_file)


def test_missing_required_field(tmp_path):
    """Verify that missing required device or layout fields raise ConfigError."""
    missing_dev = tmp_path / "no_device.toml"
    missing_dev.write_text("""
[layout]
rows = 1
cols = 1
knobs = 0
""")
    with pytest.raises(ConfigError):
        load_config(missing_dev)

    missing_vid = tmp_path / "no_vid.toml"
    missing_vid.write_text("""
[device]
product_id = 2

[layout]
rows = 1
cols = 1
knobs = 0
""")
    with pytest.raises(ConfigError):
        load_config(missing_vid)

    missing_action_cmd = tmp_path / "no_cmd.toml"
    missing_action_cmd.write_text("""
[device]
vendor_id = 1
product_id = 2

[layout]
rows = 1
cols = 1
knobs = 0

[[key]]
row = 0
col = 0
action = { type = "shell" }
""")
    with pytest.raises(ConfigError):
        load_config(missing_action_cmd)
