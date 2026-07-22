"""Regenerate assets/statusbar.png: a monochrome 3x3 grid of rounded squares.

A macOS template image — pure black with alpha — drawn at 44x44 (22pt @2x),
so the menu bar recolors it automatically for light/dark appearance.
Needs Pillow (a dev-only tool dependency, not a runtime one):
    .venv/bin/pip install pillow && .venv/bin/python scripts/make_statusbar_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 44          # 22pt @2x
SQUARE = 10
GAP = 4
MARGIN = (SIZE - 3 * SQUARE - 2 * GAP) // 2  # 3
RADIUS = 2

image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
for row in range(3):
    for col in range(3):
        x = MARGIN + col * (SQUARE + GAP)
        y = MARGIN + row * (SQUARE + GAP)
        draw.rounded_rectangle(
            (x, y, x + SQUARE - 1, y + SQUARE - 1),
            radius=RADIUS,
            fill=(0, 0, 0, 255),
        )

out = Path(__file__).resolve().parent.parent / "assets" / "statusbar.png"
image.save(out)
print(f"wrote {out}")
