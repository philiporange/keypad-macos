"""Tests for event decoding in keypad/events.py.

Verifies row-major index-to-grid mapping at layout corners, press/release states,
knob CW/CCW/press events, ignoring invalid or short byte reports, and custom decode hooks.
"""

from keypad.events import KeyEvent, KnobEvent, ReportDecoder


def test_row_major_corners_and_press_release():
    """Verify corner key index mapping to (row, col) and pressed state."""
    decoder = ReportDecoder(rows=3, cols=4, knobs=2)

    # Top-left corner: key 0 pressed -> (0, 0, True)
    ev0 = decoder.decode(bytes([1, 0, 1]))
    assert ev0 == KeyEvent(row=0, col=0, pressed=True)

    # Top-left corner: key 0 released -> (0, 0, False)
    ev0_rel = decoder.decode(bytes([1, 0, 0]))
    assert ev0_rel == KeyEvent(row=0, col=0, pressed=False)

    # Bottom-right corner: key 11 -> (2, 3, True)
    ev11 = decoder.decode(bytes([1, 11, 1]))
    assert ev11 == KeyEvent(row=2, col=3, pressed=True)


def test_knob_directions():
    """Verify knob report decoding for cw, ccw, and press directions."""
    decoder = ReportDecoder(rows=3, cols=4, knobs=2)

    # Knob 0 CW
    assert decoder.decode(bytes([2, 0, 1])) == KnobEvent(index=0, direction="cw")
    # Knob 0 CCW
    assert decoder.decode(bytes([2, 0, 2])) == KnobEvent(index=0, direction="ccw")
    # Knob 0 Press
    assert decoder.decode(bytes([2, 0, 3])) == KnobEvent(index=0, direction="press")
    # Knob 1 CW
    assert decoder.decode(bytes([2, 1, 1])) == KnobEvent(index=1, direction="cw")


def test_unknown_report_types_and_short_reports():
    """Verify that invalid/short reports or out-of-bounds indices return None."""
    decoder = ReportDecoder(rows=3, cols=4, knobs=2)

    # Short report (< 3 bytes)
    assert decoder.decode(bytes([1, 0])) is None
    assert decoder.decode(bytes([])) is None

    # Unknown report type (byte 0 not 1 or 2)
    assert decoder.decode(bytes([3, 0, 1])) is None

    # Out of bounds key index
    assert decoder.decode(bytes([1, 20, 1])) is None

    # Out of bounds knob index
    assert decoder.decode(bytes([2, 5, 1])) is None

    # Invalid press value / knob direction byte
    assert decoder.decode(bytes([1, 0, 5])) is None
    assert decoder.decode(bytes([2, 0, 5])) is None


def test_custom_hook_overrides_default():
    """Verify that a custom decoder function takes precedence when returning non-None."""
    def custom_dec(data: bytes):
        if data == bytes([0xFF, 0x01]):
            return KeyEvent(row=9, col=9, pressed=True)
        return None

    decoder = ReportDecoder(rows=3, cols=4, knobs=2, custom=custom_dec)

    # Custom report handled by custom hook
    assert decoder.decode(bytes([0xFF, 0x01])) == KeyEvent(row=9, col=9, pressed=True)

    # Standard report falls back to default decoder
    assert decoder.decode(bytes([1, 0, 1])) == KeyEvent(row=0, col=0, pressed=True)
