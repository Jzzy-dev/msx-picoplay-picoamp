// MSX PICOVERSE PROJECT
// pva_pics.c - PicoVerse Audio Engine: pictures from the card for the MSX's
// SCREEN 8 (engine 0.17): PICOAMP's pictures page and its screensaver.
//
// A folder's pictures (its folders and its JPEG files, sorted) are listed
// (PIC_DIR, PIC_NAMES). One of them is decoded (PIC_SHOW): any size of
// baseline JPEG, made small while decoding (TJpgDec: 1/2, 1/4, 1/8) and then
// to fit 256 x 192 (the MSX's pixels are about 1.1 times as wide as high),
// averaged, and dithered (Floyd-Steinberg) to SCREEN 8's 256 colours (GGGRRRBB).
// The MSX takes the rows as they come (PIC_GET: up to 7 a time) and puts them
// where the screen does not show yet.
//
// The decoding goes in steps of about 2 ms in the main loop, so that the music
// plays on; a big photo takes a few seconds. Its memory (about 38 KB) is the
// covers' while the pictures page is open (PIC_DIR borrows it, PIC_CLOSE gives
// it back): the arena's in the PicoAmp ROM, else the stream RAM when no
// station plays.
//
// The screensaver's minutes ([pictures] saver in PICOAMP.INI) are in the
// status (PVA_ST_PIC_SAVER), so that the player knows when to start it.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ff.h"
#include "pva_internal.h"
#include "tjpgd/tjpgd.h"

#define PIC_PATH_MAX 255
#define OUT_W       256
#define OUT_H       192
#define PIX_ASPECT_10 11            // an MSX pixel: 1.1 times as wide as high
#define NAMES_POOL  (8u * 1024u)
#define NAMES_MAX   400u
#define STRIP_MAX   (16u * 1024u)   // one MCU row of the decoded picture, RGB
#define RING_ROWS   8u
#define WORK_SIZE   (TJPGD_WORKSPACE_SIZE + 64)
#define A4(n)       (((n) + 3u) & ~3u)

// the memory (borrowed from the covers)
static uint8_t  *mem;
static size_t    mem_size;
static char     *pool;              // the names: a type byte (D folder, J picture) then the name, NUL
static uint16_t *ent;               // their places in pool, sorted
static uint16_t  n_ent, pool_used;
static char      folder[PIC_PATH_MAX + 1];
static FIL      *fil;
static uint8_t  *work;
static uint8_t  *strip;
static uint16_t *xs;                // OUT_W + 1: where each column starts in the decoded picture
static uint32_t *acc;               // OUT_W * 3: the sums of the row in the making
static int16_t  *err0, *err1;       // (OUT_W + 2) * 3: the dither's errors, this row and the next
static uint8_t  *ring;              // RING_ROWS * OUT_W

// a picture
enum { P_IDLE, P_WORK, P_DONE, P_ERROR };
static uint8_t  pst = P_IDLE, perr;
static JDEC     jd;
static JSTEP    js;
static uint16_t dw, dh;             // the decoded picture
static uint16_t ox0, oy0, ow, oh;   // where it goes in the 256 x 192
static uint16_t strip_y, strip_h;   // the decoded rows in strip (scaled)
static bool     strip_full;         // an MCU row is in it
static uint8_t  *lastrow;           // the row before strip_y (a small picture made bigger needs it again)
static uint8_t  scale;
static uint16_t sy;                 // the next decoded row to use
static uint16_t oy;                 // the next output row
static uint32_t acc_n;              // rows summed in acc
static uint16_t ring_head, ring_n;  // (first row in the ring: its number)
static uint16_t rows_out;           // rows made in all (0-192)
static uint16_t rows_given;         // rows the MSX took
static uint32_t t_start;
static uint8_t  saver_min;
static uint32_t saver_t;

bool pva_pics_open(void) { return mem != NULL; }
uint8_t pva_pics_saver(void) { return saver_min; }

