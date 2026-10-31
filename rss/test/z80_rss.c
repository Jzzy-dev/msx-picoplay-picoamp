// z80_rss.c - runs RSS.COM / RSS.ROM in a Z80 emulator with just enough MSX
# z80_rss: gcc -O2 -o z80_rss z80_rss.c z80.c -I<dir of z80.h> (the z80 core: github.com/superzazu/z80)
// around it: the BIOS calls it makes (RDSLT, CALSLT: CHSNS CHGET INITXT BEEP,
// ENASLT), MSX-DOS / disk BASIC FCB calls (RSS.INI in a folder), the VDP
// (V9938: 128 KB VRAM, registers, R14), the frame interrupt (JIFFY), EXTBIO
// and a TCP/IP UNAPI implementation answering from fixture files.
//
// usage: z80_rss RSS.COM|RSS.ROM fixtures/ inidir/ "keys" seconds out.vram
//   env: RSS_MSX1=1 (an MSX1: TMS9918, 16 KB VRAM), RSS_NOTLS=1 (no TLS),
//        RSS_UNAPI=rom|page3|map (where the implementation is), RSS_RATE (bytes/ms),
//        RSS_NODISK=1, RSS_SHOT="t1,t2,..." (screen dumps at those seconds)
//   keys: one per half second from 4 s: '{' up '}' down '<' left '>' right
//   '^' Enter '_' BS '~' ESC '.' nothing; others as they are
// fixtures/index.txt: "URL file [status [Location]]" lines

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <strings.h>
#include <time.h>
#include "z80.h"

#define HZ 3579545UL
static z80 cpu;
static uint8_t mem[65536];
static uint8_t rom[32768];
static int rom_mode, msx1;
static uint8_t vram[0x20000];
static uint32_t vaddr;
static uint8_t vlatch, vfirst, vregs[64];
static bool vread;
static unsigned long frames, next_frame;
static const char *keys;
static unsigned long next_key;
static uint8_t keybuf[16];
static int keyn;
static const char *fixdir, *inidir;
static int quiet;

// ---------------------------------------------------------------- the fake network
typedef struct { char url[300], file[200]; int status; char loc[300]; } fix_t;
static fix_t fx[64];
static int nfx;
static char hosts[32][64];
static int nhosts;
static int notls;
static int rate = 30;              // bytes per ms (about the ESP-01 at 230 kbps... a little faster)
static unsigned long log_requests;
static char req_log[64][320];

typedef struct {
    bool used, tls, open;
    int state;                      // 2 SYN-SENT, 4 ESTABLISHED, 7 CLOSE-WAIT
    unsigned long t_open;
    char req[2048]; int rl;
    uint8_t *resp; long rlen, rpos, rsent;
    unsigned long t_resp;
    char host[64]; int port;
} conn_t;
static conn_t cn[5];
static int dns_pending; static uint32_t dns_ip; static unsigned long dns_t; static int dns_err;

static unsigned long now_ms(void) { return cpu.cyc / (HZ / 1000); }

static void load_fixtures(void)
{
    char p[512];
    snprintf(p, sizeof p, "%s/index.txt", fixdir);
    FILE *f = fopen(p, "r");
    if (!f) { printf("no %s\n", p); exit(2); }
    char line[1024];
    while (fgets(line, sizeof line, f) && nfx < 64)
    {
        if (line[0] == '#' || line[0] == '\n') continue;
        fix_t *x = &fx[nfx];
        x->status = 200; x->loc[0] = 0;
        int n = sscanf(line, "%299s %199s %d %299s", x->url, x->file, &x->status, x->loc);
        if (n >= 2) nfx++;
    }
    fclose(f);
}

static int host_index(const char *h)
{
    if (!strcmp(h, "proxy.lan")) { for (int i = 0; i < nhosts; i++) if (!strcmp(hosts[i], h)) return i; snprintf(hosts[nhosts], 64, "%s", h); return nhosts++; }
    for (int i = 0; i < nhosts; i++) if (!strcasecmp(hosts[i], h)) return i;
    // known if a fixture has it
    for (int i = 0; i < nfx; i++)
    {
        const char *u = strstr(fx[i].url, "://");
        if (!u) continue;
        u += 3;
        size_t l = strcspn(u, "/:");
        if (l == strlen(h) && !strncasecmp(u, h, l)) { snprintf(hosts[nhosts], 64, "%s", h); return nhosts++; }
    }
    return -1;
}

