#!/usr/bin/env python3
# vram2png.py out.vram out.png - TEXT 1 / TEXT 2 from z80_rss's VRAM dump (128 KB + the 64 registers)
import sys
from PIL import Image
def p3(r, g, b): return (r * 255 // 7, g * 255 // 7, b * 255 // 7)
PAL = [p3(0,0,0), p3(0,0,0), p3(1,6,1), p3(3,7,3), p3(1,1,7), p3(2,3,7), p3(5,1,1), p3(2,6,7),
       p3(7,1,1), p3(7,3,3), p3(6,6,1), p3(6,6,4), p3(1,4,1), p3(6,2,5), p3(5,5,5), p3(7,7,7)]
v = open(sys.argv[1], 'rb').read()
R = list(v[0x20000:0x20040])
t2 = (R[0] & 0x0E) == 0x04
W = 80 if t2 else 40
rows = (27 if R[9] & 0x80 else 24) if t2 else 24
H = (212 if R[9] & 0x80 else 192)
nb = ((R[2] & 0x7C) << 10) if t2 else ((R[2] & 0x0F) << 10)
pb = ((R[4] & 0x3F) << 11) if t2 else ((R[4] & 0x07) << 11)
cb = (R[10] << 14) | ((R[3] & 0xF8) << 6)
fg, bg, bfg, bbg = R[7] >> 4, R[7] & 15, R[12] >> 4, R[12] & 15
pw = W * 6
im = Image.new('RGB', (pw + 32, H + 16), PAL[bg])
px = im.load()
for ty in range(rows):
    for tx in range(W):
        n = ty * W + tx
        ch = v[nb + n]
        bl = t2 and (v[cb + n // 8] >> (7 - n % 8)) & 1
        f, b = (bfg, bbg) if bl else (fg, bg)
        for r in range(8):
            y = ty * 8 + r
            if y >= H: break
            bits = v[pb + ch * 8 + r]
            for c in range(6):
                px[16 + tx * 6 + c, 8 + y] = PAL[f] if bits & (0x80 >> c) else PAL[b]
sc = 2 if t2 else 3
im = im.resize((im.width * sc // (1 if not t2 else 1), im.height * sc * (1 if not t2 else 2) // (1 if not t2 else 1) // (2 if t2 else 1)), Image.NEAREST)
im.save(sys.argv[2])
