#!/usr/bin/env python3
"""Bakes godot-src/cardback.png: the THALVORIX card back (navy/purple base,
gold filigree border, rune lattice, central sigil). Run once; output is committed.
    python3 godot-src/tools/make_cardback.py
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2                      # supersample
W, H = 352, 512            # final size (card aspect ~0.69)
w, h = W * S, H * S
GOLD = (232, 188, 92)
GOLD_D = (150, 108, 44)
PALE = (210, 190, 255)

img = Image.new("RGB", (w, h))
px = img.load()
cx, cy = w / 2, h / 2
for y in range(h):
    for x in range(w):
        dx, dy = (x - cx) / w, (y - cy) / h
        r = math.sqrt(dx * dx + dy * dy)
        t = max(0.0, 1.0 - r * 1.9)
        px[x, y] = (int(14 + 52 * t), int(10 + 18 * t), int(38 + 78 * t))

d = ImageDraw.Draw(img, "RGBA")

# diamond lattice + tiny dots
step = 44 * S
for k in range(-h // step - 2, w // step + h // step + 3):
    x0 = k * step
    d.line([(x0, 0), (x0 + h, h)], fill=(120, 90, 200, 38), width=S)
    d.line([(x0, 0), (x0 - h, h)], fill=(120, 90, 200, 38), width=S)
for j in range(0, h // (step // 2) + 2):
    for i in range(0, w // step + 2):
        x = i * step + (step // 2 if j % 2 else 0)
        y = j * step // 2
        d.ellipse([x - 2 * S, y - 2 * S, x + 2 * S, y + 2 * S], fill=(200, 170, 255, 70))

# concentric rings / rays around the sigil
for rr, a in [(150, 55), (128, 90), (104, 120)]:
    R = rr * S
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=GOLD + (a,), width=2 * S)
for i in range(24):
    ang = i * math.pi / 12
    r0, r1 = 108 * S, (146 if i % 2 == 0 else 128) * S
    d.line([(cx + r0 * math.cos(ang), cy + r0 * math.sin(ang)),
            (cx + r1 * math.cos(ang), cy + r1 * math.sin(ang))], fill=GOLD + (110,), width=S * 2)

# rune ticks on the ring
for i in range(12):
    ang = i * math.pi / 6 + math.pi / 12
    R = 139 * S
    x, y = cx + R * math.cos(ang), cy + R * math.sin(ang)
    s = 5 * S
    d.polygon([(x, y - s), (x + s, y), (x, y + s), (x - s, y)], fill=GOLD + (200,))

# 8-point star sigil
def star(points, r_out, r_in, rot, fill, outline=None):
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = rot + i * math.pi / points
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    d.polygon(pts, fill=fill, outline=outline)

glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
R = 92 * S
gd.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(170, 110, 255, 120))
glow = glow.filter(ImageFilter.GaussianBlur(30 * S))
img.paste(glow, (0, 0), glow)
d = ImageDraw.Draw(img, "RGBA")
star(8, 96 * S, 40 * S, -math.pi / 2, GOLD_D + (255,))
star(8, 88 * S, 36 * S, -math.pi / 2, GOLD + (255,))
star(4, 60 * S, 18 * S, -math.pi / 4, (60, 30, 110, 255))
R = 30 * S
d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(28, 14, 60), outline=GOLD, width=3 * S)
star(4, 22 * S, 7 * S, -math.pi / 2, PALE + (255,))

# title text
def text_c(txt, y, size, fill):
    try:
        f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf", size * S)
    except OSError:
        f = ImageFont.load_default()
    bb = d.textbbox((0, 0), txt, font=f)
    d.text((cx - (bb[2] - bb[0]) / 2, y), txt, font=f, fill=fill)
text_c("THALVORIX", cy + 162 * S, 26, GOLD)
text_c("\u2014  DUEL ARENA  \u2014", cy - 196 * S, 13, PALE + (200,))

# filigree border
m = 12 * S
d.rounded_rectangle([m, m, w - m, h - m], radius=18 * S, outline=GOLD, width=4 * S)
m2 = 22 * S
d.rounded_rectangle([m2, m2, w - m2, h - m2], radius=12 * S, outline=GOLD_D, width=2 * S)
# scallops along the inner border
for x in range(m2 + 14 * S, w - m2 - 10 * S, 22 * S):
    for y in (m2 + 6 * S, h - m2 - 6 * S):
        d.arc([x - 7 * S, y - 7 * S, x + 7 * S, y + 7 * S], 0, 360, fill=GOLD_D + (160,), width=S)
for y in range(m2 + 14 * S, h - m2 - 10 * S, 22 * S):
    for x in (m2 + 6 * S, w - m2 - 6 * S):
        d.arc([x - 7 * S, y - 7 * S, x + 7 * S, y + 7 * S], 0, 360, fill=GOLD_D + (160,), width=S)
# corner ornaments
c2 = m2 + 8 * S
for (x, y) in [(c2, c2), (w - c2, c2), (c2, h - c2), (w - c2, h - c2)]:
    for r, a in [(22, 255), (15, 200)]:
        R = r * S
        d.arc([x - R, y - R, x + R, y + R], 0, 360, fill=GOLD + (a,), width=2 * S)
    s = 12 * S
    d.polygon([(x, y - s), (x + s, y), (x, y + s), (x - s, y)], fill=GOLD)
    d.polygon([(x, y - s / 2), (x + s / 2, y), (x, y + s / 2), (x - s / 2, y)], fill=(40, 20, 80))
# side diamonds at edge midpoints
for (x, y) in [(cx, m), (cx, h - m), (m, cy), (w - m, cy)]:
    s = 10 * S
    d.polygon([(x, y - s), (x + s, y), (x, y + s), (x - s, y)], fill=GOLD, outline=GOLD_D)

out = img.resize((W, H), Image.LANCZOS)
p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cardback.png")
out = out.quantize(colors=192, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
out.save(p, optimize=True)
print("wrote", os.path.normpath(p), os.path.getsize(p), "bytes")
