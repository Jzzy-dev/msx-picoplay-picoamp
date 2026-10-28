#!/usr/bin/env python3
# fatput.py image.dsk DIR/NAME.EXT localfile  - replace (or create) a file in partition 1 (FAT12/16)
import sys, struct
img, path, src = sys.argv[1:4]
f = open(img, 'r+b'); d = bytearray(f.read())
po = struct.unpack('<I', d[0x1c6:0x1ca])[0] * 512
bps, spc, rsv, nf, nroot, ts16, _, spf = struct.unpack('<HBHBHHBH', d[po+11:po+24])
ts = ts16 or struct.unpack('<I', d[po+32:po+36])[0]
fat = po + rsv*bps; root = fat + nf*spf*bps; data = root + nroot*32
cs = spc*bps; ncl = (ts - (data-po)//bps)//spc + 2
fat16 = ncl >= 4085
def get(c):
    if fat16: return struct.unpack('<H', d[fat+2*c:fat+2*c+2])[0]
    v = struct.unpack('<H', d[fat+c*3//2:fat+c*3//2+2])[0]; return v >> 4 if c & 1 else v & 0xfff
def put(c, v):
    for k in range(nf):
        b = fat + k*spf*bps
        if fat16: d[b+2*c:b+2*c+2] = struct.pack('<H', v)
        else:
            o = b + c*3//2; w = struct.unpack('<H', d[o:o+2])[0]
            w = (w & 0xf) | (v << 4) if c & 1 else (w & 0xf000) | v
            d[o:o+2] = struct.pack('<H', w)
EOC = 0xffff if fat16 else 0xfff
def coff(c): return data + (c-2)*cs
def chain(c):
    r = []
    while 2 <= c < (0xfff8 if fat16 else 0xff8): r.append(c); c = get(c)
    return r
def dirents(c):  # c=None -> root
    if c is None:
        for i in range(nroot): yield root + i*32
    else:
        for cl in chain(c):
            for i in range(cs//32): yield coff(cl) + i*32
def n83(n):
    a, _, b = n.upper().partition('.'); return (a.ljust(8) + b.ljust(3)).encode()
parts = path.replace('\\', '/').split('/'); cur = None
for p in parts[:-1]:
    for e in dirents(cur):
        if d[e:e+11] == n83(p): cur = struct.unpack('<H', d[e+26:e+28])[0]; break
    else: sys.exit('dir not found ' + p)
blob = open(src, 'rb').read()
ent = None
for e in dirents(cur):
    if d[e:e+11] == n83(parts[-1]): ent = e; break
if ent is None:
    for e in dirents(cur):
        if d[e] in (0, 0xe5): ent = e; d[e:e+32] = n83(parts[-1]) + bytes(21); d[e+11] = 0x20; break
old = chain(struct.unpack('<H', d[ent+26:ent+28])[0])
for c in old: put(c, 0)
need = max(1, -(-len(blob)//cs)); cl = []
c = 2
while len(cl) < need:
    if get(c) == 0: cl.append(c)
    c += 1
for i, c in enumerate(cl):
    put(c, cl[i+1] if i+1 < len(cl) else EOC)
    chunk = blob[i*cs:(i+1)*cs]; d[coff(c):coff(c)+cs] = chunk + bytes(cs-len(chunk))
d[ent+26:ent+28] = struct.pack('<H', cl[0]); d[ent+28:ent+32] = struct.pack('<I', len(blob))
f.seek(0); f.write(d); f.close()
print('wrote', path, len(blob), 'bytes, clusters', cl[0], '..', cl[-1])
