"""Render the Deckhand tick-mark logo at every Windows icon size and pack
into app_icon.ico.

Source-space coordinates mirror DeckhandLogo's _TickLogoPainter in
packages/deckhand_ui/lib/src/widgets/deckhand_logo.dart so the window
icon and the in-app brand mark stay visually identical. Color is the
locked-in UV violet accent from DeckhandTokens (light-mode value, since
Windows title-bar usually shows a darker/saturated icon over neutral
chrome regardless of the user's dark/light preference).

Re-run when the logo geometry or accent value changes:
    python windows/runner/resources/generate_app_icon.py
"""
from __future__ import annotations

import io
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw

# OKLCH(0.55, 0.20, 285) — same math as deckhand_tokens.dart's `oklch()`
# helper. Recompute here so we don't drift; the tick-mark color must
# match the in-app accent.
def oklch_to_srgb(L: float, C: float, h_deg: float) -> tuple[int, int, int]:
    h = math.radians(h_deg)
    a = C * math.cos(h)
    b = C * math.sin(h)
    lp = L + 0.3963377774 * a + 0.2158037573 * b
    mp = L - 0.1055613458 * a - 0.0638541728 * b
    sp = L - 0.0894841775 * a - 1.2914855480 * b
    lc, mc, sc = lp ** 3, mp ** 3, sp ** 3
    r =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
    g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
    bb = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

    def to_srgb(c: float) -> int:
        if c <= 0.0031308:
            v = 12.92 * c
        else:
            v = 1.055 * (c ** (1 / 2.4)) - 0.055
        return max(0, min(255, round(v * 255)))

    return to_srgb(r), to_srgb(g), to_srgb(bb)

ACCENT = oklch_to_srgb(0.55, 0.20, 285)

# Source-space tick lines — copied verbatim from deckhand_logo.dart.
TICKS = [
    (6,  9, 14), (11, 11, 14), (16,  7, 14), (21, 11, 14), (26,  9, 14),
    (6, 18, 23), (11, 18, 21), (16, 18, 25), (21, 18, 21), (26, 18, 23),
]

# Bar geometry (x, y, w, h) in source space.
BAR = (3, 14, 26, 4)

# Source viewBox.
VB = 32

# Windows icon sizes. Includes 256x256 PNG for "Vista+" entries plus the
# legacy bitmap sizes. Pillow's save_all=True with format='ICO' handles
# the multi-image bundling.
SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def render(size: int) -> Image.Image:
    """Render the tick mark at `size` px square. Returns a transparent
    RGBA image so the icon composites cleanly over any title-bar color."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    scale = size / VB

    # Bar — 40% opacity behind the ticks.
    bx, by, bw, bh = BAR
    d.rectangle(
        (bx * scale, by * scale, (bx + bw) * scale, (by + bh) * scale),
        fill=(*ACCENT, int(0.4 * 255)),
    )

    # Stroke width scales with size; floor at 1px so the small icons
    # don't disappear.
    stroke = max(1, round(2 * scale))

    for x, y1, y2 in TICKS:
        x_px = x * scale
        d.line(
            (x_px, y1 * scale, x_px, y2 * scale),
            fill=(*ACCENT, 255),
            width=stroke,
        )

    return img


def main() -> None:
    out_path = Path(__file__).with_name("app_icon.ico")
    images = [render(s[0]) for s in SIZES]
    # Save as ICO with all sizes embedded. Pillow's IcoImagePlugin
    # uses the `sizes` kwarg as a filter — only sizes >= the source
    # image's pixel dimensions get included, and entries get
    # downscaled, not picked from `append_images`. Workaround: hand-
    # encode the ICO so each rendered size lands in its own entry at
    # full quality.
    _write_ico(out_path, images)
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes, "
          f"{len(images)} entries)")


def _write_ico(path: Path, images: list[Image.Image]) -> None:
    """Hand-pack a multi-image ICO. Each image is encoded as PNG (the
    "Vista+" ICO format) regardless of size — modern Windows accepts
    PNG entries at every size and there's no benefit to BMP entries
    today.

    File layout:
      ICONDIR (6 bytes)
      ICONDIRENTRY × N (16 bytes each)
      [PNG payload × N]
    """
    entries: list[bytes] = []
    payloads: list[bytes] = []
    payload_offset = 6 + 16 * len(images)
    for img in images:
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        data = buf.getvalue()
        w, h = img.size
        # ICONDIRENTRY:
        #   width (1)        — 0 means 256
        #   height (1)       — 0 means 256
        #   color_count (1)  — 0 for >= 8bpp
        #   reserved (1)     — 0
        #   planes (2)       — 1 for ICO
        #   bit_count (2)    — 32 (RGBA)
        #   size (4)         — bytes of PNG payload
        #   offset (4)       — byte offset into the file
        entry = struct.pack(
            "<BBBBHHII",
            w if w < 256 else 0,
            h if h < 256 else 0,
            0,
            0,
            1,
            32,
            len(data),
            payload_offset,
        )
        entries.append(entry)
        payloads.append(data)
        payload_offset += len(data)

    with open(path, "wb") as f:
        # ICONDIR:
        #   reserved (2) = 0
        #   type (2) = 1 (icon, not cursor)
        #   count (2)
        f.write(struct.pack("<HHH", 0, 1, len(images)))
        for e in entries:
            f.write(e)
        for p in payloads:
            f.write(p)


if __name__ == "__main__":
    main()
