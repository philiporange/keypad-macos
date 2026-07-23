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


def _kb_report(mod: int, *usages: int) -> bytes:
    """Build a 9-byte keyboard report (report ID 2) as sent by the CH57x pad."""
    keys = list(usages) + [0] * (6 - len(usages))
    return bytes([2, mod, 0] + keys)


def test_keyboard_decoder_grid_corners():
    """F13/F16/F21/F24 map to the four corners of a 3x4 grid."""
    from keypad.events import KeyboardReportDecoder

    decoder = KeyboardReportDecoder(rows=3, cols=4, knobs=2)

    assert decoder.decode(_kb_report(0, 0x68)) == KeyEvent(row=0, col=0, pressed=True)
    assert decoder.decode(_kb_report(0)) == KeyEvent(row=0, col=0, pressed=False)

    assert decoder.decode(_kb_report(0, 0x6B)) == KeyEvent(row=0, col=3, pressed=True)
    assert decoder.decode(_kb_report(0)) == KeyEvent(row=0, col=3, pressed=False)

    assert decoder.decode(_kb_report(0, 0x70)) == KeyEvent(row=2, col=0, pressed=True)
    assert decoder.decode(_kb_report(0)) == KeyEvent(row=2, col=0, pressed=False)

    assert decoder.decode(_kb_report(0, 0x73)) == KeyEvent(row=2, col=3, pressed=True)
    assert decoder.decode(_kb_report(0)) == KeyEvent(row=2, col=3, pressed=False)


def test_keyboard_decoder_knobs():
    """Ctrl+F13..F18 map to knob 0/1 ccw, press, cw; releases emit nothing."""
    from keypad.events import KeyboardReportDecoder

    decoder = KeyboardReportDecoder(rows=3, cols=4, knobs=2)

    assert decoder.decode(_kb_report(0x01, 0x68)) == KnobEvent(index=0, direction="ccw")
    assert decoder.decode(_kb_report(0x01)) is None  # knob release: no event
    assert decoder.decode(_kb_report(0x01, 0x69)) == KnobEvent(index=0, direction="press")
    assert decoder.decode(_kb_report(0x01)) is None
    assert decoder.decode(_kb_report(0x01, 0x6A)) == KnobEvent(index=0, direction="cw")
    assert decoder.decode(_kb_report(0x01)) is None
    assert decoder.decode(_kb_report(0x01, 0x6B)) == KnobEvent(index=1, direction="ccw")
    assert decoder.decode(_kb_report(0x01)) is None
    assert decoder.decode(_kb_report(0x01, 0x6D)) == KnobEvent(index=1, direction="cw")


def test_keyboard_decoder_held_key_no_repeat():
    """A key held across several reports emits a single press event."""
    from keypad.events import KeyboardReportDecoder

    decoder = KeyboardReportDecoder(rows=3, cols=4, knobs=2)

    assert decoder.decode(_kb_report(0, 0x68)) == KeyEvent(row=0, col=0, pressed=True)
    assert decoder.decode(_kb_report(0, 0x68)) is None
    assert decoder.decode(_kb_report(0, 0x68)) is None
    assert decoder.decode(_kb_report(0)) == KeyEvent(row=0, col=0, pressed=False)


def test_keyboard_decoder_ignores_foreign_reports():
    """Non-keyboard, short, or out-of-range reports return None."""
    from keypad.events import KeyboardReportDecoder

    decoder = KeyboardReportDecoder(rows=3, cols=4, knobs=2)

    assert decoder.decode(b"") is None
    assert decoder.decode(bytes([9, 1, 2])) is None
    # usage below F13 (ordinary typing) is ignored
    assert decoder.decode(_kb_report(0, 0x04)) is None
    # usage beyond the configured grid is ignored
    decoder2 = KeyboardReportDecoder(rows=1, cols=2, knobs=1)
    assert decoder2.decode(_kb_report(0, 0x6C)) is None  # F17 > 1x2 grid
    assert decoder2.decode(_kb_report(0x01, 0x6B)) is None  # knob 1 > 1 knob
