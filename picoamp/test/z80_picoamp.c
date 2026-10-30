// Runs PICOAMP.COM in a Z80 emulator against the real PicoVerse Audio Engine
// (host build), with just enough MSX around it: BDOS (console, keys), BIOS
// RDSLT/WRSLT/ENASLT/CALSLT, page 1 switched to the engine (slot 1-3), JIFFY and
// the VDP's VRAM writes (kept, and saved for a picture of the screen), the
// frame interrupt at 60 Hz. Engine time follows the Z80 clock (3.58 MHz).
//
// usage: z80_picoamp PICOAMP.COM image "args" "keys" seconds vram.bin
//   keys: one character per half second; '{' up '}' down '<' left '>' right,
//   '^' Enter, '_' Backspace, '.' nothing, others as they are
//
// A mouse in port 1 (optional): PICOAMP_MOUSE="t:x,y,b;t:x,y,b;..." - from t
// seconds on the pointer goes to (x, y) (screen pixels, it starts at 128, 96)
// with buttons b held (1 left, 2 right, 3 both). The harness answers GTPAD
// as the BIOS does (+ is right / down; the BIOS turns the mouse's own
// offsets round).
//
// It prints how long each main loop pass took (frames) and how long the
// program took to answer the keys.

#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdbool.h>
#include "z80.h"
#include "ff.h"

void pva_init(uint8_t *arena, size_t arena_size);
size_t pva_arena_free(void);
uint8_t pva_mem_read(uint16_t addr);
void pva_mem_write(uint16_t addr, uint8_t data);
void pva_core1_init(void);
void pva_allow_card_writes(bool on);
bool pva_core1_poll(void);
int  host_disk_open(const char *path, uint32_t create_sectors);
void host_advance_ms(uint32_t ms);
int  host_esp_load_audio(const char *mp3_path);
extern bool host_audio_unlimited;
extern uint32_t host_audio_frames, host_audio_underruns;

#define HZ      3580000UL
#define CYC_MS  3580
#define ENGINE  0x8D

static uint8_t mem[65536];
static unsigned long prof[65536], prof_next;       // PC samples (PICOAMP_PROF)
static int prof_on;
static unsigned long rd_ram, wr_ram, busy_cyc;
static uint16_t cnt_addr[16]; static unsigned long cnt_n[16]; static int cnt_k;   // PICOAMP_COUNT                // the Z80's RAM traffic
static uint8_t vram[0x4000];
static uint16_t vaddr;
static bool vlatch;
static uint8_t vfirst;
static uint8_t page1 = 0x00;
static uint8_t pal[32], pal_i, pal_hi;      // the palette (R#16, port 9Ah)
static uint8_t vregs[64] = { 0x04, 0x60, 0x06, 0x80, 0x00, 0x36, 0x07, 0x0E, 0x08 };   // VDP registers (SCREEN 4 to start with)
static int pal_set;
static z80 cpu;
static unsigned long next_ms_cyc, next_frame_cyc;
static const char *keys;
static unsigned long next_key_cyc;
static unsigned long frames, halts, last_halt_frame, worst_gap;
static unsigned long key_frame, answered = 1;
static unsigned long vwrites;

// the mouse
static struct { double t; int x, y, b; } mev[64];
static int mev_n, mev_i;
static int m_x = 128, m_y = 96, m_tx = 128, m_ty = 96, m_b;
static int m_dx, m_dy;
static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }
static void mouse_script(const char *s)
{
    while (s && *s && mev_n < 64)
    {
        double t; int x, y, b, n;
        if (sscanf(s, "%lf:%d,%d,%d%n", &t, &x, &y, &b, &n) != 4) break;
        mev[mev_n].t = t; mev[mev_n].x = x; mev[mev_n].y = y; mev[mev_n].b = b;
        mev_n++;
        s += n;
        if (*s == ';') s++;
    }
}

static void sync_engine(void)
{
    while (cpu.cyc >= next_ms_cyc) { pva_core1_poll(); host_advance_ms(1); next_ms_cyc += CYC_MS; }
}

