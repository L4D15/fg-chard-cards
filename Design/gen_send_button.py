#!/usr/bin/env python3
"""Generate the "send to chat" sheet button (speech bubble on a rounded
tile, Daggerheart-button style: their action buttons are 40x40 rounded
squares). Rendered at 2x (80px) so FG downsamples a detailed source.

Usage: any python with Pillow.  Writes graphics/buttons/cc_send_chat.png
and its pressed (darker) variant next to this repo's other art.
"""
import os

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "graphics", "buttons")

S = 2  # supersample factor over the 40px native size
SIZE = 40 * S

# Bronze tile, in the neighbourhood of the ruleset's utility buttons and
# this extension's gold detailing.
TILE_TOP = (176, 128, 48, 255)
TILE_BOTTOM = (122, 85, 24, 255)
TILE_BORDER = (92, 62, 15, 255)
WHITE = (255, 255, 255, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def make_tile(shade=1.0):
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = 8 * S

    # Vertical gradient inside a rounded-rect mask, then the border on top.
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, SIZE - 1, SIZE - 1], radius=radius, fill=255)
    grad = Image.new("RGBA", (SIZE, SIZE))
    for y in range(SIZE):
        c = lerp(TILE_TOP, TILE_BOTTOM, y / (SIZE - 1))
        c = tuple(int(v * shade) for v in c[:3]) + (255,)
        ImageDraw.Draw(grad).line([(0, y), (SIZE, y)], fill=c)
    img.paste(grad, (0, 0), mask)
    border = tuple(int(v * shade) for v in TILE_BORDER[:3]) + (255,)
    d.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=radius,
                        outline=border, width=2 * S)

    # Speech bubble: rounded body, a tail toward bottom-left, three dots.
    bx0, by0, bx1, by1 = 8 * S, 9 * S, 32 * S, 26 * S
    d.rounded_rectangle([bx0, by0, bx1, by1], radius=5 * S, fill=WHITE)
    d.polygon([(13 * S, 25 * S), (21 * S, 25 * S), (14 * S, 32 * S)],
              fill=WHITE)
    cy = (by0 + by1) // 2
    dot_fill = tuple(int(v * shade) for v in TILE_BOTTOM[:3]) + (255,)
    for cx in (14 * S, 20 * S, 26 * S):
        r = int(1.8 * S)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=dot_fill)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    make_tile(1.0).save(os.path.join(OUT, "cc_send_chat.png"))
    make_tile(0.72).save(os.path.join(OUT, "cc_send_chat_down.png"))
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