// ---------------------------------------------------------------- the memory
static bool borrow(void)
{
    if (mem) return true;
    size_t n = 0;
    mem = pva_art_borrow(&n);
    if (!mem) return false;
    mem_size = n;
    uint8_t *m = mem;
    pool = (char *)m;       m += A4(NAMES_POOL);
    ent = (uint16_t *)m;    m += A4(NAMES_MAX * 2u);
    fil = (FIL *)m;         m += A4(sizeof(FIL));
    work = m;               m += A4(WORK_SIZE);
    xs = (uint16_t *)m;     m += A4((OUT_W + 1) * 2u);
    acc = (uint32_t *)m;    m += OUT_W * 3u * 4u;
    err0 = (int16_t *)m;    m += A4((OUT_W + 2) * 3u * 2u);
    err1 = (int16_t *)m;    m += A4((OUT_W + 2) * 3u * 2u);
    ring = m;               m += RING_ROWS * OUT_W;
    strip = m;
    size_t used = (size_t)(m - mem);
    if (used + 4096u > n) { pva_art_giveback(); mem = NULL; return false; }
    n_ent = pool_used = 0;
    pva_log("pictures: %u bytes (%u for a strip)", (unsigned)n, (unsigned)(n - used));
    return true;
}

static size_t strip_room(void) { size_t r = mem_size - (size_t)(strip - mem); return r > STRIP_MAX ? STRIP_MAX : r; }

void pva_pics_close(void)
{
    if (!mem) return;
    if (pst == P_WORK) f_close(fil);
    pst = P_IDLE;
    mem = NULL;
    pva_art_giveback();
}

// ---------------------------------------------------------------- a folder
static bool is_jpg(const char *n)
{
    const char *d = strrchr(n, '.');
    if (!d) return false;
    char e[6] = { 0 };
    for (int i = 0; i < 5 && d[i + 1]; i++) e[i] = (char)(d[i + 1] | 0x20);
    return !strcmp(e, "jpg") || !strcmp(e, "jpeg");
}

static int ent_cmp(const void *a, const void *b)
{
    const char *x = pool + *(const uint16_t *)a, *y = pool + *(const uint16_t *)b;
    if (x[0] != y[0]) return x[0] == 'D' ? -1 : 1;  // folders first
    for (x++, y++; *x && *y; x++, y++)
    {
        int c = (*x | 0x20) - (*y | 0x20);
        if ((*x >= 'A' && *x <= 'Z') || (*x >= 'a' && *x <= 'z')) { if (c) return c; }
        else if (*x != *y) return *x - *y;
    }
    return *x - *y;
}

static int read_folder(const char *path)
{
    char fp[PIC_PATH_MAX + 8];
    snprintf(fp, sizeof fp, "0:%s", path[0] ? path : "/");
    DIR d;
    FILINFO fi;
    if (f_opendir(&d, fp) != FR_OK) return PVA_E_NOTFOUND;
    n_ent = pool_used = 0;
    bool full = false;
    while (f_readdir(&d, &fi) == FR_OK && fi.fname[0])
    {
        if (fi.fattrib & (AM_HID | AM_SYS) || fi.fname[0] == '.') continue;
        char t = (fi.fattrib & AM_DIR) ? 'D' : is_jpg(fi.fname) ? 'J' : 0;
        if (!t) continue;
        size_t l = strlen(fi.fname) + 2;
        if (n_ent >= NAMES_MAX || pool_used + l > NAMES_POOL) { full = true; break; }
        ent[n_ent++] = pool_used;
        pool[pool_used] = t;
        memcpy(pool + pool_used + 1, fi.fname, l - 1);
        pool_used += (uint16_t)l;
    }
    f_closedir(&d);
    qsort(ent, n_ent, sizeof ent[0], ent_cmp);
    snprintf(folder, sizeof folder, "%s", path);
    pva_log("pictures: %.30s: %u%s", path[0] ? path : "/", (unsigned)n_ent, full ? " (cut)" : "");
    return PVA_OK;
}

// ---------------------------------------------------------------- a picture
static size_t in_fn(JDEC *j, uint8_t *buf, size_t n)
{
    (void)j;
    UINT br = 0;
    if (!buf) return f_lseek(fil, f_tell(fil) + n) == FR_OK ? n : 0;
    if (f_read(fil, buf, (UINT)n, &br) != FR_OK) return 0;
    return br;
}

static int out_fn(JDEC *j, void *bitmap, JRECT *r)
{
    (void)j;
    const uint8_t *s = bitmap;
    unsigned w = r->right - r->left + 1;
    for (unsigned y = r->top; y <= r->bottom; y++)
    {
        unsigned ry = y - strip_y;
        if (y < strip_y || ry >= strip_h) { s += w * 3u; continue; }
        memcpy(strip + ((size_t)ry * dw + r->left) * 3u, s, w * 3u);
        s += w * 3u;
    }
    return 1;
}

