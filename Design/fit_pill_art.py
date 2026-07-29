#!/usr/bin/env python3
"""Scale tag pill art down to the height the pills are actually drawn at.

The pills are 9-slice frames, and FG draws a frame's border bands 1:1 in
bitmap pixels — it never scales them. So pill art has to be authored at the
final height (14px): a 32px-tall bitmap renders a 32px-tall pill, and there is
no offset combination that shrinks the rounded caps to fit a 14px row without
cutting the curve and smearing it through the stretched middle.

Authoring larger is still convenient, so this converts an export of any size
down to the drawn height, preserving aspect, and then solidifies it (a
downscale re-mixes colour with the transparent pixels, so that has to happen
after, not before).

    python3 Design/fit_pill_art.py            # the cc_tag_* pills
    python3 Design/fit_pill_art.py a.png b.png

Run it after re-exporting pill art. Already-correct files are left alone.
"""
import os
import sys

from PIL import Image

import solidify_alpha

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FILES = ["cc_tag_neutral.png", "cc_tag_positive.png", "cc_tag_negative.png"]

# Must match HEIGHT in the cc_chip template.
PILL_HEIGHT = 14


def fit(path):
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    if h == PILL_HEIGHT:
        return False
    nw = max(1, round(w * PILL_HEIGHT / h))
    img.resize((nw, PILL_HEIGHT), Image.LANCZOS).save(path)
    return True


def main(argv):
    paths = argv or [os.path.join(ROOT, "graphics/frames", f)
                     for f in DEFAULT_FILES]
    for path in paths:
        img = Image.open(path)
        before = img.size
        if fit(path):
            after = Image.open(path).size
            solidify_alpha.solidify(path)
            print(f"{os.path.basename(path):24s} {before} -> {after}")
        else:
            print(f"{os.path.basename(path):24s} {before} already at pill height")


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main(sys.argv[1:])
