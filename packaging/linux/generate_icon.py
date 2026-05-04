#!/usr/bin/env python3
"""Generate the placeholder Deckhand launcher icon.

Produces a 256x256 PNG that renders as a stylised Klipper-print bed
silhouette (a shaded rectangle with a stylised nozzle above it). It's
recognisable without being a real branding asset - replace this file
with the actual designed icon when it lands and re-run the script (or
just drop a 256x256 PNG at packaging/linux/deckhand.png directly,
which the AppImage builder picks up unconditionally).

Run: python3 packaging/linux/generate_icon.py
"""
from PIL import Image, ImageDraw

SIZE = 256
OUT = "packaging/linux/deckhand.png"

# Palette: deep navy bg, warm filament-orange accent, off-white plate.
BG = (15, 23, 42)        # slate-900
PLATE = (226, 232, 240)  # slate-200
NOZZLE = (251, 146, 60)  # orange-400
SHADOW = (8, 13, 27)     # slightly darker than bg


def main() -> None:
    img = Image.new("RGB", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(img)

    # Subtle vignette: soft inner shadow on top edges.
    for y in range(0, 24):
        alpha = 1 - y / 24
        c = tuple(int(BG[i] * (1 - 0.4 * alpha) + SHADOW[i] * 0.4 * alpha)
                  for i in range(3))
        d.line([(0, y), (SIZE, y)], fill=c)

    # Build plate: rounded rectangle near the bottom.
    plate_top = 168
    plate_h = 42
    d.rounded_rectangle(
        [(28, plate_top), (SIZE - 28, plate_top + plate_h)],
        radius=8, fill=PLATE, outline=(148, 163, 184), width=2,
    )
    # Plate shadow line below.
    d.rounded_rectangle(
        [(36, plate_top + plate_h + 2), (SIZE - 36, plate_top + plate_h + 8)],
        radius=4, fill=SHADOW,
    )

    # Print volume: a translucent rising stack of filament rings.
    cx = SIZE // 2
    for i, y in enumerate(range(plate_top - 6, plate_top - 80, -8)):
        w = 70 - i * 4
        d.ellipse(
            [(cx - w, y - 6), (cx + w, y + 6)],
            outline=NOZZLE, width=2,
        )

    # Nozzle/extruder: a downward-pointing trapezoid above the print.
    nozzle_top = 36
    nozzle_bot = 86
    d.polygon(
        [
            (cx - 36, nozzle_top),
            (cx + 36, nozzle_top),
            (cx + 22, nozzle_bot),
            (cx - 22, nozzle_bot),
        ],
        fill=(71, 85, 105), outline=(148, 163, 184),
    )
    # Nozzle tip
    d.polygon(
        [(cx - 10, nozzle_bot), (cx + 10, nozzle_bot), (cx, nozzle_bot + 14)],
        fill=NOZZLE,
    )

    img.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