// the decoded rows of the output row o: [a, b)
static void src_rows(uint16_t o, uint16_t *a, uint16_t *b)
{
    uint32_t i = o - oy0;
    *a = (uint16_t)(i * dh / oh);
    *b = (uint16_t)((i + 1) * dh / oh);
    if (*b <= *a) *b = *a + 1;
}

// the decoded columns of output column x: [xa, xb)
static inline unsigned pic_xb(unsigned x) { unsigned a = xs[x], b = xs[x + 1]; return b > a ? b : (a + 1 <= dw ? a + 1 : a); }

static const uint8_t lv3[8] = { 0, 36, 73, 109, 146, 182, 219, 255 };
static const uint8_t lv2[4] = { 0, 73, 146, 255 };

// a quantised level (n levels) and its value
static inline int q8(int v, int *out) { int i = (v * 7 + 127) / 255; if (i < 0) i = 0; if (i > 7) i = 7; *out = lv3[i]; return i; }
static inline int q4(int v, int *out) { int i = (v * 3 + 127) / 255; if (i < 0) i = 0; if (i > 3) i = 3; *out = lv2[i]; return i; }

// the row in acc (acc_n rows) to the ring, dithered (serpentine)
static void emit_row(bool black)
{
    uint8_t *o = ring + (size_t)((ring_head + ring_n) % RING_ROWS) * OUT_W;
    ring_n++;
    rows_out++;
    if (black) { memset(o, 0, OUT_W); return; }
    memset(err1, 0, (OUT_W + 2) * 3u * 2u);
    bool rev = oy & 1;
    for (int k = 0; k < (int)ow; k++)
    {
        int x = rev ? (int)ow - 1 - k : k;
        int d = rev ? -1 : 1;
        uint32_t n = (uint32_t)(pic_xb(x) - xs[x]) * acc_n;
        int rgb[3], q[3];
        for (int c = 0; c < 3; c++)
        {
            int v = (int)((acc[x * 3 + c] + n / 2) / n) + err0[(x + 1) * 3 + c] * 7 / 8 / 16;
            rgb[c] = v;
        }
        int vr, vg, vb;
        int ir = q8(rgb[0], &vr), ig = q8(rgb[1], &vg), ib = q4(rgb[2], &vb);
        q[0] = rgb[0] - vr; q[1] = rgb[1] - vg; q[2] = rgb[2] - vb;
        o[ox0 + x] = (uint8_t)(ig << 5 | ir << 2 | ib);
        for (int c = 0; c < 3; c++)
        {
            int e = q[c] * 16;
            err0[(x + 1 + d) * 3 + c] += (int16_t)(e * 7 / 16);
            err1[(x + 1 - d) * 3 + c] += (int16_t)(e * 3 / 16);
            err1[(x + 1) * 3 + c] += (int16_t)(e * 5 / 16);
            err1[(x + 1 + d) * 3 + c] += (int16_t)(e * 1 / 16);
        }
    }
    // (the left and right of the picture: black)
    if (ox0) memset(o, 0, ox0);
    if (ox0 + ow < OUT_W) memset(o + ox0 + ow, 0, OUT_W - ox0 - ow);
    int16_t *t = err0; err0 = err1; err1 = t;
}


static const uint8_t *row_ptr(uint16_t r) { return r >= strip_y ? strip + (size_t)(r - strip_y) * dw * 3u : lastrow; }

// a decoded row into acc
static void add_row(const uint8_t *r)
{
    for (unsigned x = 0; x < ow; x++)
    {
        uint32_t s0 = 0, s1 = 0, s2 = 0;
        for (unsigned i = xs[x], e = pic_xb(x); i < e; i++) { s0 += r[i * 3]; s1 += r[i * 3 + 1]; s2 += r[i * 3 + 2]; }
        acc[x * 3] += s0; acc[x * 3 + 1] += s1; acc[x * 3 + 2] += s2;
    }
    acc_n++;
}