static void make_response(conn_t *c)
{
    // "GET path HTTP/1.0\r\nHost: h\r\n..."
    char path[600] = "", host[100] = "";
    sscanf(c->req, "GET %599s", path);
    char *h = strcasestr(c->req, "\nHost: ");
    if (h) sscanf(h + 7, "%99s", host);
    char url[800];
    if (!strncmp(path, "http", 4)) snprintf(url, sizeof url, "%s", path);      // (to a proxy: the whole URL)
    else snprintf(url, sizeof url, "%s://%s%s", c->tls ? "https" : "http", host, path);
    if (log_requests < 64) snprintf(req_log[log_requests], 320, "%.300s", url);
    log_requests++;
    if (!quiet) printf("  [%.2f s] GET %s\n", cpu.cyc / (double)HZ, url);
    fix_t *x = NULL;
    for (int i = 0; i < nfx; i++) if (!strcmp(fx[i].url, url)) { x = &fx[i]; break; }
    char head[1024];
    uint8_t *body = NULL; long bl = 0;
    int status = 404;
    const char *loc = "";
    if (x)
    {
        status = x->status;
        loc = x->loc;
        if (strcmp(x->file, "-"))
        {
            char p[600];
            snprintf(p, sizeof p, "%s/%s", fixdir, x->file);
            FILE *f = fopen(p, "rb");
            if (f) { fseek(f, 0, SEEK_END); bl = ftell(f); fseek(f, 0, SEEK_SET); body = malloc(bl + 1); fread(body, 1, bl, f); fclose(f); }
        }
    }
    int hl = snprintf(head, sizeof head, "HTTP/1.1 %d X\r\nDate: Sat, 31 Oct 2026 07:58:12 GMT\r\nServer: fake\r\n%s%s%s"
                      "Content-Length: %ld\r\nConnection: close\r\n\r\n", status, loc[0] ? "Location: " : "", loc, loc[0] ? "\r\n" : "", bl);
    c->resp = malloc(hl + bl);
    memcpy(c->resp, head, hl);
    if (bl) memcpy(c->resp + hl, body, bl);
    free(body);
    c->rlen = hl + bl;
    c->rpos = 0;
    c->t_resp = now_ms() + 80;
}

static long avail(conn_t *c)
{
    if (!c->resp) return 0;
    unsigned long t = now_ms();
    if (t < c->t_resp) return 0;
    long can = (long)((t - c->t_resp) * rate) - c->rpos;
    long left = c->rlen - c->rpos;
    return can < left ? (can < 0 ? 0 : can) : left;
}

static void conn_tick(conn_t *c)
{
    if (!c->used) return;
    if (c->state == 2 && now_ms() >= c->t_open + (c->tls ? 300 : 60)) c->state = 4;
    if (c->state == 4 && c->resp && c->rpos >= c->rlen) c->state = 7;
}

static uint8_t un_mem[0x4000];     // the implementation's ROM (its name)
#define UN_SLOT 0x8F
#define UN_ENTRY 0x4010
static int un_kind;                 // 0 rom, 1 page 3, 2 mapper

