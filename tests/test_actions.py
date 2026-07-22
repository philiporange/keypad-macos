"""Tests for action execution and chord parsing in keypad/actions.py.

Uses unittest.mock to test app launch via 'open', script execution, shell commands,
safe exception handling/logging during failures, and chord string parsing for Quartz key synthesising.
"""

from unittest.mock import patch

from keypad.actions import MODIFIER_MASKS, execute, parse_chord
from keypad.config import Action


@patch("keypad.actions.subprocess.run")
def test_app_action(mock_run):
    """Verify app action triggers 'open -a NAME' or 'open PATH' via subprocess."""
    act_name = Action(type="app", name="Safari")
    execute(act_name)
    mock_run.assert_called_once_with(["open", "-a", "Safari"], check=True)

    mock_run.reset_mock()
    act_path = Action(type="app", path="/Applications/Safari.app")
    execute(act_path)
    mock_run.assert_called_once_with(["open", "/Applications/Safari.app"], check=True)


@patch("keypad.actions.subprocess.run")
def test_script_action(mock_run):
    """Verify script action executes path and arguments via subprocess."""
    act = Action(type="script", path="/usr/local/bin/my_script.py", args=["--flag", "val"])
    execute(act)
    mock_run.assert_called_once_with(["/usr/local/bin/my_script.py", "--flag", "val"], check=True)


@patch("keypad.actions.subprocess.run")
def test_shell_action(mock_run):
    """Verify shell action executes command with shell=True via subprocess."""
    act = Action(type="shell", command="echo 'test' >> /tmp/out.log")
    execute(act)
    mock_run.assert_called_once_with("echo 'test' >> /tmp/out.log", shell=True, check=True)


@patch("keypad.actions.subprocess.run", side_effect=RuntimeError("Subprocess failed"))
def test_failed_action_logs_and_does_not_raise(mock_run, caplog):
    """Verify that action failures or unknown action types log errors and never raise exceptions."""
    act = Action(type="shell", command="failing_cmd")
    execute(act)  # Must not raise
    assert "Exception occurred" in caplog.text or "Subprocess failed" in caplog.text

    caplog.clear()
    act_unknown = Action(type="non_existent_type")
    execute(act_unknown)  # Must not raise
    assert "Unknown action type" in caplog.text


def test_chord_parser(caplog):
    """Verify chord parser converts shortcut strings to modifier masks and keycodes, and handles nonsense."""
    result = parse_chord("cmd+shift+4")
    assert result is not None
    flags, keycode = result

    expected_flags = MODIFIER_MASKS["cmd"] | MODIFIER_MASKS["shift"]
    assert flags == expected_flags
    assert keycode == 0x15  # Keycode for '4'

    # Test invalid nonsense chord string
    caplog.clear()
    res_nonsense = parse_chord("invalid_modifier+nonsense_key_99")
    assert res_nonsense is None
    assert "Unknown key or modifier" in caplog.text
