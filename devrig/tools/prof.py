import sys
from collections import Counter
mapf, exef, pcsf, base = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
syms=[]
for l in open(mapf):
    p=l.split()
    if len(p)==3 and p[1] in 'CcTt':
        syms.append((int(p[0],16),p[2]))
syms.sort()
import bisect
keys=[a for a,_ in syms]
def name(off):
    i=bisect.bisect_right(keys,off)-1
    return syms[i][1] if i>=0 else None
exe=open(exef,'rb').read()
cat=Counter(); c=Counter(); n=0
for l in open(pcsf):
    p=l.split(); pc=int(p[0]); n+=1
    if 1085<=pc<=1110: cat['idle']+=1; continue
    off=pc-base
    if 0<=off<len(exe) and len(p)>1:
        b=bytes.fromhex(p[1])
        if sum(1 for i in range(4) if exe[off+i]==b[i])>=3:
            cat['picoplay']+=1; c[name(off)]+=1; continue
    cat['system']+=1
print({k:'%.1f%%'%(100*v/n) for k,v in cat.items()})
for k,v in c.most_common(int(sys.argv[5]) if len(sys.argv)>5 else 15): print('  %5.1f%% %s'%(100*v/n,k))
