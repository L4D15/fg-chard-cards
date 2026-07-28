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


def rounded(size, radius, fill, outline=None, width=1):
    # Draw at 4x and downscale for smooth corners
    s = 4
    img = Image.new("RGBA", (size[0] * s, size[1] * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [0, 0, size[0] * s - 1, size[1] * s - 1],
        radius=radius * s, fill=fill,
        outline=outline, width=width * s,
    )
    return img.resize(size, Image.LANCZOS)


def save(img, name):
    img.save(f"{OUT}/{name}.png")
    print(name)


# Card body: parchment with gold border, 48x48, corner 10 -> 9-slice offset 12
save(rounded((48, 48), 8, PARCHMENT, GOLD_DARK, 2), "cc_card")

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

# Banner: full-width gold rounded bar (turn / damage-applied messages)
save(rounded((48, 32), 10, GOLD, GOLD_DARK, 1), "cc_banner")

# Portrait frame: gold square
save(rounded((48, 48), 6, (0, 0, 0, 0), GOLD_DARK, 3), "cc_portraitframe")


# ===== Portrait icons (fixed-size, drawn inside the 44px portrait box) =====

def text_icon(name, text, bg, fg, size=36, textsize=18):
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
text_icon("cc_portrait_gm", "GM", GOLD, (59, 42, 18, 255), textsize=15)

# Unknown speaker fallback: parchment badge with a gold "?"
text_icon("cc_portrait_unknown", "?", PARCHMENT, GOLD_DARK, textsize=22)
