#!/usr/bin/env python3
# vram2png.py vram.bin out.png - draw a SCREEN 4 (pattern mode, name table
# 1800h, patterns 0000h, colours 2000h) with PICOAMP's palette
import sys
from PIL import Image

def p3(r, g, b):
    return (r * 255 // 7, g * 255 // 7, b * 255 // 7)

PAL = [p3(0, 0, 0), p3(0, 0, 0), p3(1, 1, 3), p3(2, 2, 6), p3(3, 6, 7), p3(7, 7, 7), p3(4, 4, 5), p3(0, 4, 1),
       p3(2, 7, 2), p3(7, 7, 1), p3(7, 4, 0), p3(7, 1, 1), p3(6, 2, 6), p3(2, 2, 3), p3(0, 0, 2), p3(5, 5, 6)]
v = open(sys.argv[1], 'rb').read()
if len(v) >= 0x4000 + 32:          # the palette the program set (the harness saves it)
    pv = v[0x4000:0x4020]
    PAL = [p3((pv[2 * i] >> 4) & 7, pv[2 * i + 1] & 7, pv[2 * i] & 7) for i in range(16)]
R = list(v[0x4020:0x4060]) if len(v) >= 0x4060 else [0] * 64
if (R[0] & 0x0E) == 0x04 and (R[1] & 0x18) == 0x10:
    # TEXT 2 (80 columns): names at R#2, the blink bits at R#3/R#10, patterns at R#4
    rows = 27 if R[9] & 0x80 else 24
    nb = (R[2] & 0x7C) << 10
    cb = (R[10] << 14) | ((R[3] & 0xF8) << 6)
    pb = (R[4] & 0x3F) << 11
    fg, bg, bfg, bbg = R[7] >> 4, R[7] & 15, R[12] >> 4, R[12] & 15
    H = 212 if R[9] & 0x80 else 192
    im = Image.new('RGB', (512, H), PAL[bg])
    px = im.load()
    for ty in range(rows):
        for tx in range(80):
            n = ty * 80 + tx
            ch = v[(nb + n) & 0x3FFF]
            bl = (v[(cb + n // 8) & 0x3FFF] >> (7 - n % 8)) & 1
            f, b = (bfg, bbg) if bl else (fg, bg)
            for r in range(8):
                Y = ty * 8 + r
                if Y >= H:
                    break
                pat = v[(pb + ch * 8 + r) & 0x3FFF]
                for c in range(6):
                    px[16 + tx * 6 + c, Y] = PAL[f if (pat >> (7 - c)) & 1 else b]
    im.resize((1024, H * 4), Image.NEAREST).save(sys.argv[2])
    sys.exit(0)
im = Image.new('RGB', (256, 192))
px = im.load()
for ty in range(24):
    for tx in range(32):
        name = v[0x1800 + ty * 32 + tx]
        bank = (ty // 8) * 0x800
        for r in range(8):
            pat = v[bank + name * 8 + r]
            col = v[0x2000 + bank + name * 8 + r]
            for c in range(8):
                px[tx * 8 + c, ty * 8 + r] = PAL[(col >> 4) if (pat >> (7 - c)) & 1 else (col & 15)]
# sprites (mode 2, 8 x 8): attributes 1E00h, colours 1C00h, patterns 3800h
order = []
for n in range(32):
    if v[0x1E00 + n * 4] == 216:
        break
    order.append(n)
for n in reversed(order):           # plane 0 on top
    a = 0x1E00 + n * 4
    y, x, p = (v[a] + 1) & 255, v[a + 1], v[a + 2]
    for r in range(8):
        bits = v[0x3800 + p * 8 + r]
        c = v[0x1C00 + n * 16 + r] & 15
        for b in range(8):
            if bits >> (7 - b) & 1 and 0 <= x + b < 256 and 0 <= y + r < 192:
                px[x + b, y + r] = PAL[c]
im.resize((768, 576), Image.NEAREST).save(sys.argv[2])