static int trace = -1, tr_code;
static uint8_t tr_args[4];
static void eng_wr(uint16_t a, uint8_t v)
{
    if (trace < 0) trace = getenv("PICOAMP_TRACE") != NULL;
    if (a >= 0x4100 && a < 0x4104) tr_args[a - 0x4100] = v;
    if (a == 0x4011) tr_code = v;
    pva_mem_write(a, v);
}
static uint8_t eng_rd(uint16_t a)
{
    uint8_t v = pva_mem_read(a);
    if (trace > 0 && a == 0x4013 && tr_code != 0x11 && tr_code != 0x13)
        fprintf(stderr, "[%.2f s] cmd %02X args %02X %02X %02X -> %02X\n", cpu.cyc / 3579545.0, tr_code, tr_args[0], tr_args[1], tr_args[2], v);
    return v;
}
static int rom_mode;
static uint16_t pc_ring[1024];
static unsigned pc_ri;
static int pc_warned;
static uint16_t pc_last, jmp_from[32], jmp_to[32];
static unsigned jmp_i;            // PICOAMP.ROM: at 4000h, started at its INIT, BIOS keys
static uint8_t romimg[65536];   // its 16 KB banks (6000h selects the one in page 1, as ASCII16)
static int rom_bank;
// the MSX2 clock chip (RP5C01, ports B4h/B5h), block 0: running from PICOAMP_RTC
// ("YYYY-MM-DD HH:MM:SS") or 2026-10-29 21:00:00
static uint8_t rtc_reg, rtc_mode;
static long long rtc_base = -1;
static uint8_t rtc_read(void)
{
    if (rtc_reg == 13) return rtc_mode;
    if ((rtc_mode & 3) != 0 || rtc_reg > 12) return 0x0F;
    if (rtc_base < 0)
    {
        int Y = 2026, M = 10, D = 29, h = 21, m = 0, sec = 0;
        const char *e = getenv("PICOAMP_RTC");
        if (e) sscanf(e, "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &sec);
        struct tm t = { 0 };
        t.tm_year = Y - 1900; t.tm_mon = M - 1; t.tm_mday = D; t.tm_hour = h; t.tm_min = m; t.tm_sec = sec;
        rtc_base = (long long)timegm(&t);
    }
    time_t now = (time_t)(rtc_base + (long long)(cpu.cyc / 3579545u));
    struct tm g;
    gmtime_r(&now, &g);
    int v[13] = { g.tm_sec % 10, g.tm_sec / 10, g.tm_min % 10, g.tm_min / 10, g.tm_hour % 10, g.tm_hour / 10, g.tm_wday,
                  g.tm_mday % 10, g.tm_mday / 10, (g.tm_mon + 1) % 10, (g.tm_mon + 1) / 10, (g.tm_year - 80) % 10, (g.tm_year - 80) / 10 % 10 };
    return (uint8_t)v[rtc_reg];
}
static uint8_t rd(void *u, uint16_t a)
{
    (void)u;
    if (page1 == ENGINE && a >= 0x4000 && a < 0x8000) { sync_engine(); return eng_rd(a); }
    rd_ram++;
    return mem[a];
}
static void wr(void *u, uint16_t a, uint8_t v)
{
    (void)u;
    if (page1 == ENGINE && a >= 0x4000 && a < 0x8000) { sync_engine(); eng_wr(a, v); return; }
    if (rom_mode && a >= 0x4000 && a < 0x8000)
    {
        // the cartridge ROM: a write to 6000h-67FFh selects its bank
        if ((a & 0xF800) == 0x6000 && (v & 3) != rom_bank) { rom_bank = v & 3; memcpy(&mem[0x4000], &romimg[rom_bank * 0x4000], 0x4000); }
        return;
    }
    wr_ram++;
    { static int w = -2; if (w == -2) { const char *e = getenv("PICOAMP_WATCH"); w = e ? (int)strtol(e, NULL, 16) : -1; }
      if (w >= 0 && a == w) fprintf(stderr, "[write %02X to %04X at PC %04X, page 1 %02X, HL %04X]\n", v, a, cpu.pc, page1, (unsigned)(cpu.h << 8 | cpu.l)); }
    if (a >= 0x100) mem[a] = v;
}
static uint8_t pin(z80 *z, uint8_t p) { (void)z; if (p == 0x99) vlatch = false; if (p == 0xB5) return rtc_read(); return 0; }
static void pout(z80 *z, uint8_t p, uint8_t v)
{
    (void)z;
    if (p == 0xB4) { rtc_reg = v & 15; return; }
    if (p == 0xB5) { if (rtc_reg == 13) rtc_mode = v & 15; return; }
    if (p == 0x98) { vram[vaddr & 0x3FFF] = v; vaddr++; vwrites++; vlatch = false; }
    else if (p == 0x9A)
    {
        pal[pal_i * 2 + pal_hi] = v;
        pal_set = 1;
        if (pal_hi) pal_i = (pal_i + 1) & 15;
        pal_hi ^= 1;
    }
    else if (p == 0x99)
    {
        if (!vlatch) { vfirst = v; vlatch = true; }
        else
        {
            vlatch = false;
            if (!(v & 0x80)) vaddr = (uint16_t)(vfirst | ((v & 0x3F) << 8));
            else { vregs[v & 0x3F] = vfirst; if ((v & 0x3F) == 16) { pal_i = vfirst & 15; pal_hi = 0; } }
        }
    }
}

static uint8_t font[2048];
static void load_font(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256];
    int n = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f) && n < 256)
    {
        char *p = strstr(line, "db");
        if (!p || strchr(line, ';') < p) continue;
        p += 2;
        for (int i = 0; i < 8; i++)
        {
            while (*p && *p != '$') p++;
            if (!*p) break;
            font[n * 8 + i] = (uint8_t)strtol(p + 1, &p, 16);
        }
        n++;
    }
    fclose(f);
}

