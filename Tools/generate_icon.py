#!/usr/bin/env python3
"""Draws AeroPA's original app icon (1024x1024 PNG): graphite field, white
swept-wing chevron, three blue sound-wave arcs. Pure Python, no dependencies."""
import math, os, struct, zlib
N = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "AeroPA", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

def blend(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
def clamp01(x): return max(0.0, min(1.0, x))
BG_TOP, BG_BOT = (0.09, 0.10, 0.12), (0.02, 0.025, 0.03)
BLUE, WHITE = (0.36, 0.58, 1.0), (1.0, 1.0, 1.0)

TIP = (560.0, 470.0)
# Navigation-arrow style aircraft mark pointing up-right (tip, left wing, notch, tail).
POLY = [TIP, (220.0, 600.0), (420.0, 650.0), (450.0, 830.0)]

def inside(px, py):
    c = False
    for i in range(len(POLY)):
        x1, y1 = POLY[i]; x2, y2 = POLY[(i + 1) % len(POLY)]
        if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1: c = not c
    return c

def chevron_cov(x, y):
    if x < 200 or x > 580 or y < 450 or y > 850: return 0.0
    hits = sum(inside(x + (i + 0.5) / 3, y + (j + 0.5) / 3) for i in range(3) for j in range(3))
    return hits / 9

def arcs_cov(x, y):
    cx, cy = TIP
    r = math.hypot(x - cx, y - cy)
    ang = math.degrees(math.atan2(-(y - cy), x - cx))
    if not (-25 <= ang <= 115): return 0.0
    best = 0.0
    for R in (130, 215, 300):
        best = max(best, clamp01((20 - abs(r - R)) + 0.5))
    edge = min(ang + 25, 115 - ang)
    return best * clamp01(edge / 18) * 1.0

rows = []
for y in range(N):
    row = bytearray([0])
    base = blend(BG_TOP, BG_BOT, y / N)
    for x in range(N):
        c = base
        c = blend(c, BLUE, arcs_cov(x, y))
        c = blend(c, WHITE, chevron_cov(x, y))
        row += bytes(int(clamp01(v) * 255) for v in c)
    rows.append(bytes(row))

def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
open(OUT, "wb").write(png)
print("wrote", os.path.abspath(OUT))