static void unapi_call(void)
{
    uint8_t f = cpu.a;
    for (int i = 1; i < 5; i++) conn_tick(&cn[i]);
    switch (f)
    {
        case 0:                     // UNAPI_GET_INFO
            cpu.h = 0x41; cpu.l = 0x00;
            cpu.b = 1; cpu.c = 2; cpu.d = 1; cpu.e = 1;
            cpu.a = 0;
            if (un_kind == 1) { memcpy(&mem[0xF200], un_mem + 0x100, 40); cpu.h = 0xF2; cpu.l = 0; }
            return;
        case 1:                     // GET_CAPAB
            if (cpu.b == 1) { cpu.h = 0x00; cpu.l = 0x0C; cpu.d = 0; cpu.e = 0x12; cpu.b = 4; cpu.a = 0; }
            else if (cpu.b == 4) { cpu.h = notls ? 0 : 1; cpu.l = 0x03; cpu.d = cpu.e = 0; cpu.a = 0; }
            else cpu.a = 4;
            return;
        case 6:                     // DNS_Q
        {
            char n[256]; int i = 0;
            uint16_t p = (uint16_t)(cpu.h << 8 | cpu.l);
            while (mem[p] && i < 255) n[i++] = (char)mem[p++];
            n[i] = 0;
            if (p >= 0x4000 && p < 0x8000) printf("  [!! DNS name in page 1: %04X]\n", p);
            int k = host_index(n);
            if (!quiet) printf("  [DNS %s -> %d]\n", n, k);
            dns_pending = 1; dns_t = now_ms() + 50; dns_err = k < 0;
            dns_ip = k < 0 ? 0 : (uint32_t)(10 << 24 | k + 1);
            cpu.a = 0; cpu.b = 0;
            return;
        }
        case 7:                     // DNS_S
            if (!dns_pending) { cpu.a = 0; cpu.b = 0; return; }
            if (now_ms() < dns_t) { cpu.a = 0; cpu.b = 1; cpu.c = 1; return; }
            if (dns_err) { cpu.a = 8; cpu.b = 3; return; }
            cpu.a = 0; cpu.b = 2; cpu.c = 0;
            cpu.l = (uint8_t)(dns_ip >> 24); cpu.h = (uint8_t)(dns_ip >> 16); cpu.e = (uint8_t)(dns_ip >> 8); cpu.d = (uint8_t)dns_ip;
            return;
        case 13:                    // TCP_OPEN
        {
            uint16_t p = (uint16_t)(cpu.h << 8 | cpu.l);
            if (p >= 0x4000 && p < 0x8000) printf("  [!! TCP_OPEN block in page 1]\n");
            uint8_t fl = mem[p + 10];
            if ((fl & 4) && notls) { cpu.a = 1; return; }
            int i;
            for (i = 1; i < 5 && cn[i].used; i++) ;
            if (i == 5) { cpu.a = 9; return; }
            conn_t *c = &cn[i];
            memset(c, 0, sizeof *c);
            c->used = true; c->tls = fl & 4; c->state = 2; c->t_open = now_ms();
            c->port = mem[p + 4] | mem[p + 5] << 8;
            int k = mem[p + 3] - 1;
            snprintf(c->host, 64, "%s", k >= 0 && k < nhosts ? hosts[k] : "?");
            if (c->tls)
            {
                uint16_t hn = mem[p + 11] | mem[p + 12] << 8;
                if (hn && strcmp((char *)&mem[hn], c->host)) printf("  [!! TLS name %s, not %s]\n", (char *)&mem[hn], c->host);
            }
            if ((c->tls && c->port != 443) || (!c->tls && c->port != 80)) printf("  [port %d tls %d]\n", c->port, c->tls);
            cpu.a = 0; cpu.b = (uint8_t)i;
            return;
        }
        case 14: case 15:           // TCP_CLOSE, TCP_ABORT
        {
            int a = cpu.b, b = cpu.b;
            if (!a) { a = 1; b = 4; }
            for (int i = a; i <= b && i < 5; i++) { free(cn[i].resp); memset(&cn[i], 0, sizeof cn[i]); }
            cpu.a = 0;
            return;
        }
        case 16:                    // TCP_STATE
        {
            conn_t *c = cpu.b < 5 ? &cn[cpu.b] : NULL;
            if (!c || !c->used) { cpu.a = 11; cpu.c = 0; return; }
            long av = avail(c);
            if (c->state == 7 && av == 0) { cpu.a = 11; cpu.c = 2; free(c->resp); memset(c, 0, sizeof *c); return; }
            cpu.a = 0; cpu.b = (uint8_t)c->state; cpu.c = c->tls;
            cpu.h = (uint8_t)((av > 65535 ? 65535 : av) >> 8); cpu.l = (uint8_t)(av > 65535 ? 65535 : av);
            cpu.ix = 1024;
            return;
        }
        case 17:                    // TCP_SEND
        {
            conn_t *c = cpu.b < 5 ? &cn[cpu.b] : NULL;
            if (!c || !c->used) { cpu.a = 11; return; }
            if (c->state != 4) { cpu.a = 12; return; }
            uint16_t d = (uint16_t)(cpu.d << 8 | cpu.e), n = (uint16_t)(cpu.h << 8 | cpu.l);
            if (d >= 0x4000 && d < 0x8000) printf("  [!! TCP_SEND data in page 1]\n");
            for (int i = 0; i < n && c->rl < 2047; i++) c->req[c->rl++] = (char)mem[(uint16_t)(d + i)];
            c->req[c->rl] = 0;
            if (!c->resp && strstr(c->req, "\r\n\r\n")) make_response(c);
            cpu.a = 0;
            return;
        }
        case 18:                    // TCP_RCV
        {
            conn_t *c = cpu.b < 5 ? &cn[cpu.b] : NULL;
            if (!c || !c->used) { cpu.a = 11; return; }
            uint16_t d = (uint16_t)(cpu.d << 8 | cpu.e), n = (uint16_t)(cpu.h << 8 | cpu.l);
            if (d >= 0x4000 && d < 0x8000) printf("  [!! TCP_RCV buffer in page 1]\n");
            long av = avail(c);
            if (c->state == 7 && av == 0) { cpu.a = 11; free(c->resp); memset(c, 0, sizeof *c); return; }
            if (av > n) av = n;
            for (long i = 0; i < av; i++) mem[(uint16_t)(d + i)] = c->resp[c->rpos + i];
            c->rpos += av;
            cpu.a = 0; cpu.b = (uint8_t)(av >> 8); cpu.c = (uint8_t)av; cpu.h = cpu.l = 0;
            cpu.cyc += (unsigned long)av * 30;
            conn_tick(c);
            return;
        }
        case 29: cpu.a = 0; return;  // WAIT
    }
    cpu.a = 1;                      // not here
}