// MSX-DOS 2 file handles on the card image (through the engine's FatFs)
static FIL fh[4];
static int fh_used[4];
static void dos_path(uint16_t p, char *out, size_t n)
{
    char t[128]; int i = 0;
    while (mem[p] && i < 127) t[i++] = (char)mem[p++];
    t[i] = 0;
    const char *q = t;
    if (q[0] && q[1] == ':') q += 2;
    snprintf(out, n, "0:%s", q);
    for (char *c = out; *c; c++) if (*c == '\\') *c = '/';
}

static uint8_t key_code(char k);
static uint8_t pending_key;
static uint8_t take_key(void)   // the next key of the script when it is due, else 0
{
    uint8_t k = 0;
    if (keys && *keys && cpu.cyc >= next_key_cyc)
    {
        k = key_code(*keys++);
        next_key_cyc = cpu.cyc + HZ / 2;
        if (k) { key_frame = frames; answered = 0; }
    }
    return k;
}

static void ret(void) { cpu.pc = mem[cpu.sp] | (mem[cpu.sp + 1] << 8); cpu.sp += 2; }

static uint8_t key_code(char k)
{
    switch (k)
    {
        case '{': return 30;
        case '}': return 31;
        case '<': return 29;
        case '>': return 28;
        case '^': return 13;
        case '_': return 8;
        case '.': return 0;
    }
    return (uint8_t)k;
}

