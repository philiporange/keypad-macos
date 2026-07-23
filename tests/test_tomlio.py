"""Tests for TOML serialization (keypad/tomlio.py) and expanded action parsing.

Verifies dumps_toml round-trips through tomllib and load_config, including the
launch_at_login setting and the full range of action types.
"""

import tomllib

import pytest

from keypad.config import ConfigError, load_config
from keypad.tomlio import action_to_dict, dumps_toml


def _load(tmp_path, data: dict):
    cfg_file = tmp_path / "keypad.toml"
    cfg_file.write_text(dumps_toml(data))
    return load_config(cfg_file)


BASE = {
    "device": {"vendor_id": 0x1234, "product_id": 0x5678},
    "layout": {"rows": 3, "cols": 4, "knobs": 2},
    "app": {"statusbar": True, "log_level": "INFO"},
}


def test_dumps_toml_round_trip(tmp_path):
    """dumps_toml output parses with tomllib and preserves values."""
    data = {
        **BASE,
        "device": {"vendor_id": 0x1234, "product_id": 0x5678, "usage_page": 0xFF00, "usage": 1},
        "app": {"statusbar": True, "log_level": "DEBUG", "launch_at_login": True},
        "keys": [
            {"row": 0, "col": 1, "action": {"type": "macro", "keys": ["cmd+c", "cmd+v"]}},
            {"row": 2, "col": 3, "action": {"type": "shell", "command": "echo test"}},
        ],
        "knobs": [
            {"index": 0, "on_cw": {"type": "media", "control": "volume_up"}},
            {"index": 1, "on_press": {"type": "media", "control": "mute"}},
        ],
    }
    parsed = tomllib.loads(dumps_toml(data))
    assert parsed["device"]["vendor_id"] == 0x1234
    assert parsed["device"]["usage_page"] == 0xFF00
    assert parsed["app"]["launch_at_login"] is True
    assert parsed["key"][0]["action"]["keys"] == ["cmd+c", "cmd+v"]
    assert parsed["knob"][0]["on_cw"]["control"] == "volume_up"

    cfg = _load(tmp_path, data)
    assert cfg.launch_at_login is True
    assert cfg.keys[0].action.keys == ["cmd+c", "cmd+v"]


def test_new_action_types_round_trip(tmp_path):
    """Every new action type survives dumps_toml -> load_config."""
    keys = [
        {"row": 0, "col": 0, "action": {"type": "url", "url": "https://example.com"}},
        {"row": 0, "col": 1, "action": {"type": "text", "text": "hello world"}},
        {"row": 0, "col": 2, "action": {"type": "applescript", "source": 'display dialog "hi"'}},
        {"row": 0, "col": 3, "action": {"type": "shortcut", "name": "My Shortcut"}},
        {"row": 1, "col": 0, "action": {"type": "system", "command": "lock_screen"}},
        {"row": 1, "col": 1, "action": {"type": "volume", "level": 40}},
        {"row": 1, "col": 2, "action": {"type": "notification", "title": "Hi", "text": "there"}},
        {"row": 1, "col": 3, "action": {
            "type": "sequence",
            "delay": 0.5,
            "steps": [
                {"type": "app", "name": "Safari"},
                {"type": "macro", "keys": "cmd+t"},
            ],
        }},
    ]
    cfg = _load(tmp_path, {**BASE, "keys": keys})
    by_pos = {(k.row, k.col): k.action for k in cfg.keys}

    assert by_pos[(0, 0)].url == "https://example.com"
    assert by_pos[(0, 1)].text == "hello world"
    assert by_pos[(0, 2)].source == 'display dialog "hi"'
    assert by_pos[(0, 3)].name == "My Shortcut"
    assert by_pos[(1, 0)].command == "lock_screen"
    assert by_pos[(1, 1)].level == 40
    assert by_pos[(1, 2)].title == "Hi" and by_pos[(1, 2)].text == "there"
    seq = by_pos[(1, 3)]
    assert seq.delay == 0.5
    assert [s.type for s in seq.steps] == ["app", "macro"]


@pytest.mark.parametrize("action", [
    {"type": "url"},                                     # missing url
    {"type": "system", "command": "reboot"},             # not a valid system command
    {"type": "volume", "level": 150},                    # out of range
    {"type": "volume", "level": True},                   # bool is not a level
    {"type": "notification"},                            # missing text
    {"type": "sequence", "steps": []},                   # empty steps
    {"type": "sequence", "steps": [{"type": "sequence", "steps": [{"type": "shell", "command": "x"}]}]},  # nested
])
def test_invalid_actions_rejected(tmp_path, action):
    with pytest.raises(ConfigError):
        _load(tmp_path, {**BASE, "keys": [{"row": 0, "col": 0, "action": action}]})


def test_action_to_dict_nested_sequence(tmp_path):
    """action_to_dict flattens nested step dataclasses for re-serialization."""
    cfg = _load(tmp_path, {**BASE, "keys": [{"row": 0, "col": 0, "action": {
        "type": "sequence",
        "delay": 1.0,
        "steps": [{"type": "shell", "command": "true"}],
    }}]})
    d = action_to_dict(cfg.keys[0].action)
    assert d["type"] == "sequence"
    assert d["delay"] == 1.0
    assert d["steps"] == [{"type": "shell", "command": "true"}]

    # And it must round-trip again through dumps_toml.
    cfg2 = _load(tmp_path, {**BASE, "keys": [{"row": 0, "col": 0, "action": d}]})
    assert cfg2.keys[0].action.steps[0].command == "true"
