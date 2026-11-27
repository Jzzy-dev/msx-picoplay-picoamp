#!/usr/bin/env python3
# vram_render.py dump.bin out.png: SCREEN 4 (G3, sprites mode 2) or SCREEN 8 from a dump: 128K VRAM, 32 palette bytes, 48 regs
import sys
from PIL import Image
d=open(sys.argv[1],'rb').read()
vram=d[:131072]; palb=d[131072:131104]; regs=d[131104:131152]
def pal(i):
    r=(palb[2*i]>>4)&7; b=palb[2*i]&7; g=palb[2*i+1]&7
    return (r*255//7,g*255//7,b*255//7)
P=[pal(i) for i in range(16)]
m=((regs[0]>>1)&7)<<2 | ((regs[1]>>3)&1)<<1 | ((regs[1]>>4)&1)  # M5 M4 M3 / M1 M2 order varies; use known values
mode5=(regs[0]>>1)&7
lines=212 if regs[9]&0x80 else 192
im=Image.new('RGB',(256,lines))
px=im.load()
if mode5==7:   # G7: SCREEN 8, page from R#2
    base=((regs[2]>>5)&1)*0x10000
    for y in range(lines):
        for x in range(256):
            c=vram[base+y*256+x]
            px[x,y]=(((c>>2)&7)*255//7,((c>>5)&7)*255//7,(c&3)*255//3)
else:          # G3
    nt=(regs[2]&0x7F)<<10; ct=((regs[10]&7)<<14)|((regs[3]&0x80)<<6); pt=(regs[4]&0x3C)<<11
    for y in range(192):
        row=y//8
        for cx in range(32):
            n=vram[nt+row*32+cx]+(row//8)*256
            p=vram[pt+n*8+(y&7)]; c=vram[ct+n*8+(y&7)]
            fg=P[c>>4]; bg=P[c&15]
            for b in range(8):
                px[cx*8+b,y]=fg if p&(0x80>>b) else (bg if (c&15) else P[regs[7]&15])
    # sprites mode 2, 8x8
    if not regs[8]&2:
        sat=((regs[11]&3)<<15)|((regs[5]&0xF8)<<7)|0x200; spt=(regs[6]&0x3F)<<11; sct=sat-512
        for s in range(32):
            sy=vram[sat+s*4]
            if sy==216: break
            sx=vram[sat+s*4+1]; pn=vram[sat+s*4+2]
            for l in range(8):
                yy=(sy+1+l)&255
                if yy>=192: continue
                col=vram[sct+s*16+l]; ci=col&15
                if not ci: continue
                pat=vram[spt+pn*8+l]
                for b in range(8):
                    if pat&(0x80>>b) and sx+b<256: px[sx+b,yy]=P[ci]
im=im.resize((512,lines*2),Image.NEAREST)
im.save(sys.argv[2])