// ---------------------------------------------------------------- disk (FCB)
static FILE *fcb_f;
static void fcb_name(uint16_t fcb, char *out)
{
    char n[13]; int k = 0;
    for (int i = 0; i < 8; i++) if (mem[fcb + 1 + i] != ' ') n[k++] = (char)mem[fcb + 1 + i];
    n[k++] = '.';
    for (int i = 0; i < 3; i++) if (mem[fcb + 9 + i] != ' ') n[k++] = (char)mem[fcb + 9 + i];
    n[k] = 0;
    sprintf(out, "%s/%s", inidir, n);
}
static uint16_t dma = 0x80;
static void bdos(void)
{
    uint16_t de = (uint16_t)(cpu.d << 8 | cpu.e);
    char p[600];
    switch (cpu.c)
    {
        case 0x09: { while (mem[de] != '$') putchar(mem[de++]); cpu.a = 0; break; }
        case 0x0F: fcb_name(de, p); if (fcb_f) fclose(fcb_f); fcb_f = fopen(p, "rb"); cpu.a = fcb_f ? 0 : 0xFF; if (!quiet) printf("  [open %s: %s]\n", p, fcb_f ? "ok" : "no"); break;
        case 0x16: fcb_name(de, p); if (fcb_f) fclose(fcb_f); fcb_f = fopen(p, "wb"); cpu.a = fcb_f ? 0 : 0xFF; if (!quiet) printf("  [create %s]\n", p); break;
        case 0x10: if (fcb_f) fclose(fcb_f); fcb_f = NULL; cpu.a = 0; break;
        case 0x1A: dma = de; cpu.a = 0; break;
        case 0x27: case 0x26:
        {
            uint16_t n = (uint16_t)(cpu.h << 8 | cpu.l);
            if (mem[de + 14] != 1) printf("  [record size %d]\n", mem[de + 14]);
            size_t r = 0;
            if (fcb_f)
            {
                if (cpu.c == 0x27) { uint8_t t[65536]; r = fread(t, 1, n, fcb_f); memcpy(&mem[dma], t, r); }
                else r = fwrite(&mem[dma], 1, n, fcb_f);
            }
            cpu.h = (uint8_t)(r >> 8); cpu.l = (uint8_t)r;
            cpu.a = r == n ? 0 : 1;
            break;
        }
        default: printf("[BDOS %02X]\n", cpu.c); cpu.a = 0xFF;
    }
}

