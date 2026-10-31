#!/usr/bin/env python3
# run.py com|rom "t:keys;t:keys..." shots... - RSS in openMSX (NMS 8245 + Nextor IDE, or the cartridge)
import sys, subprocess, os
mode = sys.argv[1]; steps = sys.argv[2]; end = float(sys.argv[3]); notls = os.environ.get('NOTLS', '0')
here = os.path.dirname(os.path.abspath(__file__))
L = ['set throttle %s' % os.environ.get('THROTTLE', 'off'), 'set maxframeskip 0', 'set minframeskip 0', 'set ::un_fixdir %s/../fix' % here, 'set ::un_notls %s' % notls, 'set ::un_rate 20', 'set ::un_slot %s' % os.environ.get('UNSLOT', '2'),
     'set ::un_debug %s' % os.environ.get('UNDEBUG','0'), 'source %s/unapi.tcl' % here] + ([ 'source %s/dbg.tcl' % here] if os.environ.get('DBG') else [])
n = 0
for st in steps.split(';'):
    if not st: continue
    t, k = st.split(':', 1)
    if k == 'SHOT':
        L.append('after time %s { screenshot -raw -doublesize %s/shot_%d.png }' % (t, here, n)); n += 1
    else:
        k = k.replace('\\r', '\r').replace('\\e', '\033')
        tcl = k.replace('\\', '\\\\').replace('"', '\\"').replace('[', '\\[').replace(']', '\\]').replace('$', '\\$').replace('\r', '\\r').replace('\033', '\\033')
        KM = {'ESC': (7, 0x04), 'ENTER': (7, 0x80), 'BS': (7, 0x20), 'TAB': (7, 0x08), 'LEFT': (8, 0x10), 'UP': (8, 0x20),
              'DOWN': (8, 0x40), 'RIGHT': (8, 0x80), 'DEL': (8, 0x08)}
        for i, c in enumerate('CDEFGHIJ'): KM[c] = (3, 1 << i)
        for i, c in enumerate('KLMNOPQR'): KM[c] = (4, 1 << i)
        for i, c in enumerate('STUVWXYZ'): KM[c] = (5, 1 << i)
        for i, c in enumerate('01234567'): KM[c] = (0, 1 << i)
        KM['A'] = (2, 0x40); KM['B'] = (2, 0x80); KM['8'] = (1, 1); KM['9'] = (1, 2)
        if k.startswith('K'):
            tt = float(t)
            for name in k[1:].split(','):
                row, bit = KM[name]
                L.append('after time %.2f { keymatrixdown %d %d }' % (tt, row, bit)); L.append('after time %.2f { keymatrixup %d %d }' % (tt + 0.15, row, bit))
                tt += 0.4
        else:
            L.append('after time %s { type "%s" }' % (t, tcl))
peek=os.environ.get('PEEK','')
if peek: L.append('after time %s { foreach a {%s} { puts -nonewline stderr "[format %%02X [debug read memory $a]] " }; puts stderr "" }' % (float(end)-0.01, peek))
L.append('after time %s { puts stderr [array get ::un_cnt] }' % (float(end)-0.02))
L.append('after time %s { puts stderr "PC [format %%04X [reg PC]] SP [format %%04X [reg SP]]" ; exit }' % end)
open(here + '/run.tcl', 'w').write('\n'.join(L) + '\n')
env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy', LD_LIBRARY_PATH='/home/claude/rig/prefix/lib',
           OPENMSX_USER_DATA='/home/claude/rig/omsx-user/share', OPENMSX_SYSTEM_DATA='/home/claude/rig/openMSX/share')
m = os.environ.get('MACHINE', 'Philips_NMS_8245')
args = ['/home/claude/rig/openMSX/derived/x86_64-linux-opt/bin/openmsx', '-machine', m]
if mode == 'com':
    args += ['-ext', 'RSS_IDE', '-cartb', here + '/FAKEUNAPI.ROM']
else:
    args += ['-carta', here + '/../../RSS.ROM', '-cartb', here + '/FAKEUNAPI.ROM']
    if os.environ.get('DISK'): args += ['-diska', os.environ['DISK']]
args += ['-script', here + '/run.tcl']
r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=1200)
print(r.stdout[-1500:], r.stderr[-3000:])
