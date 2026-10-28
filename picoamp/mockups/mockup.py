#!/usr/bin/env python3
# Mock-ups for the MSX-DOS PicoPlay player, drawn under the real VDP rules:
# pattern mode (SCREEN 4 on MSX2, SCREEN 2 on MSX1), 32 x 24 tiles of 8 x 8,
# every 8-pixel row of a tile has one foreground and one background colour,
# sprites 16 x 16 (MSX2: a colour per line, 8 per line; MSX1: one colour, 4 per
# line). The font is C-BIOS's (BSD licence, Eric Boon).
#
#   mockup.py <c-bios font_us.asm> <out dir>
import re, sys, math
from PIL import Image

FONT = {}
def load_font(path):
    n = 0
    for line in open(path):
        m = re.match(r'\s*db\s+(.*?)\s*;', line)
        if not m:
            continue
        FONT[n] = [int(v.strip().lstrip('$'), 16) for v in m.group(1).split(',')]
        n += 1

def p3(r, g, b):  # MSX2 9-bit colour
    return (r * 255 // 7, g * 255 // 7, b * 255 // 7)

MSX2_PAL = [p3(0, 0, 0), p3(0, 0, 0), p3(1, 1, 3), p3(2, 2, 6), p3(3, 6, 7), p3(7, 7, 7), p3(4, 4, 5),
            p3(0, 4, 1), p3(2, 7, 2), p3(7, 7, 1), p3(7, 4, 0), p3(7, 1, 1), p3(6, 2, 6), p3(2, 2, 3),
            p3(0, 0, 2), p3(5, 5, 6)]
# names for the MSX2 palette above
BLK, BLUE_D, BLUE, CYAN, WHITE, GREY, GREEN_D, GREEN, YELLOW, ORANGE, RED, MAGENTA, GREY_D, NAVY, GREY_L = range(1, 16)

TMS_PAL = [(0, 0, 0), (0, 0, 0), (33, 200, 66), (94, 220, 120), (84, 85, 237), (125, 118, 252), (212, 82, 77),
           (66, 235, 245), (252, 85, 84), (255, 121, 120), (212, 193, 84), (230, 206, 128), (33, 176, 59),
           (201, 91, 186), (204, 204, 204), (255, 255, 255)]
# MSX1: the nearest fixed colours for the same roles
MSX1_MAP = {BLK: 1, BLUE_D: 4, BLUE: 4, CYAN: 7, WHITE: 15, GREY: 14, GREEN_D: 12, GREEN: 2, YELLOW: 11,
            ORANGE: 10, RED: 8, MAGENTA: 13, GREY_D: 1, NAVY: 1, GREY_L: 14, 0: 0}

class Screen:
    def __init__(self, bg):
        self.pat = [[[0] * 8 for _ in range(32)] for _ in range(24)]
        self.col = [[[(bg, bg)] * 8 for _ in range(32)] for _ in range(24)]
        self.sprites = []

    def tile(self, x, y, pat, fg, bg):
        if 0 <= x < 32 and 0 <= y < 24:
            self.pat[y][x] = list(pat)
            self.col[y][x] = [(fg[i] if isinstance(fg, list) else fg, bg[i] if isinstance(bg, list) else bg) for i in range(8)]

    def text6(self, px, y, s, fg, bg):
        # 6-pixel characters packed across tiles (pattern mode with 768 different
        # patterns is a bitmap: the player writes the text into the patterns).
        # The colours stay per tile row, so a text sets them for the tiles it touches.
        for i, ch in enumerate(s):
            g = FONT.get(ord(ch), FONT[32])
            x0 = px + i * 6
            for r in range(8):
                for c in range(6):
                    on = (g[r] >> (7 - c)) & 1
                    X = x0 + c
                    tx, bx = X // 8, X % 8
                    if not (0 <= tx < 32):
                        continue
                    pat = self.pat[y][tx]
                    if on:
                        pat[r] |= 0x80 >> bx
                    else:
                        pat[r] &= ~(0x80 >> bx) & 0xFF
        for tx in range(px // 8, min(32, (px + len(s) * 6 + 7) // 8)):
            self.col[y][tx] = [(fg, bg)] * 8

    def text(self, x, y, s, fg, bg, shift=1):
        for i, ch in enumerate(s):
            g = FONT.get(ord(ch), FONT[32])
            self.tile(x + i, y, [(b >> shift) for b in g], fg, bg)

    def fill(self, x, y, w, h, bg):
        for j in range(h):
            for i in range(w):
                self.tile(x + i, y + j, [0] * 8, bg, bg)

    def bitmap(self, x, y, rows, fg, bg):
        # rows: strings of '#'/'.' covering whole tiles; fg may be a function of the pixel row
        h = len(rows)
        w = len(rows[0])
        for ty in range(h // 8):
            for tx in range(w // 8):
                pat = []
                for r in range(8):
                    bits = rows[ty * 8 + r][tx * 8: tx * 8 + 8]
                    pat.append(int(''.join('1' if c == '#' else '0' for c in bits), 2))
                f = [fg(ty * 8 + r) if callable(fg) else fg for r in range(8)]
                self.tile(x + tx, y + ty, pat, f, bg)

    def sprite(self, x, y, rows, colours):
        self.sprites.append((x, y, rows, colours))

    def render(self, pal, scale=3, msx1=False):
        im = Image.new('RGB', (256, 192))
        px = im.load()
        cmap = (lambda c: MSX1_MAP.get(c, c)) if msx1 else (lambda c: c)
        for ty in range(24):
            for tx in range(32):
                for r in range(8):
                    fg, bg = self.col[ty][tx][r]
                    b = self.pat[ty][tx][r]
                    for c in range(8):
                        px[tx * 8 + c, ty * 8 + r] = pal[cmap(fg if (b >> (7 - c)) & 1 else bg)]
        # sprites (back to front: the first is on top, as on the VDP)
        for (x, y, rows, colours) in reversed(self.sprites):
            for r, line in enumerate(rows):
                for c, ch in enumerate(line):
                    if ch == '#':
                        col = colours[0] if msx1 else colours[min(r, len(colours) - 1)]
                        if 0 <= x + c < 256 and 0 <= y + r < 192:
                            px[x + c, y + r] = pal[cmap(col)]
        return im.resize((256 * scale, 192 * scale), Image.NEAREST)

# ---------------------------------------------------------------- pieces
SEG = {  # 7-segment digits on a 16 x 24 cell
    '0': 'abcdef', '1': 'bc', '2': 'abged', '3': 'abgcd', '4': 'fgbc', '5': 'afgcd', '6': 'afgedc',
    '7': 'abc', '8': 'abcdefg', '9': 'abcdfg', ' ': ''}

def digit_rows(d, w=16, h=24, t=3):
    g = [['.'] * w for _ in range(h)]
    def hline(y):
        for yy in range(y, y + t):
            for x in range(t, w - t - 1):
                g[yy][x] = '#'
    def vline(x, y0, y1):
        for yy in range(y0, y1):
            for xx in range(x, x + t):
                g[yy][xx] = '#'
    s = SEG[d]
    mid = h // 2 - 1
    if 'a' in s: hline(1)
    if 'g' in s: hline(mid)
    if 'd' in s: hline(h - t - 1)
    if 'f' in s: vline(1, 2, mid + 1)
    if 'b' in s: vline(w - t - 2, 2, mid + 1)
    if 'e' in s: vline(1, mid + 2, h - 2)
    if 'c' in s: vline(w - t - 2, mid + 2, h - 2)
    return [''.join(r) for r in g]

def colon_rows(w=8, h=24):
    g = [['.'] * w for _ in range(h)]
    for y in (7, 8, 15, 16):
        for x in (3, 4):
            g[y][x] = '#'
    return [''.join(r) for r in g]

def big_time(scr, x, y, s, fg, bg):
    for ch in s:
        if ch == ':':
            scr.bitmap(x, y, colon_rows(), fg, bg)
            x += 1
        else:
            scr.bitmap(x, y, digit_rows(ch), fg, bg)
            x += 2
    return x

ICONS = {
    'prev': [0x00, 0x46, 0x4E, 0x5E, 0x5E, 0x4E, 0x46, 0x00],
    'play': [0x00, 0x20, 0x30, 0x38, 0x3C, 0x38, 0x30, 0x20],
    'pause': [0x00, 0x6C, 0x6C, 0x6C, 0x6C, 0x6C, 0x6C, 0x00],
    'stop': [0x00, 0x7C, 0x7C, 0x7C, 0x7C, 0x7C, 0x7C, 0x00],
    'next': [0x00, 0x62, 0x72, 0x7A, 0x7A, 0x72, 0x62, 0x00],
    'rew': [0x00, 0x12, 0x36, 0x7E, 0x7E, 0x36, 0x12, 0x00],
    'ffw': [0x00, 0x48, 0x6C, 0x7E, 0x7E, 0x6C, 0x48, 0x00],
    'note': [0x0E, 0x0A, 0x08, 0x08, 0x38, 0x78, 0x30, 0x00],
    'folder': [0x00, 0x70, 0x8E, 0x82, 0x82, 0x82, 0xFE, 0x00],
    'radio': [0x04, 0x08, 0x7E, 0x42, 0x5A, 0x5A, 0x7E, 0x00],
    'hline': [0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00],
    'track': [0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00],
    'knob': [0x00, 0x3C, 0x7E, 0xFF, 0xFF, 0x7E, 0x3C, 0x00],
    'full': [0xFF] * 8,
}

def spectrum_values(n, t=0.0):
    out = []
    for i in range(n):
        x = i / (n - 1)
        v = 0.85 * math.exp(-((x - 0.12) ** 2) / 0.02) + 0.55 * math.exp(-((x - 0.45) ** 2) / 0.05) + 0.25
        v *= 0.8 + 0.2 * math.sin(i * 1.7 + t)
        v = max(0.05, min(1.0, v - 0.25 * x))
        out.append(v)
    return out

def spectrum(scr, x, y, bars, rows, colour_of_seg, peak_col, bg, vals, peaks):
    # each bar: one tile wide, 2 LED segments per tile (3 lit rows, 1 gap)
    nseg = rows * 2
    for b in range(bars):
        lit = int(vals[b] * nseg + 0.5)
        pk = min(nseg - 1, max(lit, int(peaks[b] * nseg + 0.5)))
        for t in range(rows):
            ty = y + rows - 1 - t
            pat, fg = [0] * 8, [bg] * 8
            for half in range(2):          # lower segment: rows 4-6, upper: rows 0-2
                seg = t * 2 + half
                r0 = 4 if half == 0 else 0
                on = seg < lit or seg == pk
                col = peak_col if (seg == pk and seg >= lit) else colour_of_seg(seg, nseg)
                for r in range(r0, r0 + 3):
                    pat[r] = 0x7E if on else 0x00
                    fg[r] = col
            scr.tile(x + b, ty, pat, fg, bg)

def hmeter(scr, x, y, w, level, colours, bg, dim):
    # horizontal LED strip: 2 segments per tile
    nseg = w * 2
    lit = int(level * nseg + 0.5)
    for i in range(w):
        pat = [0] * 8
        # a tile row has one fg colour: one tile = one colour, segments within it share it
        segs = [i * 2, i * 2 + 1]
        on = [s < lit for s in segs]
        col = colours(i * 2, nseg) if on[0] else dim
        for r in range(1, 7):
            pat[r] = (0x70 if on[0] or True else 0) | (0x07 if on[1] or True else 0)
        fg = col
        # unlit segments drawn in the dim colour: split by using the dim colour for the whole tile
        if not on[0]:
            fg = dim
        if on[0] and not on[1]:
            for r in range(1, 7):
                pat[r] = 0x70
        scr.tile(x + i, y, pat, fg, bg)

def grad(seg, n):
    f = seg / n
    return GREEN if f < 0.55 else YELLOW if f < 0.8 else RED

# ---------------------------------------------------------------- A: MUBScope / Winamp, MSX2
def mock_a(msx1=False):
    s = Screen(NAVY)
    s.fill(0, 0, 32, 1, BLUE)
    s.tile(0, 0, ICONS['note'], YELLOW, BLUE)
    s.text(1, 0, "PICOPLAY  PLAYING     1/12 REP", WHITE, BLUE)
    big_time(s, 1, 1, "03:27", RED, NAVY)
    s.text6(11 * 8, 1, "VAMPIRE KILLER (ARRANGE)", YELLOW, NAVY)
    s.text6(11 * 8, 2, "KONAMI KUKEIHA CLUB", CYAN, NAVY)
    s.text6(11 * 8, 3, "128 KBPS  44.1 KHZ  STEREO", GREEN, NAVY)
    for i in range(30):
        s.tile(1 + i, 4, ICONS['track'], GREY, NAVY)
    s.tile(1 + 11, 4, ICONS['knob'], WHITE, NAVY)
    s.text(1, 5, "SPECTRUM", MAGENTA, NAVY)
    s.text(13, 5, "PEAK", GREY, NAVY)
    s.text(24, 5, "LEVEL", MAGENTA, NAVY)
    vals = spectrum_values(22)
    peaks = [min(1.0, v + 0.08 + 0.05 * math.sin(i)) for i, v in enumerate(vals)]
    spectrum(s, 1, 6, 22, 10, grad, WHITE, NAVY, vals, peaks)
    # VU L / R, vertical
    spectrum(s, 25, 6, 1, 10, grad, WHITE, NAVY, [0.78], [0.86])
    spectrum(s, 28, 6, 1, 10, grad, WHITE, NAVY, [0.70], [0.80])
    s.text(25, 16, "L", CYAN, NAVY)
    s.text(28, 16, "R", CYAN, NAVY)
    for x, lab in ((1, "60"), (5, "250"), (10, "1K"), (15, "4K"), (20, "16K")):
        s.text(x, 16, lab, CYAN, NAVY)
    for i in range(32):
        s.tile(i, 17, ICONS['hline'], BLUE, NAVY)
    s.tile(1, 18, ICONS['folder'], YELLOW, NAVY)
    s.text(2, 18, "A:\\MUSIC\\KONAMI", YELLOW, NAVY)
    s.text(24, 18, "12 FILES", GREY, NAVY)
    rows = [("[..]", "", False), ("01 VAMPIRE KILLER (ARRANGE).MP3", "4:05", True),
            ("02 NEMESIS - STAGE 1 AIR BATTLE.MP3", "2:48", False), ("03 METAL GEAR - THEME OF TARA.MP3", "3:12", False)]
    for i, (n, t, sel) in enumerate(rows):
        fg, bg = (NAVY, CYAN) if sel else (WHITE, NAVY)
        s.fill(1, 19 + i, 30, 1, bg)
        if len(n) > 33:
            n = n[:31] + ".."
        s.text6(2 * 8, 19 + i, n, fg, bg)
        s.text6(31 * 8 - len(t) * 6, 19 + i, t, fg, bg)
    # control row
    s.fill(0, 23, 32, 1, BLUE_D)
    x = 1
    for ic in ('prev', 'rew', 'play', 'pause', 'stop', 'ffw', 'next'):
        s.tile(x, 23, ICONS[ic], GREEN if ic == 'play' else WHITE, BLUE_D)
        x += 1
    s.text(9, 23, "SHF REP EQ", GREY_L, BLUE_D)
    s.text(20, 23, "VOL", GREY_L, BLUE_D)
    for i in range(8):
        s.tile(24 + i, 23, [0, 0x7E, 0x7E, 0x7E, 0x7E, 0x7E, 0x7E, 0] if i < 6 else [0, 0, 0, 0, 0, 0, 0x7E, 0], GREEN if i < 4 else YELLOW, BLUE_D)
    return s

# ---------------------------------------------------------------- C: Synthesaurus, MSX2
def reel_rows(phase):
    g = [['.'] * 24 for _ in range(24)]
    for y in range(24):
        for x in range(24):
            r = math.hypot(x - 11.5, y - 11.5)
            if 9.5 <= r <= 11.5:
                g[y][x] = '#'
            a = math.atan2(y - 11.5, x - 11.5) + phase
            if r < 8.5 and (abs(math.sin(a * 1.5)) < 0.18 and r > 2):
                g[y][x] = '#'
            if r < 2.2:
                g[y][x] = '#'
    return [''.join(r) for r in g]

def button(s, x, y, icon, c):
    s.fill(x, y, 3, 2, c)
    rows = []
    for r in range(16):
        if 4 <= r < 12:
            bits = ICONS[icon][r - 4]
            line = '.' * 8 + ''.join('#' if (bits >> (7 - k)) & 1 else '.' for k in range(8)) + '.' * 8
        else:
            line = '.' * 24
        rows.append(line)
    s.bitmap(x, y, rows, BLK, c)

def mock_c():
    s = Screen(BLUE)
    # cassette deck
    s.fill(1, 1, 12, 6, GREY_D)
    s.bitmap(2, 2, reel_rows(0.0), GREEN, GREY_D)
    s.bitmap(9, 2, reel_rows(0.6), GREEN, GREY_D)
    s.fill(5, 3, 4, 1, BLK)
    for i in range(4):
        s.tile(5 + i, 3, ICONS['hline'], CYAN, BLK)
    s.text6(5 * 8 + 1, 5, "C-60", GREY_L, GREY_D)
    s.fill(1, 8, 12, 1, BLK)
    s.text6(1 * 8 + 2, 8, "REC 0347  SIDE A", RED, BLK)
    for i, (ic, c) in enumerate((('play', GREEN), ('pause', ORANGE), ('stop', RED), ('prev', GREEN))):
        button(s, 1 + i * 3, 10, ic, c)
    # LCD panel
    s.text6(14 * 8, 0, "SOURCE", YELLOW, BLUE)
    s.text6(21 * 8, 0, "RATE", YELLOW, BLUE)
    s.text6(28 * 8, 0, "MODE", YELLOW, BLUE)
    s.fill(14, 1, 18, 10, BLK)
    s.text6(15 * 8, 2, "AUTO PLAY MODE", GREEN, BLK)
    s.text6(28 * 8, 2, "STOP", CYAN, BLK)
    s.text6(15 * 8, 3, "SONG  : SYNTH WAVE 1", GREEN, BLK)
    s.text6(15 * 8, 4, "ARTIST: MSX CLUB", GREEN, BLK)
    s.text6(16 * 8, 6, "MIN", CYAN, BLK)
    s.text6(21 * 8, 6, "SEC", CYAN, BLK)
    s.text6(26 * 8, 6, "MSEC", CYAN, BLK)
    big_time(s, 15, 7, "03", RED, BLK)
    big_time(s, 20, 7, "27", RED, BLK)
    big_time(s, 25, 7, "120", RED, BLK)
    # equalizer matrix (the spectrum, as slider strips with a knob at the level)
    for i in range(32):
        s.tile(i, 12, ICONS['hline'], CYAN, BLUE)
    s.fill(1, 13, 18, 10, BLK)
    s.text6(1 * 8 + 4, 13, "EQUALIZER MATRIX", WHITE, BLK)
    s.text6(15 * 8, 13, "128K", WHITE, BLK)
    vals = spectrum_values(8, 1.0)
    for b in range(8):
        x = 2 + b * 2
        h = 7
        lit = int(vals[b] * h * 8)
        for t in range(h):
            pat, fg = [], []
            for r in range(8):
                py = t * 8 + r
                from_bottom = h * 8 - 1 - py
                pat.append(0x7E if py % 2 == 0 else 0x42)
                fg.append(BLUE if from_bottom < lit else GREY)
            s.tile(x, 14 + t, pat, fg, BLK)
        ky = 14 * 8 + (h * 8 - lit) - 4
        s.sprite(x * 8 - 4, ky, ["................"] * 3 + ["....########...."] * 4 + ["................"] * 9, [CYAN])
        s.text6(x * 8 + 1, 21, "0%d" % (b + 1), WHITE, BLK)
    # track list
    s.fill(20, 13, 11, 10, BLK)
    s.text6(20 * 8 + 2, 13, "TRACK LIST", WHITE, BLK)
    for i in range(11):
        s.tile(20 + i, 14, ICONS['hline'], GREY, BLK)
    for i, n in enumerate(("11 SYNTH WAVE 1", "12 CYBER BASS", "13 NEON PIANO", "14 RETRO RHYTHM", "15 8BIT GROOVE", "16 MOONLIGHT")):
        sel = i == 0
        if sel:
            s.fill(20, 15 + i, 11, 1, GREEN)
        s.text6(20 * 8 + 2, 15 + i, n[:14], BLK if sel else GREEN, GREEN if sel else BLK)
    # bottom: VU strips where the piano was
    s.text6(1 * 8 + 1, 23, "L", WHITE, BLUE)
    vu = lambda a, n: GREEN if a / n < 0.6 else YELLOW if a / n < 0.85 else RED
    hmeter(s, 2, 23, 13, 0.72, vu, BLUE, GREY_D)
    s.text6(16 * 8 + 1, 23, "R", WHITE, BLUE)
    hmeter(s, 17, 23, 14, 0.64, vu, BLUE, GREY_D)
    return s

if __name__ == '__main__':
    load_font(sys.argv[1])
    out = sys.argv[2]
    a = mock_a()
    a.render(MSX2_PAL).save(out + '/a_msx2_mubscope_winamp.png')
    a.render(TMS_PAL, msx1=True).save(out + '/b_msx1_mubscope_winamp.png')
    mock_c().render(MSX2_PAL).save(out + '/c_msx2_synthesaurus.png')
    print('written to', out)