// ---------------------------------------------------------------- the VDP
static uint8_t font[2048];
static void load_font(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256]; int n = 0;
    if (!f) { printf("no font\n"); return; }
    while (fgets(line, sizeof line, f) && n < 256)
    {
        char *q = strstr(line, "db");
        if (!q || (strchr(line, ';') && strchr(line, ';') < q)) continue;
        q += 2;
        for (int i = 0; i < 8; i++) { while (*q && *q != '$') q++; if (!*q) break; font[n * 8 + i] = (uint8_t)strtol(q + 1, &q, 16); }
        n++;
    }
    fclose(f);
}
static uint32_t vmask(void) { return msx1 ? 0x3FFF : 0x1FFFF; }
static uint8_t rtc_reg;
static uint8_t rtc_read(void)
{
    if (rtc_reg == 13) return 0;
    int Y = 2026, M = 10, D = 31, h = 8, m = 58;
    const char *e = getenv("RSS_RTC");
    if (e && !strcmp(e, "none")) return 0;
    if (e) sscanf(e, "%d-%d-%d %d:%d", &Y, &M, &D, &h, &m);
    int s = (int)(cpu.cyc / HZ);
    m += s / 60;
    int v[13] = { s % 10, s % 60 / 10, m % 10, m / 10, h % 10, h / 10, 6, D % 10, D / 10, M % 10, M / 10, (Y - 1980) % 10, (Y - 1980) / 10 };
    return rtc_reg < 13 ? (uint8_t)v[rtc_reg] : 0;
}
static uint8_t pin(z80 *z, uint8_t p)
{
    (void)z;
    if (p == 0xB5) return msx1 ? 0xFF : rtc_read();
    if (p == 0x98) { uint8_t v = vram[vaddr & vmask()]; vaddr = (vaddr + 1) & vmask(); vlatch = 0; return v; }
    if (p == 0x99) { vlatch = 0; return 0x80; }
    if (p == 0xA8) return rom_mode ? 0x50 : 0xFF;
    return 0xFF;
}
static void pout(z80 *z, uint8_t p, uint8_t v)
{
    (void)z;
    if (p == 0x98) { vram[vaddr & vmask()] = v; vaddr = (vaddr + 1) & vmask(); vlatch = 0; return; }
    if (p == 0xB4) { rtc_reg = v & 15; return; }
    if (p != 0x99) return;
    if (!vlatch) { vfirst = v; vlatch = 1; return; }
    vlatch = 0;
    if (v & 0x80)
    {
        int r = v & (msx1 ? 7 : 0x3F);
        vregs[r] = vfirst;
        return;
    }
    vaddr = ((uint32_t)(msx1 ? 0 : vregs[14] & 7) << 14) | (uint32_t)((v & 0x3F) << 8 | vfirst);
    vread = !(v & 0x40);
}
static void initxt(void)
{
    int w = mem[0xF3AE];
    memset(vregs, 0, 16);
    if (w > 40 && !msx1)
    {
        vregs[0] = 0x04; vregs[1] = 0x70; vregs[2] = 0x03; vregs[3] = 0x27; vregs[4] = 0x02;
        memset(vram, ' ', 80 * 24);
        memcpy(&vram[0x1000], font, 2048);
    }
    else
    {
        vregs[0] = 0x00; vregs[1] = 0x70; vregs[2] = 0x00; vregs[4] = 0x01;
        memset(vram, ' ', 40 * 24);
        memcpy(&vram[0x0800], font, 2048);
    }
    vregs[7] = (uint8_t)(mem[0xF3E9] << 4 | mem[0xF3EA]);
    vregs[9] = mem[0xFFE8];
}

