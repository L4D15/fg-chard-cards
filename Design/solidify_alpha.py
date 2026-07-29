#!/usr/bin/env python3
"""Remove the dark fringe around transparent edges in the extension's art.

Image editors leave fully transparent pixels as black. FG filters textures
when it draws them, so a soft edge pixel gets averaged with its transparent
neighbours' *colour* as well as their alpha — pulling the edge toward black
and ringing light-coloured art (the tag pills especially) with a dark halo.

The fix is to bleed the nearest visible colour outwards into the transparent
pixels while leaving every alpha value untouched: nothing about the image's
appearance changes, but there is no longer any black to average in.

Run after re-exporting art from an image editor:

    python3 Design/solidify_alpha.py                 # all frames and icons
    python3 Design/solidify_alpha.py path/to/art.png # specific files

Idempotent — running it again on fixed art does nothing.
"""
import glob
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GLOBS = ["graphics/frames/*.png", "graphics/icons/*.png"]


def solidify(path):
    """Bleed visible colour into transparent pixels. Returns True if changed."""
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    px = img.load()

    rgb = [[list(px[x, y][:3]) for x in range(w)] for y in range(h)]
    known = [[px[x, y][3] > 0 for x in range(w)] for y in range(h)]
    todo = [(x, y) for y in range(h) for x in range(w) if not known[y][x]]
    if not todo or all(not known[y][x] for y in range(h) for x in range(w)):
        # Nothing to do, or nothing visible to bleed from (a blank layer).
        return False

    changed = False
    while todo:
        # One ring per pass: average the neighbours that already have colour.
        filled = []
        for x, y in todo:
            acc, n = [0, 0, 0], 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and known[ny][nx]:
                        c = rgb[ny][nx]
                        acc[0] += c[0]
                        acc[1] += c[1]
                        acc[2] += c[2]
                        n += 1
            if n:
                filled.append((x, y, [acc[0] // n, acc[1] // n, acc[2] // n]))
        if not filled:
            break
        for x, y, c in filled:
            if rgb[y][x] != c:
                changed = True
            rgb[y][x] = c
            known[y][x] = True
        todo = [(x, y) for x, y in todo if not known[y][x]]

    if changed:
        for y in range(h):
            for x in range(w):
                px[x, y] = tuple(rgb[y][x]) + (px[x, y][3],)
        img.save(path)
    return changed


def main(argv):
    if argv:
        paths = argv
    else:
        paths = []
        for pattern in DEFAULT_GLOBS:
            paths.extend(sorted(glob.glob(os.path.join(ROOT, pattern))))

    for path in paths:
        name = os.path.basename(path)
        print(f"{name:32s} {'fixed' if solidify(path) else 'already clean'}")


if __name__ == "__main__":
    main(sys.argv[1:])
