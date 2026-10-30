#!/usr/bin/env python3
# Mock-ups for the news reader, drawn under the VDP's rules.
#   A: TEXT 2 (SCREEN 0, WIDTH 80): 80 x 26 characters of 6 x 8, one text colour
#      pair for the screen and a second pair ("blink" colours) for any cell.
#   B: SCREEN 4 as PICOAMP uses it: 6-pixel text, 42 x 24, colours per 8-pixel
#      tile row.
#   news_mockup.py <c-bios font_us.asm> <out dir>
import re, sys, textwrap
from PIL import Image

FONT = {}
def load_font(path):
    n = 0
    for line in open(path):
        m = re.match(r'\s*db\s+(.*?)\s*;', line)
        if m:
            FONT[n] = [int(v.strip().lstrip('$'), 16) for v in m.group(1).split(',')]
            n += 1

def p3(r, g, b):
    return (r * 255 // 7, g * 255 // 7, b * 255 // 7)

H, V, TL, TR, BL, BR, TD, TU = 0x17, 0x16, 0x18, 0x19, 0x1A, 0x1B, 0x12, 0x11
NOTE = 0x0E

# ---------------------------------------------------------------- A: TEXT 2
class Text2:
    COLS, ROWS = 80, 26
    def __init__(self, fg, bg, bfg, bbg):
        self.ch = [[32] * self.COLS for _ in range(self.ROWS)]
        self.bl = [[False] * self.COLS for _ in range(self.ROWS)]
        self.fg, self.bg, self.bfg, self.bbg = fg, bg, bfg, bbg
    def put(self, x, y, s, blink=False):
        for i, c in enumerate(s):
            if 0 <= x + i < self.COLS and 0 <= y < self.ROWS:
                self.ch[y][x + i] = c if isinstance(c, int) else ord(c)
                self.bl[y][x + i] = blink
    def bar(self, x, y, w):
        for i in range(w):
            self.bl[y][x + i] = True
    def hline(self, y, l=TD, r=TD):
        self.put(0, y, [H] * 80)
    def image(self):
        im = Image.new('RGB', (512, 212), self.bg)
        px = im.load()
        for y in range(self.ROWS):
            for x in range(self.COLS):
                g = FONT[self.ch[y][x]]
                f, b = (self.bfg, self.bbg) if self.bl[y][x] else (self.fg, self.bg)
                for r in range(8):
                    Y = y * 8 + r
                    if Y >= 212:
                        continue
                    for c in range(6):
                        px[16 + x * 6 + c, Y] = f if (g[r] >> (7 - c)) & 1 else b
        return im.resize((1024, 848), Image.NEAREST)

def fit(s, w):
    return s if len(s) <= w else s[:w - 3] + '...'

HEAD = [
    ("09:52", "Storm brings strong winds and heavy rain to the north coast overnight"),
    ("09:41", "Scientists find water ice under the surface near the moon's south pole"),
    ("09:30", "Central bank keeps interest rates unchanged and points to slower growth ahead"),
    ("09:18", "City council approves plan for new tram line through the old harbour district"),
    ("09:02", "Football: late penalty decides the cup quarter-final after extra time"),
    ("08:47", "Museum reopens after five years of restoration with a new wing for photography"),
    ("08:33", "New study: walking ten minutes after meals lowers blood sugar peaks"),
    ("08:20", "Railway strike called off after agreement on pay and working hours"),
    ("08:05", "Electric ferry starts service between the islands, cutting travel time by half"),
    ("07:51", "Record number of visitors at the autumn book fair, organisers say"),
    ("07:39", "Space telescope sends first images of a comet passing the outer planets"),
    ("07:22", "Farmers expect a smaller apple harvest after a dry summer"),
    ("07:10", "Tech company recalls chargers that can overheat; customers can swap them"),
    ("06:58", "Orchestra plays a concert of 1980s computer game music to a full hall"),
    ("06:41", "Snow expected in the mountains this weekend, first of the season"),
    ("06:30", "Bridge closed for two nights for maintenance; diversions in place"),
    ("06:12", "Researchers restore a 40-year-old home computer's lost software from tapes"),
]
SUMMARY = ("Gusts of up to 110 km/h are expected along the coast from late evening, the weather "
           "service said. Ferries between the islands may be cancelled and people are asked to "
           "secure garden furniture. The rain moves inland in the morning.")
ARTICLE = ("Gusts of up to 110 km/h are expected along the coast from late evening, the weather "
           "service said on Friday. Ferries between the islands may be cancelled and people are "
           "asked to secure garden furniture and to avoid the dunes.\n"
           "The storm, the first of the autumn, formed over the ocean on Wednesday and has "
           "strengthened since. It is expected to reach the coast around 22:00 and to move "
           "inland during the night, bringing between 30 and 50 millimetres of rain.\n"
           "\"We advise everyone near the coast to stay indoors tonight,\" a spokesperson for "
           "the emergency services said. \"Check on your neighbours, and keep a torch and a "
           "charged phone at hand.\"\n"
           "The railway company said trains would run at a lower speed on the coastal line, "
           "and some services after 21:00 may be replaced by buses. Schools in the area will "
           "open as usual on Monday.\n"
           "Wind and rain will ease on Saturday afternoon, with sunny spells and temperatures "
           "of around 12 degrees. A second, weaker front is expected on Tuesday.")

def wrap(t, w):
    out = []
    for p in t.split('\n'):
        out += textwrap.wrap(p, w) + ['']
    return out[:-1]

def top_rows(s, page):
    s.put(0, 0, [NOTE] + list(" Cafe del Mar - Sine Cafe Song  " + chr(0x07) + "  NPO Radio 2 Soul & Jazz"))
    s.put(80 - 16, 0, "Fri 30 Oct 09:53")
    s.put(0, 1, page)

def mock_a_list():
    s = Text2(p3(7, 7, 7), p3(0, 0, 2), p3(0, 0, 0), p3(3, 6, 7))
    top_rows(s, "")
    s.put(0, 1, " BBC World", True); s.bar(0, 1, 80)
    s.put(56, 1, "Headlines 1-17 of 38", True)
    for i, (t, h) in enumerate(HEAD):
        s.put(1, 2 + i, t)
        s.put(8, 2 + i, fit(h, 70))
    s.bar(0, 3, 80)
    for y in range(2, 19):
        s.put(79, y, [0xDB] if y < 6 else [0x16])
    s.hline(19)
    for i, l in enumerate(wrap(SUMMARY, 78)[:3]):
        s.put(1, 20 + i, l)
    s.hline(23)
    s.put(0, 24, " Enter read   Up/Down choose   </> page   F feeds   + add   R reload   ESC back")
    s.put(0, 25, " C clock  W weather   playback keys work as always")
    return s.image()

def mock_a_story():
    s = Text2(p3(7, 7, 7), p3(0, 0, 2), p3(0, 0, 0), p3(7, 7, 1))
    top_rows(s, "")
    s.put(0, 1, " BBC World " + chr(0x16) + " 2 of 38", True); s.bar(0, 1, 80)
    s.put(57, 1, "Fri 30 Oct 2026 09:41", True)
    s.put(1, 2, "Storm brings strong winds and heavy rain to the north coast overnight")
    s.put(1, 3, [H] * 78)
    lines = wrap(ARTICLE, 77)
    for i, l in enumerate(lines[:19]):
        s.put(1, 4 + i, l)
    for y in range(4, 23):
        s.put(79, y, [0xDB] if y < 11 else [0x16])
    s.put(0, 23, " Full article, 4.2 KB" + " " * 42 + "lines 1-19 of 26", True); s.bar(0, 23, 80)
    s.put(0, 24, " Up/Down scroll   </> page   N/P next/previous story   S summary only   ESC list")
    s.put(0, 25, " C clock  W weather")
    return s.image()

def mock_a_feeds():
    s = Text2(p3(7, 7, 7), p3(0, 0, 2), p3(0, 0, 0), p3(3, 6, 7))
    top_rows(s, "")
    s.put(0, 1, " My feeds", True); s.bar(0, 1, 80)
    s.put(40, 1, " Add a feed: World news", True)
    favs = ["BBC World", "NOS (NL)", "The Guardian World", "DW (English)", "Ars Technica",
            "Hackaday", "MSX Resource Center", "Tweakers", "NASA news releases", "BBC Sport Football"]
    for i, f in enumerate(favs):
        s.put(2, 3 + i, f)
    s.bar(1, 4, 37)
    s.put(2, 3 + len(favs) + 1, "D remove   U/J move up/down")
    for y in range(2, 23):
        s.put(39, y, [0x16])
    cat = [("  BBC News, top stories", ""), ("* BBC World", ""), ("  Sky News, World", ""),
           ("  The New York Times, World", ""), ("* The Guardian, World", ""), ("  Al Jazeera English", ""),
           ("  NPR News", ""), ("  France 24 (English)", ""), ("* DW (English)", ""),
           ("  CBC News", ""), ("  ABC News (Australia)", ""), ("  South China Morning Post", ""),
           ("  The Times of India", ""), ("  Euronews", ""), ("  Google News, World", "")]
    for i, (n, _) in enumerate(cat):
        s.put(41, 3 + i, n)
    s.bar(40, 8, 39)
    s.put(41, 19, "Topics: World Europe NL DE US Business")
    s.put(41, 20, "        Tech Science Sports Games Retro")
    s.put(41, 21, "T next topic  Enter add  * = added")
    s.put(0, 23, [H] * 80)
    s.put(0, 24, " Tab/Left/Right switch side   Enter open the feed / add it   ESC back")
    s.put(0, 25, " C clock  W weather")
    return s.image()

# ---------------------------------------------------------------- B: SCREEN 4, 42 columns
NAVY, WHITE, CYAN, YELLOW, BLUE, GREY, GREEN = p3(1, 1, 3), p3(7, 7, 7), p3(3, 6, 7), p3(7, 7, 1), p3(2, 2, 6), p3(4, 4, 5), p3(2, 7, 2)
class Scr4:
    def __init__(self):
        self.im = Image.new('RGB', (256, 192), NAVY)
        self.px = self.im.load()
    def row(self, y, bg):
        for Y in range(y * 8, y * 8 + 8):
            for X in range(256):
                self.px[X, Y] = bg
    def text(self, col, y, s, fg, bg=None):
        for i, ch in enumerate(s):
            g = FONT[ch if isinstance(ch, int) else ord(ch)]
            for r in range(8):
                for c in range(6):
                    X = 1 + (col + i) * 6 + c
                    if X < 256:
                        if (g[r] >> (7 - c)) & 1:
                            self.px[X, y * 8 + r] = fg
                        elif bg:
                            self.px[X, y * 8 + r] = bg
    def image(self):
        return self.im.resize((1024, 768), Image.NEAREST)

def mock_b_list():
    s = Scr4()
    s.text(0, 0, [NOTE] + list(" Cafe del Mar - Sine Cafe Song  " + chr(7) + " N"), WHITE)
    s.row(1, BLUE); s.text(0, 1, "BBC World", YELLOW); s.text(29, 1, "1-14 of 38", WHITE)
    for i, (t, h) in enumerate(HEAD[:14]):
        y = 2 + i
        if i == 1:
            s.row(y, CYAN)
        s.text(0, y, t, CYAN if i != 1 else NAVY)
        s.text(6, y, fit(h, 36), WHITE if i != 1 else NAVY)
    for i, l in enumerate(wrap(SUMMARY, 42)[:4]):
        s.text(0, 17 + i, l, GREY)
    s.text(0, 22, "Enter read  F feeds  + add  ESC back", GREEN)
    s.text(0, 23, "C clock  W weather", GREEN)
    return s.image()

def mock_b_story():
    s = Scr4()
    s.text(0, 0, [NOTE] + list(" Cafe del Mar - Sine Cafe Song  " + chr(7) + " N"), WHITE)
    s.row(1, BLUE); s.text(0, 1, "BBC World", YELLOW); s.text(26, 1, "30 Oct 09:41", WHITE)
    for i, l in enumerate(wrap("Storm brings strong winds and heavy rain to the north coast overnight", 42)[:2]):
        s.text(0, 2 + i, l, YELLOW)
    for i, l in enumerate(wrap(ARTICLE, 41)[:17]):
        s.text(0, 4 + i, l, WHITE)
    s.text(0, 21, "Full article  lines 1-17 of 48", CYAN)
    s.text(0, 22, "Up/Down scroll  N/P story  ESC list", GREEN)
    s.text(0, 23, "C clock  W weather", GREEN)
    return s.image()

if __name__ == '__main__':
    load_font(sys.argv[1])
    out = sys.argv[2]
    mock_a_list().save(out + '/news_a_list.png')
    mock_a_story().save(out + '/news_a_story.png')
    mock_a_feeds().save(out + '/news_a_feeds.png')
    mock_b_list().save(out + '/news_b_list.png')
    mock_b_story().save(out + '/news_b_story.png')
