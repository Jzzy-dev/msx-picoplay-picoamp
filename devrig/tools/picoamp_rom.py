#!/usr/bin/env python3
# picoamp_rom.py - PICOAMP.ROM on openMSX's free C-BIOS (no private ROMs needed), the
# screen saved from the VDP (headless screenshots come out black here: vram_render.py)
#
#   cd <work folder with PICOAMP.ROM (built with -DRIGENASLT) and card.img>
#   picoamp_rom.py "12:{D}" "14:{N}" "20:v" "24:shot cover" "25:c" "28:shot clock" "29:exit"
#
# "t:keys" types at emulated time t; {U} {D} {L} {R} {N} Return {E} Esc {B} BS {S} Space;
# "t:shot name" writes name.bin (VRAM, palette, registers) and name.png; "t:exit" ends.
# MOUSE=1 plugs a mouse into port A.
#
# The extension PicoAmp_Rig.xml (made here): the ROM in sub-slot 0 of an expanded slot
# (ASCII16 banks), the PicoVerseAudio device with card.img in sub-slot 3, as on the cartridge.
# C-BIOS's ENASLT does not switch page 1 to a sub-slot: build the ROM with
#   sjasmplus -DROMBUILD -DRIGENASLT --raw=PICOAMP.ROM picoamp.asm
# for its own page 1 switch (the real ROM keeps the BIOS's).
import sys, subprocess, os
here = os.path.dirname(os.path.abspath(__file__))
R = os.environ.get('RIG', os.path.dirname(here))
work = os.getcwd()
os.makedirs(R + '/omsx-user/share/extensions', exist_ok=True)
os.makedirs(R + '/omsx-user/share/machines', exist_ok=True)
os.makedirs(R + '/omsx-user/share/systemroms', exist_ok=True)
cb = R + '/openMSX/Contrib/cbios'
for f in os.listdir(cb):
    dst = R + ('/omsx-user/share/machines/' if f.endswith('.xml') else '/omsx-user/share/systemroms/') + f
    if not os.path.exists(dst):
        open(dst, 'wb').write(open(cb + '/' + f, 'rb').read())
open(R + '/omsx-user/share/extensions/PicoAmp_Rig.xml', 'w').write('''<?xml version="1.0" ?>
<!DOCTYPE msxconfig SYSTEM 'msxconfig2.dtd'>
<msxconfig>
  <info><name>PicoAmp cartridge (rig)</name><manufacturer>test</manufacturer><code/><release_year>2026</release_year>
  <description>PICOAMP.ROM in sub-slot 0, the engine in 3</description><type>test</type></info>
  <devices>
    <primary slot="any">
      <secondary slot="0">
        <ROM id="PICOAMP ROM"><mem base="0x4000" size="0x4000"/><rom><filename>%s/PICOAMP.ROM</filename></rom><mappertype>ASCII16</mappertype></ROM>
      </secondary>
      <secondary slot="3">
        <PicoVerseAudio id="PicoVerse Audio Engine"><mem base="0x4000" size="0x4000"/>
          <image>%s/card.img</image><wav>%s/out.wav</wav><stream>%s/assets/cbr128_v23.mp3</stream></PicoVerseAudio>
      </secondary>
    </primary>
  </devices>
</msxconfig>
''' % (work, work, work, R))
keys = {'U': (8, 0x20), 'D': (8, 0x40), 'L': (8, 0x10), 'R': (8, 0x80), 'N': (7, 0x80), 'E': (7, 0x04), 'B': (7, 0x20), 'S': (8, 0x01)}
lines = ['set throttle off'] + (['plug joyporta mouse'] if os.environ.get('MOUSE') else [])
shots = []
for a in sys.argv[1:]:
    t, k = a.split(':', 1)
    if k.startswith('shot '):
        n = k[5:]
        shots.append(n)
        lines.append('after time %s { set f [open %s/%s.bin w]; fconfigure $f -translation binary; '
                     'puts -nonewline $f [debug read_block VRAM 0 131072]; puts -nonewline $f [debug read_block {VDP palette} 0 32]; '
                     'puts -nonewline $f [debug read_block {VDP regs} 0 48]; close $f }' % (t, work, n))
    elif k.startswith('{'):
        r, b = keys[k[1]]
        lines.append('after time %s { keymatrixdown %d %d }' % (t, r, b))
        lines.append('after time %.2f { keymatrixup %d %d }' % (float(t) + 0.3, r, b))
    elif k == 'exit':
        lines.append('after time %s { exit }' % t)
    else:
        lines.append('after time %s { type "%s" }' % (t, k.replace('\\r', '\r').replace('"', '\\"').replace('$', '\\$')))
open('drv.tcl', 'w').write('\n'.join(lines) + '\n')
env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy', LD_LIBRARY_PATH=R + '/prefix/lib',
           OPENMSX_USER_DATA=R + '/omsx-user/share', OPENMSX_SYSTEM_DATA=R + '/openMSX/share')
r = subprocess.run([R + '/openMSX/derived/x86_64-linux-opt/bin/openmsx', '-machine', 'C-BIOS_MSX2_EU', '-ext', 'PicoAmp_Rig',
                    '-script', 'drv.tcl'], env=env, capture_output=True, text=True, timeout=3600)
open('drv.err', 'w').write(r.stderr)
for n in shots:
    subprocess.run([sys.executable, os.path.join(here, 'vram_render.py'), n + '.bin', n + '.png'])
