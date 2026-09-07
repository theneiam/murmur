"""Render the Murmur app icon: a macOS-style rounded square with a soft
indigo→violet gradient, faint concentric "murmur" ripples, and a five-bar
sound wave that echoes the recording indicator. Supersampled, then exported
at every size the AppIcon set needs."""
import json
import math
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.environ.get("OUT", "icon_out")
os.makedirs(OUT, exist_ok=True)

S = 4096                 # supersample canvas
# Apple's macOS icon grid: 1024 canvas, 824 rounded square centred (100 margin).
MARGIN = int(S * 100 / 1024)
INNER = S - 2 * MARGIN


def squircle_mask(size, inner, margin, n=4.6):
    """Superellipse mask approximating Apple's continuous-corner rounded square."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    cx = cy = size / 2
    a = inner / 2
    v = (np.abs((x - cx) / a) ** n + np.abs((y - cy) / a) ** n)
    # soft edge for anti-aliasing
    edge = 1.0 - np.clip((v - 1.0) * (a / 3.0), 0, 1)
    return Image.fromarray((edge * 255).astype(np.uint8), "L")


def gradient(size, top, bottom, angle_deg=28):
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) / size
    ang = math.radians(angle_deg)
    t = (x * math.sin(ang) + y * math.cos(ang))
    t = (t - t.min()) / (t.max() - t.min())
    t = t[..., None]
    c = np.array(top)[None, None, :] * (1 - t) + np.array(bottom)[None, None, :] * t
    return Image.fromarray(c.astype(np.uint8), "RGB")


# --- background ---------------------------------------------------------
bg = gradient(S, (86, 111, 255), (122, 63, 224))          # indigo → violet
# subtle radial glow top-left so the square doesn't look flat
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([-S * 0.25, -S * 0.35, S * 0.85, S * 0.75], fill=255)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.18))
glow_layer = Image.new("RGB", (S, S), (255, 255, 255))
bg = Image.composite(glow_layer, bg, glow.point(lambda p: int(p * 0.16)))

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
icon.paste(bg, (0, 0), squircle_mask(S, INNER, MARGIN))

# --- ripples ------------------------------------------------------------
ripple = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(ripple)
cx, cy = S / 2, S / 2
for i, r in enumerate([0.30, 0.42, 0.54]):
    rr = INNER * r
    alpha = int(255 * (0.13 - i * 0.035))
    rd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
               outline=(255, 255, 255, alpha), width=int(S * 0.012))
ripple = ripple.filter(ImageFilter.GaussianBlur(S * 0.002))
icon = Image.alpha_composite(icon, Image.composite(
    ripple, Image.new("RGBA", (S, S), (0, 0, 0, 0)), squircle_mask(S, INNER, MARGIN)))

# --- sound-wave bars ----------------------------------------------------
heights = [0.22, 0.40, 0.58, 0.40, 0.22]      # fraction of INNER
bar_w = INNER * 0.085
gap = INNER * 0.055
total_w = len(heights) * bar_w + (len(heights) - 1) * gap
x0 = cx - total_w / 2

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
bars = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bars)
for i, h in enumerate(heights):
    bh = INNER * h
    x = x0 + i * (bar_w + gap)
    box = [x, cy - bh / 2, x + bar_w, cy + bh / 2]
    sd.rounded_rectangle([b + (0 if j % 2 == 0 else S * 0.012) for j, b in enumerate(box)],
                         radius=bar_w / 2, fill=(20, 10, 60, 110))
    bd.rounded_rectangle(box, radius=bar_w / 2, fill=(255, 255, 255, 255))
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.012))
icon = Image.alpha_composite(icon, shadow)
icon = Image.alpha_composite(icon, bars)

# --- export -------------------------------------------------------------
master = icon.resize((1024, 1024), Image.LANCZOS)
master.save(os.path.join(OUT, "icon_1024.png"))

sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes:
    master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, f"icon_{px}.png"))

entries = []
for pt in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        entries.append({"filename": f"icon_{pt * scale}.png", "idiom": "mac",
                        "scale": f"{scale}x", "size": f"{pt}x{pt}"})
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"images": entries, "info": {"author": "xcode", "version": 1}}, f, indent=2)

# preview sheet: 512 + 128 + 32 + 16 side by side on light and dark
sheet = Image.new("RGBA", (1000, 620), (0, 0, 0, 0))
for row, bgc in enumerate([(245, 245, 247, 255), (30, 30, 32, 255)]):
    band = Image.new("RGBA", (1000, 310), bgc)
    sheet.paste(band, (0, row * 310))
    x = 40
    for px in [256, 128, 64, 32, 16]:
        im = master.resize((px, px), Image.LANCZOS)
        sheet.alpha_composite(im, (x, row * 310 + (310 - px) // 2))
        x += px + 60
sheet.save(os.path.join(OUT, "preview.png"))
print("done", sizes)
