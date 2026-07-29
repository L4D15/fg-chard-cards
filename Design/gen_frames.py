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
CARD_FILL = (240, 232, 211, 255)  # #F0E8D3, the card art's fill
CREAM = (255, 252, 242, 255)      # inner text panels
RED = (178, 46, 46, 255)          # attack chip
WHITE = (255, 255, 255, 255)
MUTED = (121, 117, 108, 255)      # #79756C: roll-type label + die glyphs


def rounded(size, radius, fill, outline=None, width=1, bottom_gap=0, inset=0):
    # Draw at 4x and downscale for smooth corners. bottom_gap adds fully
    # transparent rows below the shape: FG windowclass frames stretch over
    # the whole list-window rect INCLUDING the bottom margin, so inter-card
    # spacing must be baked into the frame art (keep the gap inside the
    # bottom 9-slice band via the framedef offset).
    s = 4
    img = Image.new("RGBA", (size[0] * s, (size[1] + bottom_gap) * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [inset * s, inset * s, (size[0] - inset) * s - 1, (size[1] - inset) * s - 1],
        radius=radius * s, fill=fill,
        outline=outline, width=width * s,
    )
    return img.resize((size[0], size[1] + bottom_gap), Image.LANCZOS)


def save(img, name):
    img.save(f"{OUT}/{name}.png")
    print(name)


# cc_card.png: USER-SUPPLIED ART (2026-07-28) — do not regenerate.
# 48x56 with the 8px transparent bottom gutter (framedef offset 12,12,12,20).

# cc_header.png: USER-SUPPLIED ART (2026-07-28) — do not regenerate.

# Inner cream text panel
save(rounded((48, 48), 5, CREAM, (222, 210, 178, 255), 1), "cc_panel")

# Result box: white with gold border
save(rounded((48, 48), 5, WHITE, GOLD_DARK, 2), "cc_resultbox")

# Result box header strip (gold)
save(rounded((48, 20), 4, GOLD), "cc_resultheader")

# cc_chip_red.png / cc_chip_gold.png: USER-SUPPLIED ART (2026-07-29) —
# do not regenerate. 36x14 pills (framedef offset 7,6,7,6).

# Banner (turn / damage-applied messages): matches the card art's geometry
# so the two never disagree at their edges — same 5px transparent inset on
# every side (which also provides the separation between rows, so the class
# needs no margin) and the same ~4px corner radius, no outline.
# framedef offset 12,12,12,12 (>= inset 5 + radius 4).
save(rounded((48, 48), 4, GOLD, inset=5), "cc_banner")

# cc_portraitframe.png: USER-SUPPLIED ART (2026-07-28) — do not regenerate.
# 2px border, square interior; avatar layers are 40x40 at +2,+2 inside the
# 44x44 frame control.


# ===== Portrait icons =====
# Authored at 3x the 40px avatar area for the same reason as the die
# glyphs: setCardPortrait draws them via a bitmap widget with an explicit
# 40px size, so a detailed source is downsampled once at render time.
PORTRAIT_DISPLAY = 40
PORTRAIT_SUPERSAMPLE = 3
PORTRAIT_SRC = PORTRAIT_DISPLAY * PORTRAIT_SUPERSAMPLE
# Corner rounding of the avatar, in display pixels
PORTRAIT_RADIUS = 4
PORTRAIT_RADIUS_SRC = PORTRAIT_RADIUS * PORTRAIT_SUPERSAMPLE


def text_icon(name, text, bg, fg, size=PORTRAIT_SRC, textsize=18):
    # Badge filling the frame's interior, corners rounded to match the mask
    s = 4
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1],
                        radius=PORTRAIT_RADIUS_SRC * s * (size / PORTRAIT_SRC),
                        fill=bg)
    font = ImageFont.truetype(FONT, textsize * s)
    d.text((size * s / 2, size * s / 2 - 1 * s), text,
           font=font, fill=fg, anchor="mm")
    img = img.resize((size, size), Image.LANCZOS)
    img.save(f"{ICONS}/{name}.png")
    print(name)


# GM speaker icon: gold badge with dark "GM"
text_icon("cc_portrait_gm", "GM", GOLD, (59, 42, 18, 255),
          textsize=17 * PORTRAIT_SUPERSAMPLE)

