#!/usr/bin/env python3
"""Generate placeholder 9-slice frame PNGs for the ChatCards extension."""
from PIL import Image, ImageDraw, ImageFont

OUT = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/frames"
ICONS = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/icons"
FONT = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/fonts/NotoSans-Bold.ttf"

GOLD = (185, 156, 91, 255)        # header bars / borders
GOLD_DARK = (150, 122, 60, 255)   # border lines
PARCHMENT = (250, 244, 226, 255)  # card body
CREAM = (255, 252, 242, 255)      # inner text panels
RED = (178, 46, 46, 255)          # attack chip
WHITE = (255, 255, 255, 255)


def rounded(size, radius, fill, outline=None, width=1, bottom_gap=0):
    # Draw at 4x and downscale for smooth corners. bottom_gap adds fully
    # transparent rows below the shape: FG windowclass frames stretch over
    # the whole list-window rect INCLUDING the bottom margin, so inter-card
    # spacing must be baked into the frame art (keep the gap inside the
    # bottom 9-slice band via the framedef offset).
    s = 4
    img = Image.new("RGBA", (size[0] * s, (size[1] + bottom_gap) * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [0, 0, size[0] * s - 1, size[1] * s - 1],
        radius=radius * s, fill=fill,
        outline=outline, width=width * s,
    )
    return img.resize((size[0], size[1] + bottom_gap), Image.LANCZOS)


def save(img, name):
    img.save(f"{OUT}/{name}.png")
    print(name)


# Card body: parchment with gold border + 8px transparent gutter below
# (framedef offset 12,12,12,20)
save(rounded((48, 48), 8, PARCHMENT, GOLD_DARK, 2, bottom_gap=8), "cc_card")

# Header bar: solid gold, slightly rounded top corners handled by card behind it
save(rounded((48, 24), 5, GOLD), "cc_header")

# Inner cream text panel
save(rounded((48, 48), 5, CREAM, (222, 210, 178, 255), 1), "cc_panel")

# Result box: white with gold border
save(rounded((48, 48), 5, WHITE, GOLD_DARK, 2), "cc_resultbox")

# Result box header strip (gold)
save(rounded((48, 20), 4, GOLD), "cc_resultheader")

# Chips
save(rounded((36, 20), 9, RED), "cc_chip_red")
save(rounded((36, 20), 9, GOLD), "cc_chip_gold")

# Banner: full-width gold rounded bar (turn / damage-applied messages),
# 8px transparent gutter below (framedef offset 12,10,12,18)
save(rounded((48, 32), 10, GOLD, GOLD_DARK, 1, bottom_gap=8), "cc_banner")

# Portrait frame: gold square
save(rounded((48, 48), 6, (0, 0, 0, 0), GOLD_DARK, 3), "cc_portraitframe")


# ===== Portrait icons (fill the whole 44px portrait box; the border-only
# cc_portraitframe graphic is layered on top of them) =====

def text_icon(name, text, bg, fg, size=44, textsize=18):
    s = 4
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1],
                        radius=5 * s, fill=bg)
    font = ImageFont.truetype(FONT, textsize * s)
    d.text((size * s / 2, size * s / 2 - 1 * s), text,
           font=font, fill=fg, anchor="mm")
    img = img.resize((size, size), Image.LANCZOS)
    img.save(f"{ICONS}/{name}.png")
    print(name)


# GM speaker icon: gold badge with dark "GM"
text_icon("cc_portrait_gm", "GM", GOLD, (59, 42, 18, 255), textsize=19)

# Unknown speaker fallback: parchment badge with a gold "?"
text_icon("cc_portrait_unknown", "?", PARCHMENT, GOLD_DARK, textsize=27)

# Portrait-set layers for engine-generated PC portrait icons
# (portrait_<identity>_ccard): fully transparent base (no ring/decoration)
# and a full-size opaque rounded mask so the portrait fills the box and is
# clipped to match the border frame's corners.
base = Image.new("RGBA", (44, 44), (0, 0, 0, 0))
base.save(f"{ICONS}/cc_portrait_base.png")
print("cc_portrait_base")

mask = rounded((44, 44), 6, (255, 255, 255, 255))
mask.save(f"{ICONS}/cc_portrait_mask.png")
print("cc_portrait_mask")
