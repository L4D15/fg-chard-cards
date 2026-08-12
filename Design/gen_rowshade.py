#!/usr/bin/env python3
"""Generate the sheet-row stripe frame: a flat black at 10% opacity,
overlaid on every other list row (see common/sheet_chatcards_dh.xml).
A plain fill needs no border bands, so any small size works.

Usage: any python with Pillow.
"""
import os

from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "graphics", "frames")


def main():
    os.makedirs(OUT, exist_ok=True)
    Image.new("RGBA", (8, 8), (0, 0, 0, 26)).save(
        os.path.join(OUT, "cc_rowshade.png"))
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
