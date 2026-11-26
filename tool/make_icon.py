#!/usr/bin/env python3
"""Draws the macOS app icon (Resources/AppIcon.icns) from tool/icon.svg.

The mark is the size map's pebble: contour rings around one solid stone.
Needs rsvg-convert (brew install librsvg) and macOS iconutil.
Usage: tool/make_icon.py
"""
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
    out_icns = ROOT / "Resources" / "AppIcon.icns"
    out_icns.parent.mkdir(parents=True, exist_ok=True)
    pairs = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for px, filename in pairs:
            subprocess.run(
                ["rsvg-convert", "-w", str(px), "-h", str(px), str(source), "-o", str(iconset / filename)],
                check=True,
            )
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out_icns)], check=True)


if __name__ == "__main__":
    main()
