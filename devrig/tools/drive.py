#!/usr/bin/env python3
# drive.py - run openMSX headless with a list of key presses and take a screenshot after each.
#
#   cd <work folder>            (holds hd.dsk; screenshots, out.wav, drv.err go here)
#   drive.py <start_s> <gap_s> key1 key2 ...
#
# Keys: plain text is typed ("CD SYMBOS\r"), {X} or {Xn} presses a key n times:
#   {U} {D} {L} {R} arrows, {N} Return, {E} Esc, {T} Tab, {S} Space, {B} Backspace,
#   {C} Ctrl+Esc (SymbOS start menu).  "@g" changes the gap for the following keys.
# Screenshot i (shot_i.png, 640x480) is taken just before key i+1.
#
# Environment:
#   RIG          the devrig folder (default: two levels above this script's folder)
#   MACHINE      openMSX machine (default Philips_NMS_8245)
#   PCSAMPLE=t,n sample the Z80 PC (and 12 code bytes) every 1 ms from emulated time t, n times
#                -> pcs.txt (see prof.py)
#   DUMPRAM=1    dump the memory mapper to ram.bin at the end
#   PVA_TRACE=1  the PicoVerseAudio device prints the engine status once a second (drv.err)
import sys, subprocess, os

here = os.path.dirname(os.path.abspath(__file__))
rig = os.environ.get('RIG', os.path.dirname(here))
work = os.getcwd()
start = float(sys.argv[1]); gap = float(sys.argv[2]); keys = sys.argv[3:]

# an extension for this work folder (so several runs can go on at once)
ext = 'PicoVerse_' + ''.join(c if c.isalnum() else '_' for c in os.path.basename(work))
tpl = open(os.path.join(rig, 'templates', 'PicoVerse_Player.xml.in')).read()
os.makedirs(os.path.join(rig, 'omsx-user', 'share', 'extensions'), exist_ok=True)
open(os.path.join(rig, 'omsx-user', 'share', 'extensions', ext + '.xml'), 'w').write(
    tpl.replace('@WORK@', work).replace('@ASSETS@', os.path.join(rig, 'assets')).replace('@RIG@', rig))

def shot(t, i):
    return 'after time %.2f { screenshot -raw -doublesize %s/shot_%d.png }' % (t, work, i)

combo_keys = {'R': [(8, 0x80)], 'D': [(8, 0x40)], 'U': [(8, 0x20)], 'L': [(8, 0x10)], 'E': [(7, 0x04)],
              'C': [(6, 0x02), (7, 0x04)], 'N': [(7, 0x80)], 'T': [(7, 0x08)], 'S': [(8, 0x01)],
              'B': [(7, 0x20)]}
t = start
lines = ['set throttle off']
for i, k in enumerate(keys):
    if k.startswith('@'):
        gap = float(k[1:])
        continue
    if k.startswith('{') and k.endswith('}'):
        combo = combo_keys[k[1]]
        n = int(k[2:-1] or 1)
        for j in range(n):
            for r, b in combo: lines.append('after time %.2f { keymatrixdown %d %d }' % (t + j * 0.4, r, b))
            for r, b in combo: lines.append('after time %.2f { keymatrixup %d %d }' % (t + j * 0.4 + 0.2, r, b))
    elif k:
        k = k.replace('\\r', '\r').replace('\\e', '\033')
        tcl = (k.replace('\\', '\\\\').replace('"', '\\"').replace('[', '\\[').replace(']', '\\]')
                .replace('$', '\\$').replace('\r', '\\r').replace('\033', '\\033'))
        lines.append('after time %.1f { type "%s" }' % (t, tcl))
    lines.append(shot(t + gap - 0.5, i))
    t += gap
if os.environ.get('PCSAMPLE'):
    t0, cnt = os.environ['PCSAMPLE'].split(',')
    lines.insert(1, 'proc pcs {n} { global pcf; set pc [reg PC]; binary scan [debug read_block memory $pc 12] H* hx; '
                    'puts $pcf "$pc $hx"; if {$n > 0} { after time 0.001 [list pcs [expr {$n-1}]] } else { close $pcf } }')
    lines.append('after time %s { set pcf [open %s/pcs.txt w]; pcs %s }' % (t0, work, cnt))
if os.environ.get('DUMPRAM'):
    lines.append('after time %.1f { foreach d [debug list] { if {[string match -nocase "*mapper*" $d]} { '
                 'set f [open %s/ram.bin w]; fconfigure $f -translation binary; '
                 'puts -nonewline $f [debug read_block $d 0 [debug size $d]]; close $f } } }' % (t - 0.3, work))
lines.append('after time %.1f { exit }' % t)
open('drv.tcl', 'w').write('\n'.join(lines) + '\n')
env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy',
           LD_LIBRARY_PATH=os.path.join(rig, 'prefix', 'lib'),
           OPENMSX_USER_DATA=os.path.join(rig, 'omsx-user', 'share'),
           OPENMSX_SYSTEM_DATA=os.path.join(rig, 'openMSX', 'share'))
exe = os.path.join(rig, 'openMSX', 'derived', 'x86_64-linux-opt', 'bin', 'openmsx')
r = subprocess.run([exe, '-machine', os.environ.get('MACHINE', 'Philips_NMS_8245'), '-ext', ext, '-script', 'drv.tcl'],
                   env=env, capture_output=True, text=True, timeout=3600)
open('drv.err', 'w').write(r.stderr)
print(r.stdout[-400:], r.stderr[-400:])
