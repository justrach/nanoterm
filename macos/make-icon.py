#!/usr/bin/env python3
"""Draws nanoterm's app icon, a prompt over blocks in Codegraff colors (amber
on warm charcoal), and writes AppIcon.icns beside this file.
Needs Pillow and macOS's iconutil. Usage: python3 macos/make-icon.py"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024

def base():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Apple's icon grid: an 824-point square, corners of about 185.
    box = (100, 100, 924, 924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, 185, fill=255)
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    top, bottom = (0x2a, 0x26, 0x1e), (0x16, 0x14, 0x0f)
    for y in range(S):
        t = min(1, max(0, (y - 100) / 824))
        fd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    img.paste(fill, (0, 0), mask)
    d.rounded_rectangle(box, 185, outline=(0x3a, 0x35, 0x2b, 255), width=4)
    return img, d

def draw(d):
    amber, text, muted, faint = (0xe8, 0xa3, 0x3d, 255), (0xed, 0xea, 0xe2, 255), (0x9a, 0x93, 0x84, 255), (0x5c, 0x56, 0x4b, 255)
    violet = (0xbd, 0x80, 0xe4, 255)
    # The prompt: a chevron and a cursor on one line.
    d.line([(250, 300), (350, 390), (250, 480)], fill=amber, width=52, joint="curve")
    for x, y in ((250, 300), (350, 390), (250, 480)):
        d.ellipse((x - 26, y - 26, x + 26, y + 26), fill=amber)
    d.rounded_rectangle((410, 440, 560, 492), 10, fill=amber)
    # The blocks a command and the agent left.
    d.rounded_rectangle((230, 600, 640, 636), 18, fill=text)
    d.rounded_rectangle((230, 680, 520, 716), 18, fill=muted)
    d.ellipse((556, 672, 608, 724), fill=violet)
    d.rounded_rectangle((230, 760, 760, 796), 18, fill=faint)

def icns(img, name):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                suffix = "" if scale == 1 else "@2x"
                img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, name)], check=True)

if __name__ == "__main__":
    img, d = base()
    draw(d)
    img.save(os.path.join(tempfile.gettempdir(), "nanoterm-icon.png"))
    icns(img, "AppIcon.icns")