// the strip's rows to output rows, as the ring has room (true: the strip is used up)
static bool use_strip(void)
{
    while (ring_n < RING_ROWS)
    {
        if (oy >= OUT_H) return true;
        if (oy < oy0 || oy >= oy0 + oh) { emit_row(true); oy++; continue; }
        uint16_t a, b;
        src_rows(oy, &a, &b);
        if (sy < a) sy = a;                         // (rows no output row needs)
        if (sy >= strip_y + strip_h) return true;   // the next strip
        while (sy < b && sy < strip_y + strip_h) { add_row(row_ptr(sy)); sy++; }
        if (sy < b) return true;                    // (its rows go on in the next strip)
        emit_row(false);
        memset(acc, 0, OUT_W * 3u * 4u);
        acc_n = 0;
        oy++;
        // (an output row that needs the same rows again: a small picture made bigger)
        if (oy < oy0 + oh) { uint16_t a2, b2; src_rows(oy, &a2, &b2); if (a2 < sy) sy = a2; }
    }
    return false;
}

static void pic_fail(uint8_t e, const char *why)
{
    pva_log("picture: %s", why);
    if (pst == P_WORK) f_close(fil);
    pst = P_ERROR;
    perr = e;
}

static int pic_show(uint16_t idx)
{
    if (!mem) return PVA_E_STATE;
    if (idx >= n_ent || pool[ent[idx]] != 'J') return PVA_E_ARGS;
    if (pst == P_WORK) f_close(fil);
    char fp[PIC_PATH_MAX + 80];
    snprintf(fp, sizeof fp, "0:%s/%s", folder[0] && strcmp(folder, "/") ? folder : "", pool + ent[idx] + 1);
    pst = P_WORK;
    perr = 0;
    ring_head = ring_n = rows_out = rows_given = 0;
    t_start = pva_hal_millis();
    if (f_open(fil, fp, FA_READ) != FR_OK) { pic_fail(PVA_PIC_E_OPEN, "cannot open"); return PVA_OK; }
    JRESULT r = jd_prepare(&jd, in_fn, work, WORK_SIZE, NULL);
    if (r != JDR_OK) { pic_fail(r == JDR_FMT3 ? PVA_PIC_E_PROGRESSIVE : PVA_PIC_E_FORMAT, r == JDR_FMT3 ? "progressive (or another kind) JPEG" : "not a JPEG it reads"); return PVA_OK; }
    // the scale: as small as it may be while it still covers the 256 x 192 (in the MSX's pixels), and its MCU row fits
    unsigned need_w = OUT_W * PIX_ASPECT_10 / 10, need_h = OUT_H;
    uint8_t s = 0;
    while (s < 3 && (jd.width >> (s + 1)) >= need_w && (jd.height >> (s + 1)) >= need_h) s++;
    while (s < 3 && (size_t)(jd.width >> s) * ((jd.msy * 8u >> s) + 1u) * 3u > strip_room()) s++;
    scale = s;
    dw = (uint16_t)(jd.width >> s);
    dh = (uint16_t)(jd.height >> s);
    strip_h = (uint16_t)(jd.msy * 8u >> s);
    if (!dw || !dh || (size_t)dw * (strip_h + 1u) * 3u > strip_room()) { pic_fail(PVA_PIC_E_SIZE, "too wide"); return PVA_OK; }
    lastrow = strip + (size_t)dw * strip_h * 3u;
    strip_full = false;
    // fit: dw x dh square pixels into 256 x 192 MSX pixels (1.1 wide)
    uint32_t w = OUT_W, h = (uint32_t)dh * OUT_W * PIX_ASPECT_10 / 10 / dw;
    if (h > OUT_H) { h = OUT_H; w = (uint32_t)dw * OUT_H * 10 / PIX_ASPECT_10 / dh; }
    if (!w) w = 1;
    if (!h) h = 1;
    ow = (uint16_t)w; oh = (uint16_t)h;
    ox0 = (uint16_t)((OUT_W - ow) / 2); oy0 = (uint16_t)((OUT_H - oh) / 2);
    for (unsigned x = 0; x <= ow; x++) xs[x] = (uint16_t)((uint32_t)x * dw / ow);
    memset(acc, 0, OUT_W * 3u * 4u);
    memset(err0, 0, (OUT_W + 2) * 3u * 2u);
    acc_n = 0;
    sy = 0;
    oy = 0;
    strip_y = 0;
    jd_step_begin(&jd, &js, out_fn, s);
    pva_log("picture: %ux%u, 1/%u: %ux%u, %ux%u", jd.width, jd.height, 1u << s, dw, dh, ow, oh);
    return PVA_OK;
}

static void finish(void)
{
    f_close(fil);
    pst = P_DONE;
    pva_log("picture: made in %lu ms", (unsigned long)(pva_hal_millis() - t_start));
}