// the screen as text (bars: '[' at their start)
static void dump_screen(const char *title)
{
    bool t2 = (vregs[0] & 0x0E) == 0x04;
    int W = t2 ? 80 : 40, H = t2 ? ((vregs[9] & 0x80) ? 26 : 24) : 24;
    uint32_t nb = t2 ? (uint32_t)(vregs[2] & 0x7C) << 10 : (uint32_t)(vregs[2] & 0x0F) << 10;
    uint32_t cb = ((uint32_t)vregs[10] << 14) | ((uint32_t)(vregs[3] & 0xF8) << 6);
    printf("---- %s (%.1f s) ----\n", title, cpu.cyc / (double)HZ);
    for (int y = 0; y < H; y++)
    {
        char l[100]; int bar = 0;
        for (int x = 0; x < W; x++)
        {
            uint8_t c = vram[nb + y * W + x];
            int b = t2 ? (vram[cb + (y * W + x) / 8] >> (7 - (y * W + x) % 8)) & 1 : (c >> 7);
            if (b) bar = 1;
            if (!t2) c &= 0x7F;
            l[x] = c == 1 ? '-' : c == 2 ? '|' : c == 4 ? '.' : (c >= 32 && c < 127) ? (char)c : c >= 128 ? '#' : '?';
        }
        l[W] = 0;
        printf("%c%s\n", bar ? '*' : ' ', l);
    }
}

// ---------------------------------------------------------------- the machine
static uint8_t rd(void *u, uint16_t a) { (void)u; return mem[a]; }
static void wr(void *u, uint16_t a, uint8_t v)
{
    (void)u;
    if (rom_mode && a >= 0x4000 && a < 0xC000) return;
    if (!rom_mode && a < 0x100) return;
    mem[a] = v;
}
static void ret(void) { cpu.pc = mem[cpu.sp] | (mem[cpu.sp + 1] << 8); cpu.sp += 2; }
static uint8_t key_code(char k)
{
    switch (k) { case '{': return 30; case '}': return 31; case '<': return 29; case '>': return 28;
                 case '^': return 13; case '_': return 8; case '~': return 27; case '.': return 0; }
    return (uint8_t)k;
}
static double shots[32]; static int nshots, shot_i;
static unsigned long halts, busy_halt;

