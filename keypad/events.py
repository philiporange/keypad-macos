"""HID input report decoder module converting raw bytes to structured key and knob events.

This module provides data structures for key presses/releases and knob movements, as well as a
ReportDecoder class configured with keypad dimensions. Decodes standard raw HID byte reports or
delegates to a user-supplied custom decoding function.
"""

from dataclasses import dataclass
from typing import Callable, Optional, Union


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
