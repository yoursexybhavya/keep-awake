#!/usr/bin/env python3
"""Generate KeepAwake.app icon: rounded-square tile with a coffee cup. Pure PIL."""
import os, subprocess, sys
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else "icon"
BASE = 1024
img = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- rounded square background, warm gradient-ish ---
m = 90
top, bot = (58, 132, 214), (30, 78, 148)          # blue tile
grad = Image.new("RGBA", (BASE, BASE))
gd = ImageDraw.Draw(grad)
for y in range(BASE):
    t = y / BASE
    gd.line([(0, y), (BASE, y)],
            fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
mask = Image.new("L", (BASE, BASE), 0)
ImageDraw.Draw(mask).rounded_rectangle([m, m, BASE - m, BASE - m], radius=230, fill=255)
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)

# --- subtle inner highlight ---
d.rounded_rectangle([m + 26, m + 26, BASE - m - 26, BASE - m - 26], radius=206,
                    outline=(255, 255, 255, 70), width=10)

# --- coffee cup ---
cx, cy = BASE // 2, BASE // 2 + 60
cw, ch = 330, 250            # cup body width/height
white = (255, 255, 255, 255)

# cup body (tapered): trapezoid with rounded bottom
body = [(cx - cw // 2, cy - ch // 2), (cx + cw // 2, cy - ch // 2),
        (cx + cw // 2 - 46, cy + ch // 2), (cx - cw // 2 + 46, cy + ch // 2)]
d.polygon(body, fill=white)
d.rounded_rectangle([cx - cw // 2 + 34, cy + ch // 2 - 70, cx + cw // 2 - 34, cy + ch // 2 + 12],
                    radius=40, fill=white)

# handle
d.arc([cx + cw // 2 - 40, cy - 90, cx + cw // 2 + 150, cy + 90], start=-70, end=70,
      fill=white, width=46)

# saucer
d.rounded_rectangle([cx - 260, cy + ch // 2 + 26, cx + 260, cy + ch // 2 + 76],
                    radius=26, fill=white)

# --- steam: three wavy strokes ---
import math
def steam(x0, ytop, ybot, amp, phase, width):
    pts = []
    for i in range(60):
        t = i / 59
        y = ytop + (ybot - ytop) * t
        x = x0 + amp * math.sin(t * math.pi * 2.1 + phase)
        pts.append((x, y))
    d.line(pts, fill=(255, 255, 255, 225), width=width, joint="curve")

steam(cx - 95, cy - 330, cy - 165, 26, 0.4, 26)
steam(cx + 5,  cy - 375, cy - 165, 30, 2.2, 26)
steam(cx + 105, cy - 330, cy - 165, 26, 4.0, 26)

# --- "activity" pulse dot so it reads as 'still awake' ---
d.ellipse([cx + cw // 2 + 96, cy - ch // 2 - 96, cx + cw // 2 + 190, cy - ch // 2 - 2],
          fill=(120, 235, 150, 255))
d.ellipse([cx + cw // 2 + 112, cy - ch // 2 - 80, cx + cw // 2 + 174, cy - ch // 2 - 18],
          fill=(255, 255, 255, 255))

# --- export PNG set + .icns ---
os.makedirs(OUT, exist_ok=True)
iconset = os.path.join(OUT, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
         (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
         (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
         (1024, "icon_512x512@2x")]
for px, name in sizes:
    img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"{name}.png"))
img.save(os.path.join(OUT, "preview_1024.png"))

# iconutil only exists on macOS; fall back to a hand-built ICNS (PNG payload).
if subprocess.run(["bash", "-c", "command -v iconutil"], capture_output=True).returncode == 0:
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
else:
    def build_icns(path):
        import struct
        # ICNS container: 'icns' + total size + entries. macOS accepts PNG payloads
        # for the modern types (ic07..ic10).
        types = {16: b"icp4", 32: b"icp5", 64: b"icp6", 128: b"ic07",
                 256: b"ic08", 512: b"ic09", 1024: b"ic10"}
        entries = []
        for px in (16, 32, 128, 256, 512, 1024):
            p = os.path.join(iconset, {16: "icon_16x16", 32: "icon_32x32", 128: "icon_128x128",
                                       256: "icon_256x256", 512: "icon_512x512",
                                       1024: "icon_512x512@2x"}[px] + ".png")
            data = open(p, "rb").read()
            entries.append(types[px] + struct.pack(">I", len(data) + 8) + data)
        body = b"".join(entries)
        with open(path, "wb") as f:
            f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    build_icns(os.path.join(OUT, "AppIcon.icns"))

print("wrote", os.path.join(OUT, "AppIcon.icns"))