static int run(unsigned long max)
{
    while (cpu.cyc < max)
    {
        if (cpu.cyc >= next_frame)
        {
            next_frame += HZ / 60;
            frames++;
            uint16_t j = mem[0xFC9E] | mem[0xFC9F] << 8;
            j++;
            mem[0xFC9E] = (uint8_t)j; mem[0xFC9F] = (uint8_t)(j >> 8);
            if (cpu.iff1) cpu.halted = false;
            if (keys && *keys && cpu.cyc >= next_key)
            {
                uint8_t k = key_code(*keys++);
                if (k && keyn < 16) keybuf[keyn++] = k;
                next_key = cpu.cyc + HZ / 2;
            }
            if (shot_i < nshots && cpu.cyc / (double)HZ >= shots[shot_i]) { char t[32]; sprintf(t, "shot %d", shot_i); dump_screen(t); shot_i++; }
        }
        if (cpu.halted) { cpu.cyc += 4; continue; }
        uint16_t pc = cpu.pc;
        static uint16_t ring[64]; static int ri;
        if (pc != ring[(ri - 1) & 63]) ring[ri++ & 63] = pc;
        if (pc == 0x0000)
        {
            if (getenv("RSS_TRACE")) { printf("[to 0, SP %04X:", cpu.sp); for (int i = 0; i < 64; i++) printf(" %04X", ring[(ri + i) & 63]); printf("]\n"); }
            return 0;
        }
        if (pc == 0x0005 && !rom_mode) { bdos(); ret(); cpu.cyc += 500; continue; }
        if (pc == 0xF37D && rom_mode) { bdos(); ret(); cpu.cyc += 500; continue; }
        if (pc == 0x000C)           // RDSLT
        {
            uint16_t a = (uint16_t)(cpu.h << 8 | cpu.l);
            if (cpu.a == UN_SLOT) cpu.a = un_mem[a & 0x3FFF];
            else if (a == 0x002D) cpu.a = msx1 ? 0 : 2;
            else if (a == 0x002B) cpu.a = 0x11;   // international, 60 Hz
            else cpu.a = 0xFF;
            cpu.iff1 = cpu.iff2 = false;
            ret(); cpu.cyc += 150; continue;
        }
        if (pc == 0x001C || (un_kind == 2 && pc == 0xF300))   // CALSLT / CALL_MAP
        {
            uint16_t ix = cpu.ix;
            if (ix == UN_ENTRY && (cpu.iy >> 8) == UN_SLOT) { unapi_call(); ret(); cpu.cyc += 800; continue; }
            if (ix == 0x009C) { cpu.zf = keyn == 0; }
            else if (ix == 0x009F) { cpu.a = keyn ? keybuf[0] : 0; if (keyn) { memmove(keybuf, keybuf + 1, 15); keyn--; } }
            else if (ix == 0x006C) { initxt(); cpu.cyc += 20000; }
            else if (ix == 0x00C0) { if (!quiet) printf("  [beep]\n"); }
            else printf("[CALSLT %04X]\n", ix);
            ret(); cpu.cyc += 300; continue;
        }
        if (pc == 0x0024) { cpu.iff1 = cpu.iff2 = false; ret(); cpu.cyc += 300; continue; }  // ENASLT
        if (un_kind == 1 && pc == 0xF100) { unapi_call(); ret(); cpu.cyc += 800; continue; }
        if (pc == 0xFFCA)           // EXTBIO
        {
            uint16_t de = (uint16_t)(cpu.d << 8 | cpu.e);
            if (de == 0x2222)
            {
                if (cpu.a == 0xFF) { if (un_kind == 2) { cpu.h = 0xF3; cpu.l = 0x00; cpu.a = 3; } else cpu.h = cpu.l = 0; }
                else if (!strcasecmp((char *)&mem[0xF847], "TCP/IP") && !getenv("RSS_NONET"))
                {
                    if (cpu.a == 0) cpu.b++;
                    else if (cpu.a == 1)
                    {
                        if (un_kind == 1) { cpu.h = 0xF1; cpu.l = 0x00; cpu.a = 0; cpu.b = 0; }
                        else { cpu.a = UN_SLOT; cpu.b = un_kind == 2 ? 3 : 0xFF; cpu.h = 0x40; cpu.l = 0x10; }
                        if (un_kind == 2) cpu.a = UN_SLOT;
                    }
                }
            }
            ret(); cpu.cyc += 300; continue;
        }
        if (un_kind == 2 && pc == 0xF303)    // RD_MAP
        {
            cpu.a = un_mem[(cpu.h << 8 | cpu.l) & 0x3FFF];
            ret(); continue;
        }
        if (mem[pc] == 0x76) halts++;
        { static int spc = -2, last = -1; if (spc == -2) spc = getenv("RSS_SPCHECK") ? (int)strtol(getenv("RSS_SPCHECK"), 0, 16) : -1;
          if (pc == spc && cpu.sp != last) { printf("  [loop SP %04X at %.2f s]\n", cpu.sp, cpu.cyc / (double)HZ); last = cpu.sp; } }
        { static unsigned long *prof; static unsigned long pn;
          if (getenv("RSS_PROF")) { if (!prof) prof = calloc(65536, sizeof *prof); unsigned long c0 = cpu.cyc; z80_step(&cpu); prof[pc] += cpu.cyc - c0;
            if (cpu.cyc / HZ != pn) { pn = cpu.cyc / HZ; FILE *pf = fopen(getenv("RSS_PROF"), "w"); for (int i = 0; i < 65536; i++) if (prof[i]) fprintf(pf, "%04X %lu\n", i, prof[i]); fclose(pf); }
            continue; } }
        z80_step(&cpu);
    }
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 7) { printf("usage: z80_rss RSS.COM|RSS.ROM fixtures inidir keys seconds out.vram\n"); return 2; }
    msx1 = getenv("RSS_MSX1") != NULL;
    notls = getenv("RSS_NOTLS") != NULL;
    quiet = getenv("RSS_QUIET") != NULL;
    if (getenv("RSS_RATE")) rate = atoi(getenv("RSS_RATE"));
    const char *k = getenv("RSS_UNAPI");
    un_kind = k && !strcmp(k, "page3") ? 1 : k && !strcmp(k, "map") ? 2 : 0;
    fixdir = argv[2]; inidir = argv[3]; keys = argv[4];
    load_fixtures();
    load_font(getenv("RSS_FONT") ? getenv("RSS_FONT") : "/home/claude/rig/cbios/src/font_us.asm");
    strcpy((char *)un_mem + 0x100, "Fake TCP/IP UNAPI");
    { const char *s = getenv("RSS_SHOT"); while (s && *s && nshots < 32) { shots[nshots++] = atof(s); s = strchr(s, ','); if (s) s++; } }
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    size_t l1 = strlen(argv[1]);
    rom_mode = l1 > 4 && !strcasecmp(argv[1] + l1 - 4, ".ROM");
    z80_init(&cpu);
    cpu.read_byte = rd; cpu.write_byte = wr; cpu.port_in = pin; cpu.port_out = pout;
    memset(mem + 0xF380, 0, 0xC80);
    mem[0xFCC1] = 0x00;             // EXPTBL: slot 0 not expanded
    mem[0xFB20] = 1;                // HOKVLD
    mem[0xF3AE] = 39;
    mem[0xFFE8] = 0x02;             // RG9SAV
    for (int i = 0xFD9A; i < 0xFFCA; i++) mem[i] = 0xC9;
    mem[0xFFCA] = 0xC9;
    mem[0xFFA7] = getenv("RSS_NODISK") ? 0xC9 : 0xF7;   // H.PHYD
    if (rom_mode)
    {
        fread(rom, 1, sizeof rom, f);
        memcpy(&mem[0x4000], rom, 0x8000);
        mem[0xFC4A] = 0x00; mem[0xFC4B] = 0xDE;          // HIMEM
        cpu.pc = (uint16_t)(rom[2] | rom[3] << 8);
        cpu.sp = 0xF000;
        mem[0xF000] = 0x00; mem[0xF001] = 0xF8;          // INIT returns to F800
        mem[0xF800] = 0x76;                              // (then H.STKE is called, below)
    }
    else
    {
        fread(&mem[0x100], 1, 0xC000, f);
        mem[6] = 0x00; mem[7] = 0xD8;                    // the TPA's top
        cpu.pc = 0x100;
        cpu.sp = 0xD800;
        mem[0xD800] = 0; mem[0xD801] = 0;
    }
    fclose(f);
    next_frame = HZ / 60;
    next_key = HZ * 4;
    if (rom_mode)
    {
        // INIT
        while (cpu.pc != 0xF800 && cpu.cyc < HZ) z80_step(&cpu);
        if (mem[0xFEDA] != 0xF7) { printf("INIT did not set H.STKE\n"); return 1; }
        // H.STKE: as CALLF (our slot in page 1 already), back to 0000h at the end
        cpu.pc = (uint16_t)(mem[0xFEDC] | mem[0xFEDD] << 8);
        cpu.sp = 0xF100;
        mem[0xF100] = 0x00; mem[0xF101] = 0x00;
        cpu.iff1 = cpu.iff2 = true;
    }
    int r = run(HZ * (unsigned long)atoi(argv[5]));
    if (rom_mode && cpu.pc == 0) r = 0;
    dump_screen(r ? "time up" : "the end");
    printf("[%s after %.1f s, %lu requests, PC %04X]\n", r ? "time up" : "exit", cpu.cyc / (double)HZ, log_requests, cpu.pc);
    f = fopen(argv[6], "wb");
    fwrite(vram, 1, 0x20000, f);
    fwrite(vregs, 1, 64, f);
    fclose(f);
    return 0;
}