# Unknown speaker fallback: parchment badge with a gold "?"
text_icon("cc_portrait_unknown", "?", PARCHMENT, GOLD_DARK,
          textsize=24 * PORTRAIT_SUPERSAMPLE)

# ===== Die result glyphs (mimic native chat's black die silhouettes;
# the rolled number is overlaid as a white text widget) =====
#
# Authored at 3x the 22px display size: the card renders them through
# addBitmapWidget with an explicit w/h, so FG downsamples a detailed
# source instead of stretching a 22px one. Keeps the same on-screen size
# while staying sharp under UI scaling / high-DPI displays. Do NOT bake
# the downscale in here — a single scale at render time is crisper than
# downscale-then-upscale.
DIE_DISPLAY = 22
DIE_SUPERSAMPLE = 3


def die_glyph(name, shape, size=DIE_DISPLAY * DIE_SUPERSAMPLE):
    import math
    s = 4
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    dark = MUTED

    def ngon(n, rot_deg, radius=W / 2 - 1, cy=W / 2):
        pts = []
        for i in range(n):
            a = math.radians(rot_deg + i * (360.0 / n))
            pts.append((W / 2 + radius * math.cos(a), cy + radius * math.sin(a)))
        return pts

    k = size / DIE_DISPLAY      # keep proportions at any supersample
    if shape == "square":       # d6
        inset = k * s
        d.rounded_rectangle([inset, inset, W - inset - 1, W - inset - 1],
                            radius=4 * k * s, fill=dark)
    elif shape == "triangle":   # d4
        d.polygon([(W / 2, 0), (W - 1, W * 0.9), (0, W * 0.9)], fill=dark)
    elif shape == "diamond":    # d8
        d.polygon([(W / 2, 0), (W - 1, W / 2), (W / 2, W - 1), (0, W / 2)], fill=dark)
    elif shape == "kite":       # d10 / d100
        d.polygon([(W / 2, 0), (W * 0.96, W * 0.42), (W / 2, W - 1), (W * 0.04, W * 0.42)], fill=dark)
    elif shape == "pentagon":   # d12
        d.polygon(ngon(5, -90), fill=dark)
    elif shape == "hexagon":    # d20
        d.polygon(ngon(6, -90), fill=dark)

    img = img.resize((size, size), Image.LANCZOS)
    img.save(f"{ICONS}/{name}.png")
    print(name)


die_glyph("cc_die_d4", "triangle")
die_glyph("cc_die_d6", "square")
die_glyph("cc_die_d8", "diamond")
die_glyph("cc_die_d10", "kite")
die_glyph("cc_die_d12", "pentagon")
die_glyph("cc_die_d20", "hexagon")


# Portrait-set layers for engine-generated PC portrait icons
# (portrait_<identity>_ccard): fully transparent base (no ring/decoration)
# and a plain opaque square mask, authored at the supersampled size so the
# engine composites each identity's portrait at 3x — the card renders it
# down into the 40px avatar area, preserving detail from the original
# portrait image instead of baking a 40px thumbnail.
base = Image.new("RGBA", (PORTRAIT_SRC, PORTRAIT_SRC), (0, 0, 0, 0))
base.save(f"{ICONS}/cc_portrait_base.png")
print("cc_portrait_base")

mask = rounded((PORTRAIT_SRC, PORTRAIT_SRC), PORTRAIT_RADIUS_SRC,
               (255, 255, 255, 255))
mask.save(f"{ICONS}/cc_portrait_mask.png")
print("cc_portrait_mask")

# Corner cover drawn on TOP of the avatar layers: FG cannot mask a token
# control, so the rounding for NPC token art comes from covering the square
# corners. Opaque outside a rounded window, in the card art's fill colour so
# the covered corners blend into the card (the avatar has no border now).
# Re-sample CARD_FILL if the card background art changes.
cover = Image.new("RGBA", (PORTRAIT_SRC * 4, PORTRAIT_SRC * 4), CARD_FILL)
ImageDraw.Draw(cover).rounded_rectangle(
    [0, 0, PORTRAIT_SRC * 4 - 1, PORTRAIT_SRC * 4 - 1],
    radius=PORTRAIT_RADIUS_SRC * 4, fill=(0, 0, 0, 0))
cover.resize((PORTRAIT_SRC, PORTRAIT_SRC), Image.LANCZOS).save(
    f"{ICONS}/cc_portrait_cover.png")
print("cc_portrait_cover")
