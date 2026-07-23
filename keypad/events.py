"""HID input report decoder module converting raw bytes to structured key and knob events.

This module provides data structures for key presses/releases and knob movements, as well as a
ReportDecoder class configured with keypad dimensions. Decodes standard raw HID byte reports or
delegates to a user-supplied custom decoding function.
"""

from dataclasses import dataclass
from typing import Callable, List, Optional, Union


@dataclass
class KeyEvent:
    """Logical key event indicating grid coordinates and press state."""
    row: int
    col: int
    pressed: bool


@dataclass
class KnobEvent:
    """Logical knob event indicating knob index and rotation or press action."""
    index: int
    direction: str  # 'cw' | 'ccw' | 'press'


class ReportDecoder:
    """Decodes raw HID input report bytes into KeyEvent or KnobEvent objects."""

    def __init__(
        self,
        rows: int = 0,
        cols: int = 0,
        knobs: int = 0,
        custom: Optional[Callable[[bytes], Optional[Union[KeyEvent, KnobEvent]]]] = None,
    ):
        self.rows = rows
        self.cols = cols
        self.knobs = knobs
        self.custom = custom

    def decode(self, data: bytes) -> Optional[Union[KeyEvent, KnobEvent]]:
        """Decode raw HID byte sequence into a KeyEvent, KnobEvent, or None."""
        if self.custom is not None:
            res = self.custom(data)
            if res is not None:
                return res

        if not data or len(data) < 3:
            return None

        report_type = data[0]

        if report_type == 1:
            # Key report
            key_index = data[1]
            pressed_val = data[2]
            if pressed_val not in (0, 1):
                return None
            
            if self.cols <= 0 or self.rows <= 0:
                return None

            row = key_index // self.cols
            col = key_index % self.cols

            if key_index >= self.rows * self.cols or row >= self.rows or col >= self.cols:
                return None

            return KeyEvent(row=row, col=col, pressed=(pressed_val == 1))

        elif report_type == 2:
            # Knob report
            knob_index = data[1]
            dir_val = data[2]

            dir_map = {1: "cw", 2: "ccw", 3: "press"}
            if dir_val not in dir_map:
                return None

            if knob_index < 0 or knob_index >= self.knobs:
                return None

            return KnobEvent(index=knob_index, direction=dir_map[dir_val])

        return None


class KeyboardReportDecoder:
    """Decodes standard HID keyboard reports from a keypad programmed to emit
    F13..F24 for grid keys and Ctrl+F13.. for knob actions.

    Expected programming (via e.g. ch57x-keyboard-tool):
    - Grid keys send plain F13..F24 (HID usages 0x68..0x73), row-major.
    - Knob N sends Ctrl+F(13 + 3N) for ccw, Ctrl+F(14 + 3N) for press,
      Ctrl+F(15 + 3N) for cw.

    Reports are stateful (a report lists all keys currently held), so the
    decoder tracks the previous key set and emits an event only on change.
    """

    F13_USAGE = 0x68  # HID usage of F13; F14..F24 follow contiguously
    CTRL_MASK = 0x11  # left or right Ctrl modifier bits
    KNOB_DIRECTIONS = ("ccw", "press", "cw")

    def __init__(self, rows: int = 0, cols: int = 0, knobs: int = 0):
        self.rows = rows
        self.cols = cols
        self.knobs = knobs
        self._held: set = set()

    def decode(self, data: bytes) -> Optional[Union[KeyEvent, KnobEvent]]:
        """Decode a raw keyboard report into a KeyEvent, KnobEvent, or None."""
        parsed = self._parse_report(data)
        if parsed is None:
            return None
        modifier, usages = parsed

        current = {(modifier & self.CTRL_MASK != 0, u) for u in usages}
        pressed = current - self._held
        released = self._held - current
        self._held = current

        # A report carries at most one change in practice; prefer new presses.
        for ctrl, usage in pressed:
            event = self._event_for(ctrl, usage, pressed=True)
            if event is not None:
                return event
        for ctrl, usage in released:
            event = self._event_for(ctrl, usage, pressed=False)
            # Knob rotations/presses have no release semantics.
            if isinstance(event, KeyEvent):
                return event
        return None

    def _parse_report(self, data: bytes) -> Optional[tuple]:
        """Extract (modifier, key usages) from a report, with or without a report ID."""
        if not data:
            return None
        if len(data) >= 9 and data[0] in (1, 2):
            # report ID, modifier, reserved, 6 key usages
            return data[1], [u for u in data[3:9] if u]
        if len(data) == 8:
            # modifier, reserved, 6 key usages (no report ID)
            return data[0], [u for u in data[2:8] if u]
        return None

    def _event_for(self, ctrl: bool, usage: int, pressed: bool) -> Optional[Union[KeyEvent, KnobEvent]]:
        index = usage - self.F13_USAGE
        if index < 0:
            return None
        if ctrl:
            knob_index, direction = divmod(index, len(self.KNOB_DIRECTIONS))
            if knob_index >= self.knobs:
                return None
            if not pressed:
                return None
            return KnobEvent(index=knob_index, direction=self.KNOB_DIRECTIONS[direction])
        if self.cols <= 0 or index >= self.rows * self.cols:
            return None
        return KeyEvent(row=index // self.cols, col=index % self.cols, pressed=pressed)