void pva_pics_poll(void)
{
    uint32_t now = pva_hal_millis();
    if (now - saver_t > 2000u)
    {
        saver_t = now;
        char v[8];
        saver_min = pva_cfg_get("pictures.saver", v, sizeof v) ? (uint8_t)atoi(v) : 0;
    }
    if (pst != P_WORK) return;
    // about 2 ms a pass: the music goes on
    do
    {
        if (strip_full)
        {
            // the strip's rows to the ring (as it has room), then the next MCU row
            if (!use_strip()) return;
            if (oy >= OUT_H) { finish(); return; }
            if (js.done)
            {
                while (oy < OUT_H && ring_n < RING_ROWS) { emit_row(true); oy++; }
                if (oy >= OUT_H) finish();
                return;
            }
            memcpy(lastrow, strip + (size_t)(strip_h - 1u) * dw * 3u, (size_t)dw * 3u);
            strip_full = false;
        }
        if (js.x == 0) strip_y = (uint16_t)(js.y >> scale);
        JRESULT r = jd_step(&jd, &js, 64);
        if (r != JDR_OK) { pic_fail(PVA_PIC_E_FORMAT, "broken data"); return; }
        if (js.x == 0) strip_full = true;           // (an MCU row ended)
    } while (pva_hal_millis() - now < 2u);
}

// ---------------------------------------------------------------- commands
int pva_pics_cmd(uint8_t code, const uint8_t *args, size_t n)
{
    switch (code)
    {
        case PVA_C_PIC_DIR:
        {
            if (!borrow()) return PVA_E_FULL;
            char p[PIC_PATH_MAX + 1];
            size_t l = n < sizeof p - 1 ? n : sizeof p - 1;
            memcpy(p, args, l);
            p[l] = 0;
            size_t k = strlen(p);
            while (k > 1 && p[k - 1] == '/') p[--k] = 0;
            int r = read_folder(p);
            if (r != PVA_OK) return r;
            uint16_t nd = 0;
            while (nd < n_ent && pool[ent[nd]] == 'D') nd++;
            pva_reply_byte((uint8_t)n_ent);
            pva_reply_byte((uint8_t)(n_ent >> 8));
            pva_reply_byte((uint8_t)nd);            // (the folders come first)
            pva_reply_byte((uint8_t)(nd >> 8));
            return PVA_OK;
        }
        case PVA_C_PIC_NAMES:
        {
            if (!mem) return PVA_E_STATE;
            uint16_t first = (uint16_t)(args[0] | args[1] << 8);
            uint8_t cnt = args[2];
            uint8_t w = args[3] ? args[3] : 255;
            for (uint16_t i = first; i < n_ent && i < first + cnt; i++)
            {
                const char *e = pool + ent[i];
                pva_reply_byte((uint8_t)e[0]);
                size_t l = strlen(e + 1);
                if (l > w) l = w;
                for (size_t c = 0; c < l; c++) pva_reply_byte((uint8_t)e[1 + c]);
                pva_reply_byte(0);
            }
            return PVA_OK;
        }
        case PVA_C_PIC_SHOW:
            return pic_show((uint16_t)(args[0] | args[1] << 8));
        case PVA_C_PIC_GET:
        {
            // args: u8 rows at most (0: 7). reply: u8 state, u8 error, u8 the first row, u8 rows, then the rows
            uint8_t mx = args[0] && args[0] < 7 ? args[0] : 7;
            uint8_t k = ring_n < mx ? (uint8_t)ring_n : mx;
            uint8_t s = pst == P_ERROR ? 3 : (pst == P_DONE && rows_given + k >= OUT_H) ? 2 : pst == P_IDLE ? 0 : 1;
            pva_reply_byte(s);
            pva_reply_byte(perr);
            pva_reply_byte((uint8_t)rows_given);
            pva_reply_byte(k);
            for (uint8_t i = 0; i < k; i++)
            {
                const uint8_t *r = ring + (size_t)((ring_head + i) % RING_ROWS) * OUT_W;
                for (unsigned x = 0; x < OUT_W; x++) pva_reply_byte(r[x]);
            }
            ring_head = (uint16_t)((ring_head + k) % RING_ROWS);
            ring_n -= k;
            rows_given += k;
            return PVA_OK;
        }
        case PVA_C_PIC_CLOSE:
            pva_pics_close();
            return PVA_OK;
    }
    return PVA_E_ARGS;
}
