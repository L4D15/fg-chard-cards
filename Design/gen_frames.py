#!/usr/bin/env python3
"""Generate placeholder 9-slice frame PNGs for the ChatCards extension."""
from PIL import Image, ImageDraw, ImageFont

OUT = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/frames"
ICONS = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/icons"
FONT = "/home/ladis/.smiteworks/fgdata/extensions/ChatCards/graphics/fonts/NotoSans-Bold.ttf"

# Unified gold #B49D5D (from the reference mockup): header bars, card
# borders, and the avatar border all share this color.
GOLD = (180, 157, 93, 255)
GOLD_DARK = (180, 157, 93, 255)
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

# cc_header.png: USER-SUPPLIED ART (2026-07-28) — do not regenerate.

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

# cc_portraitframe.png: USER-SUPPLIED ART (2026-07-28) — do not regenerate.
# 2px border, square interior; avatar layers are 40x40 at +2,+2 inside the
# 44x44 frame control.


# ===== Portrait icons (sized to the border's 40px inner area) =====

def text_icon(name, text, bg, fg, size=40, textsize=18):
    # Square badge filling the frame's square interior
    s = 4
    img = Image.new("RGBA", (size * s, size * s), bg)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, textsize * s)
    d.text((size * s / 2, size * s / 2 - 1 * s), text,
           font=font, fill=fg, anchor="mm")
    img = img.resize((size, size), Image.LANCZOS)
    img.save(f"{ICONS}/{name}.png")
    print(name)


# GM speaker icon: gold badge with dark "GM"
text_icon("cc_portrait_gm", "GM", GOLD, (59, 42, 18, 255), textsize=17)

# Unknown speaker fallback: parchment badge with a gold "?"
text_icon("cc_portrait_unknown", "?", PARCHMENT, GOLD_DARK, textsize=24)

# Portrait-set layers for engine-generated PC portrait icons
# (portrait_<identity>_ccard): fully transparent base (no ring/decoration)
# and a plain opaque square mask, both at the 40px inner-area size so the
# portrait fills the frame's square interior exactly.
base = Image.new("RGBA", (40, 40), (0, 0, 0, 0))
base.save(f"{ICONS}/cc_portrait_base.png")
print("cc_portrait_base")

mask = Image.new("RGBA", (40, 40), (255, 255, 255, 255))
mask.save(f"{ICONS}/cc_portrait_mask.png")
print("cc_portrait_mask")