static int run(unsigned long max_cyc)
{
    while (cpu.cyc < max_cyc)
    {
        sync_engine();
        if (cpu.cyc >= next_frame_cyc)
        {
            next_frame_cyc += HZ / 60;
            frames++;
            uint16_t j = mem[0xFC9E] | (mem[0xFC9F] << 8);
            j++;
            mem[0xFC9E] = (uint8_t)j; mem[0xFC9F] = (uint8_t)(j >> 8);
            if (cpu.iff1) cpu.halted = false;
        }
        if (cpu.halted) { cpu.cyc += 4; busy_cyc += 4; continue; }
        if (!rom_mode && ((cpu.pc >= 0x4000 && cpu.pc < 0x9698) || cpu.pc >= 0xA600) && getenv("PICOAMP_CRASH") && !pc_warned)
        {
            pc_warned = 1;
            fprintf(stderr, "[jumps:");
            for (int k = 0; k < 32; k++) fprintf(stderr, " %04X>%04X", jmp_from[(jmp_i + k) & 31], jmp_to[(jmp_i + k) & 31]);
            fprintf(stderr, "]\n");
            fprintf(stderr, "[code run in page 1 at %04X, SP %04X; before:", cpu.pc, cpu.sp);
            for (int k = 0; k < 1024; k++) { uint16_t q = pc_ring[(pc_ri + k) & 1023]; if (q < 0xA0D5) fprintf(stderr, " %04X", q); }
            fprintf(stderr, "]\n");
        }
        if (cpu.pc < pc_last || cpu.pc > pc_last + 4u) { jmp_from[jmp_i & 31] = pc_last; jmp_to[jmp_i & 31] = cpu.pc; jmp_i++; }
        pc_last = cpu.pc;
        pc_ring[pc_ri++ & 1023] = cpu.pc;
        switch (cpu.pc)
        {
            case 0x0000:
                if (getenv("PICOAMP_CRASH"))
                {
                    fprintf(stderr, "[ended at 0: the last PCs, SP %04X]", cpu.sp);
                    for (int k = 0; k < 1024; k++) { uint16_t q = pc_ring[(pc_ri + k) & 1023]; if (q < 0xA0D5) fprintf(stderr, " %04X", q); }
                    fprintf(stderr, "\n");
                }
                return 0;
            case 0x0005:
                switch (cpu.c)
                {
                    case 0x00: return 0;
                    case 0x02: putchar(cpu.e); break;
                    case 0x09: { uint16_t p = (uint16_t)(cpu.d << 8 | cpu.e); while (mem[p] != '$') putchar(mem[p++]); break; }
                    case 0x06:
                        cpu.a = take_key();
                        cpu.l = cpu.a;
                        break;
                    case 0x43: case 0x44:   // _OPEN / _CREATE: DE = path -> B = handle
                    {
                        char path[160]; int h;
                        dos_path((uint16_t)(cpu.d << 8 | cpu.e), path, sizeof path);
                        for (h = 0; h < 4 && fh_used[h]; h++) ;
                        BYTE mode = cpu.c == 0x44 ? (FA_CREATE_ALWAYS | FA_WRITE | FA_READ) : (FA_READ | FA_WRITE);
                        if (h == 4 || f_open(&fh[h], path, mode) != FR_OK) { cpu.a = 0xD7; break; }    // .NOFIL
                        fh_used[h] = 1; cpu.b = (uint8_t)h; cpu.a = 0;
                        printf("  [DOS %s %s]\n", cpu.c == 0x44 ? "create" : "open", path);
                        break;
                    }
                    case 0x45:                  // _CLOSE
                        if (cpu.b < 4 && fh_used[cpu.b]) { f_close(&fh[cpu.b]); fh_used[cpu.b] = 0; }
                        cpu.a = 0;
                        break;
                    case 0x48: case 0x49:       // _READ / _WRITE: B, DE = buffer, HL = bytes
                    {
                        UINT n = 0, want = (UINT)(cpu.h << 8 | cpu.l);
                        uint16_t d = (uint16_t)(cpu.d << 8 | cpu.e);
                        static uint8_t tmp[65536];
                        if (cpu.b >= 4 || !fh_used[cpu.b]) { cpu.a = 0xC2; break; }
                        if (cpu.c == 0x48) { f_read(&fh[cpu.b], tmp, want, &n); memcpy(&mem[d], tmp, n); cpu.a = n ? 0 : 0xC7; }
                        else { memcpy(tmp, &mem[d], want); f_write(&fh[cpu.b], tmp, want, &n); cpu.a = n == want ? 0 : 0xC1; }
                        cpu.h = (uint8_t)(n >> 8); cpu.l = (uint8_t)n;
                        break;
                    }
                    case 0x6B:                  // _GENV: PROGRAM
                    {
                        const char *v = "A:\\PICOAMP.COM";
                        uint16_t d = (uint16_t)(cpu.d << 8 | cpu.e);
                        memcpy(&mem[d], v, strlen(v) + 1);
                        cpu.a = 0;
                        break;
                    }
                    default: printf("[BDOS %02X]\n", cpu.c);
                }
                ret();
                cpu.cyc += 300;
                continue;
            case 0x009C:                // CHSNS (the ROM): ZF=1 no key
                if (!rom_mode) break;
                if (!pending_key) pending_key = take_key();
                cpu.zf = pending_key == 0;
                ret();
                cpu.cyc += 200;
                continue;
            case 0x009F:                // CHGET
                if (!rom_mode) break;
                cpu.a = pending_key;
                pending_key = 0;
                ret();
                cpu.cyc += 300;
                continue;
            case 0x00A2:                // CHPUT
                if (!rom_mode) break;
                putchar(cpu.a);
                ret();
                continue;
            case 0x000C:                // RDSLT
            {
                uint16_t a = (uint16_t)(cpu.h << 8 | cpu.l);
                if (cpu.a == ENGINE) { sync_engine(); cpu.a = eng_rd(a); }
                else if (a == 0x0004) cpu.a = 0x00;          // CGTABL -> 3000h (fake ROM)
                else if (a == 0x0005) cpu.a = 0x30;
                else if (a >= 0x3000 && a < 0x3800) cpu.a = font[a - 0x3000];
                else if (a == 0x002B) cpu.a = 0x00;          // 60 Hz
                else cpu.a = 0xFF;
                cpu.iff1 = cpu.iff2 = false;
                ret();
                cpu.cyc += 150;
                continue;
            }
            case 0x0014:                // WRSLT
                if (cpu.a == ENGINE) { sync_engine(); eng_wr((uint16_t)(cpu.h << 8 | cpu.l), cpu.e); }
                cpu.iff1 = cpu.iff2 = false;
                ret();
                cpu.cyc += 150;
                continue;
            case 0x001C:                // CALSLT: the mouse BIOS calls; CHGMOD etc. do nothing here
            {
                double now = cpu.cyc / (double)HZ;
                while (mev_i < mev_n && mev[mev_i].t <= now)
                {
                    m_tx = mev[mev_i].x; m_ty = mev[mev_i].y; m_b = mev[mev_i].b;
                    mev_i++;
                }
                if (cpu.ix == 0x00DB && mev_n)          // GTPAD
                {
                    if (cpu.a == 12)
                    {
                        // move towards the target, at most 12 pixels a read
                        int dx = clampi(m_tx - m_x, -12, 12), dy = clampi(m_ty - m_y, -12, 12);
                        m_x += dx; m_y += dy;
                        m_dx = dx; m_dy = dy;     // GTPAD: + is right / down
                        cpu.a = 0xFF;
                    }
                    else if (cpu.a == 13) cpu.a = (uint8_t)m_dx;
                    else if (cpu.a == 14) cpu.a = (uint8_t)m_dy;
                    else cpu.a = 0xFF;                  // port 2: nothing
                    cpu.cyc += 3000;
                }
                else if (cpu.ix == 0x00DB) { cpu.a = 0xFF; cpu.cyc += 3000; }
                else if (cpu.ix == 0x005F && cpu.a == 4)   // CHGMOD 4: SCREEN 4's registers
                {
                    static const uint8_t s4[10] = { 0x04, 0x60, 0x06, 0x80, 0x00, 0x36, 0x07, 0x0E, 0x08, 0x00 };
                    memcpy(vregs, s4, sizeof s4);
                    vregs[10] = vregs[11] = 0;
                    cpu.cyc += 20000;
                }
                else if (cpu.ix == 0x00D8)              // GTTRIG
                {
                    cpu.a = ((cpu.a == 1 && (m_b & 1)) || (cpu.a == 3 && (m_b & 2))) ? 0xFF : 0;
                    cpu.cyc += 300;
                }
                else cpu.cyc += 2000;
                ret();
                continue;
            }
            case 0x0024:                // ENASLT A = slot, H = page
                if ((cpu.h & 0xC0) == 0x40) page1 = cpu.a;
                cpu.iff1 = cpu.iff2 = false;
                ret();
                cpu.cyc += 400;
                continue;
        }
        for (int k = 0; k < cnt_k; k++) if (cpu.pc == cnt_addr[k]) cnt_n[k]++;
        if (prof_on && cpu.cyc >= prof_next) { prof[cpu.pc]++; prof_next = cpu.cyc + 97; }
        if (mem[cpu.pc] == 0x76)    // HALT: a main loop pass ended
        {
            unsigned long gap = frames - last_halt_frame;
            if (halts > 10 && gap > worst_gap) worst_gap = gap;
            last_halt_frame = frames;
            halts++;
            if (!answered)
            {
                answered = 1;
                printf("  key answered after %lu frame(s)\n", frames - key_frame);
            }
        }
        z80_step(&cpu);
    }
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 7) { printf("usage: z80_picoamp PICOAMP.COM image args keys seconds vram.bin [font.asm]\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    size_t al1 = strlen(argv[1]);
    rom_mode = al1 > 4 && !strcasecmp(argv[1] + al1 - 4, ".ROM");
    size_t n = rom_mode ? fread(romimg, 1, sizeof romimg, f) : fread(&mem[0x100], 1, 0xD000, f);
    if (rom_mode) memcpy(&mem[0x4000], romimg, 0x4000);
    fclose(f);
    if (argc > 7) load_font(argv[7]);
    if (host_disk_open(argv[2], 0)) { printf("no image\n"); return 2; }
    static uint8_t arena[200 * 1024];
    host_audio_unlimited = false;
    {   // the simulated radio stations' sound (PICOAMP_MP3, else assets/cbr128_v23.mp3)
        const char *mp3 = getenv("PICOAMP_MP3");
        host_esp_load_audio(mp3 ? mp3 : "assets/cbr128_v23.mp3");
    }
    pva_init(arena, rom_mode ? sizeof arena : 120u * 1024u);   // as the firmware: PicoAmp ~200 KB, Nextor modes 120 KB
    if (rom_mode) pva_allow_card_writes(true);  // as the PicoAmp firmware: no Nextor
    pva_core1_init();
    const char *a = argv[3];
    keys = argv[4];
    mouse_script(getenv("PICOAMP_MOUSE"));
    prof_on = getenv("PICOAMP_PROF") != NULL;
    { const char *c = getenv("PICOAMP_COUNT"); int n;
      while (c && *c && cnt_k < 16 && sscanf(c, "%hx%n", &cnt_addr[cnt_k], &n) == 1) { cnt_k++; c += n; if (*c == ',') c++; } }
    size_t al = strlen(a);
    mem[0x80] = (uint8_t)(al ? al + 1 : 0);
    mem[0x81] = ' ';
    memcpy(&mem[0x82], a, al);
    memset(&mem[0xFCC1], 0, 4);
    mem[0xFCC1 + 1] = 0x80;
    mem[0xFCC1 + 3] = 0x80;
    mem[0xF342] = 0x00;             // RAMAD1 (not the engine)
    mem[0x0006] = 0x00; mem[0x0007] = 0xF0;     // top of the TPA
    z80_init(&cpu);
    cpu.read_byte = rd; cpu.write_byte = wr; cpu.port_in = pin; cpu.port_out = pout;
    cpu.pc = 0x100;
    cpu.sp = 0xF000;
    mem[0xF000] = 0; mem[0xF001] = 0;
    if (rom_mode)                   // the BIOS calls INIT (4002h) with the stack high up
    {
        cpu.pc = (uint16_t)(mem[0x4002] | mem[0x4003] << 8);
        cpu.sp = 0xF37E;
        mem[0xF37E] = 0; mem[0xF37F] = 0;
    }
    next_ms_cyc = CYC_MS;
    next_frame_cyc = HZ / 60;
    next_key_cyc = HZ * 3;
    printf("loaded %zu bytes\n", n);
    int r = run(HZ * (unsigned long)atoi(argv[5]));
    printf("[%s after %.1f s: %lu frames, %lu loop passes (%.1f frames each), worst %lu frames, %lu VRAM bytes, %u audio underruns]\n",
           r ? "time up" : "exit", cpu.cyc / (double)HZ, frames, halts, halts ? (double)frames / halts : 0.0, worst_gap, vwrites,
           host_audio_underruns);
    printf("[RAM: %.0f reads, %.0f writes a second; busy %.0f%% (not in HALT)]\n",
           rd_ram / (cpu.cyc / (double)HZ), wr_ram / (cpu.cyc / (double)HZ), 100.0 - 100.0 * busy_cyc / cpu.cyc);
    if (trace > 0) printf("[engine arena: %zu bytes free]\n", pva_arena_free());
    for (int k = 0; k < cnt_k; k++) printf("[%04X entered %lu times]\n", cnt_addr[k], cnt_n[k]);
    if (prof_on)
    {
        FILE *pf = fopen(getenv("PICOAMP_PROF"), "w");
        for (int i = 0; i < 65536; i++) if (prof[i]) fprintf(pf, "%04X %lu\n", i, prof[i]);
        fclose(pf);
    }
    {
        const char *d = getenv("PICOAMP_DUMP");     // "addr,len;addr,len" (hex)
        while (d && *d)
        {
            unsigned a, l; int n;
            if (sscanf(d, "%x,%x%n", &a, &l, &n) != 2) break;
            printf("[%04X]", a);
            for (unsigned i = 0; i < l; i++) printf(" %02X", mem[(a + i) & 0xFFFF]);
            printf("\n");
            d += n;
            if (*d == ';') d++;
        }
    }
    f = fopen(argv[6], "wb");
    fwrite(vram, 1, sizeof vram, f);
    fwrite(pal, 1, sizeof pal, f);                  // the palette after VRAM, then the VDP registers
    fwrite(vregs, 1, sizeof vregs, f);
    fclose(f);
    return 0;
}
