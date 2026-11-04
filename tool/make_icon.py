#!/usr/bin/env python3
"""Draws the app icon and writes it for macOS and Windows.

The mark is the size map's pebble: contour rings around one solid stone.
Needs rsvg-convert and magick (brew install librsvg imagemagick).
Usage: tool/make_icon.py
"""
import json
import math
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAPER = "#F1EFE7"
EDGE = "#E0DCD1"
INK = "#1D1C1A"
ACCENT = "#C96442"


def pebble(cx, cy, r):
    """A soft, slightly lopsided closed curve around (cx, cy)."""
    pts = []
    for i in range(7):
        a = 2 * math.pi * i / 7 - math.pi / 2
        k = 1 + 0.10 * math.sin(3 * a + 0.7) + 0.05 * math.cos(2 * a)
        pts.append((cx + r * k * math.cos(a), cy + r * k * math.sin(a) * 0.94))
    n = len(pts)
    d = f"M{(pts[0][0] + pts[-1][0]) / 2:.1f},{(pts[0][1] + pts[-1][1]) / 2:.1f}"
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        d += f" Q{p[0]:.1f},{p[1]:.1f} {(p[0] + q[0]) / 2:.1f},{(p[1] + q[1]) / 2:.1f}"
    return d + " Z"


def svg():
    # macOS icon grid: an 824 tile centred on a 1024 canvas.
    rings = "".join(
        f'<path d="{pebble(512, 512, r)}" fill="none" stroke="{INK}" '
        f'stroke-width="{w}"/>'
        for r, w in [(322, 11), (272, 11), (222, 11), (172, 11)]
    )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs>
  <filter id="s" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.22"/>
  </filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="{PAPER}" stroke="{EDGE}" stroke-width="3" filter="url(#s)"/>
{rings}
<path d="{pebble(512, 512, 112)}" fill="{ACCENT}"/>
</svg>"""


def main():
    source = ROOT / "tool" / "icon.svg"
    source.write_text(svg())
    mac = ROOT / "app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    sizes = sorted(
        {
            int(i["filename"].rsplit("_", 1)[1].split(".")[0])
            for i in json.loads((mac / "Contents.json").read_text())["images"]
        }
    )
    for s in sizes:
        subprocess.run(
            ["rsvg-convert", "-w", str(s), "-h", str(s), str(source),
             "-o", str(mac / f"app_icon_{s}.png")],
            check=True,
        )
    ico = ROOT / "app/windows/runner/resources/app_icon.ico"
    with tempfile.TemporaryDirectory() as tmp:
        big = pathlib.Path(tmp) / "icon.png"
        subprocess.run(
            ["rsvg-convert", "-w", "256", "-h", "256", str(source), "-o", str(big)],
            check=True,
        )
        subprocess.run(
            ["magick", str(big), "-define",
             "icon:auto-resize=256,128,64,48,32,16", str(ico)],
            check=True,
        )


if __name__ == "__main__":
    main()
