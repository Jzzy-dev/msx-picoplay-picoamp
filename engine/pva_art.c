// MSX PICOVERSE PROJECT
// pva_art.c - PicoVerse Audio Engine: a track's cover, ready for the MSX.
//
// When a file starts, its picture is looked for: the one in its ID3 tag (the
// front cover first), else an image in its folder (cover.jpg, folder.jpg,
// front.jpg ...). It is decoded at once (TJpgDec, baseline JPEG, made small
// while decoding) and then converted to SCREEN 4 cells in small steps in the
// main loop (pva_cover.c), so that the music does not stop for it. A folder's
// image is converted once for all its tracks.
//
// Memory: about 37 KB, from the stream ring, which no stream uses while a
// file plays (a stream ends the cover before it takes the ring back), or from
// the arena when the ring is not there and the arena has it.
//
// The player says once which palette it uses and which entries the cover may
// set (COVER_SETUP); COVER_GET gives the result. PVA_ST_COVER_GEN goes +1 when
// the cover changes (also to none), PVA_ST_COVER_STATE says what there is.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <stdio.h>
#include <string.h>
#include "ff.h"
#include "pva_internal.h"
#include "pva_cover.h"
#include "tjpgd/tjpgd.h"

#define KEY_MAX     260

static pva_cover_t *cv;
static uint8_t     *work;           // TJpgDec's
static uint8_t     *out;            // PVA_COVER_SIZE
static FIL         *f;
static uint32_t     f_left;         // bytes of the picture still to read
static uint8_t      pal[32];
static uint16_t     free_mask;
static bool         set_up;
static uint8_t      state = PVA_COVER_NONE;
static uint8_t      gen;
static char         key[KEY_MAX];   // where the picture came from ("" none)
static bool         picture;        // cv->img holds the picture of key

#define WORK_SIZE   (TJPGD_WORKSPACE_SIZE + 64)
#define MEM_SIZE    (((sizeof(pva_cover_t) + 3u) & ~3u) + WORK_SIZE + PVA_COVER_SIZE + ((sizeof(FIL) + 3u) & ~3u) + 16u)

static bool    on;                  // covers are made (the memory is there when a file plays)
static uint8_t *own;                // the arena's, when it gave it

static void place(uint8_t *m)
{
    cv = (pva_cover_t *)m;
    m += (sizeof(pva_cover_t) + 3u) & ~3u;
    work = m;
    m += WORK_SIZE;
    out = m;
    m += (PVA_COVER_SIZE + 3u) & ~3u;
    f = (FIL *)m;
}

// the memory now (a file starts): NULL none
static bool mem(void)
{
    uint8_t *m = own ? own : pva_net_ring_idle(MEM_SIZE);
    if (!m) { cv = NULL; return false; }
    place(m);
    return true;
}

bool pva_art_init(void)
{
    if (pva_net_ring_idle(MEM_SIZE)) on = true;
    else if (pva_arena_free() >= MEM_SIZE + 24u * 1024u && (own = pva_alloc(MEM_SIZE))) on = true;
    return on;
}

uint8_t pva_art_state(void) { return state; }
uint8_t pva_art_gen(void) { return gen; }

static void set_state(uint8_t s)
{
    if (s != state || s != PVA_COVER_MAKING) gen++;
    state = s;
}

// ---------------------------------------------------------------- decoding
static size_t jpg_in(JDEC *jd, uint8_t *buf, size_t n)
{
    (void)jd;
    if (n > f_left) n = f_left;
    if (!buf)
    {
        if (f_lseek(f, f_tell(f) + n) != FR_OK) return 0;
        f_left -= (uint32_t)n;
        return n;
    }
    UINT br = 0;
    if (f_read(f, buf, (UINT)n, &br) != FR_OK) return 0;
    f_left -= br;
    return br;
}

static int jpg_out(JDEC *jd, void *bitmap, JRECT *r)
{
    (void)jd;
    pva_cover_block(cv, r->left, r->top, r->right - r->left + 1, r->bottom - r->top + 1, bitmap);
    return 1;
}

// the picture at pos (len bytes) of a file into cv->img
static bool decode(const char *path, uint32_t pos, uint32_t len)
{
    if (f_open(f, path, FA_READ) != FR_OK) return false;
    bool ok = false;
    if (!len) len = (uint32_t)f_size(f);
    if (f_lseek(f, pos) == FR_OK)
    {
        f_left = len;
        JDEC jd;
        JRESULT r = jd_prepare(&jd, jpg_in, work, TJPGD_WORKSPACE_SIZE + 64, NULL);
        if (r == JDR_OK)
        {
            uint8_t s = 0;          // made small while decoding: 1/2, 1/4, 1/8 as long as 80 pixels are left
            unsigned m = jd.width < jd.height ? jd.width : jd.height;
            while (s < 3 && (m >> (s + 1)) >= PVA_COVER_PX) s++;
            pva_cover_begin(cv, jd.width >> s, jd.height >> s);
            r = jd_decomp(&jd, jpg_out, s);
            if (r == JDR_OK) { pva_cover_end(cv); ok = true; }
        }
        if (!ok) pva_log("cover: %.40s: not a JPEG it can read (%d)", path, (int)r);
        else pva_log("cover: %ux%u, %.40s", jd.width, jd.height, path);
    }
    f_close(f);
    return ok;
}

// an image in the folder of the track
static bool folder_image(const char *track, char *img, size_t size)
{
    static const char *const names[] = { "cover", "folder", "front", "album", "albumart", "AlbumArtSmall" };
    static const char *const ext[] = { ".jpg", ".jpeg" };
    const char *sl = strrchr(track, '/');
    int dl = sl ? (int)(sl - track) : 0;
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++)
        for (unsigned e = 0; e < 2; e++)
        {
            snprintf(img, size, "%.*s/%s%s", dl, track, names[i], ext[e]);
            FILINFO fi;
            if (f_stat(img, &fi) == FR_OK && !(fi.fattrib & AM_DIR)) return true;
        }
    return false;
}

static void start_convert(void)
{
    pva_cover_convert_begin(cv, pal, free_mask, out);
    set_state(PVA_COVER_MAKING);
}

// a file starts (fatfs path, its tag's picture: pos, len; len 0 = none)
void pva_art_track(const char *path, uint32_t pic_pos, uint32_t pic_len)
{
    if (!on) return;
    if (!mem()) { key[0] = 0; picture = false; set_state(PVA_COVER_NONE); return; }
    char k[KEY_MAX], img[KEY_MAX];
    const char *src = NULL;
    uint32_t pos = 0, len = 0;
    if (pic_len)
    {
        snprintf(k, sizeof k, "%s#%lu", path, (unsigned long)pic_pos);
        src = path; pos = pic_pos; len = pic_len;
    }
    else if (folder_image(path, img, sizeof img))
    {
        snprintf(k, sizeof k, "%s", img);
        src = img;
    }
    else k[0] = 0;
    if (!strcmp(k, key) && (picture || !k[0])) return;     // the same picture (an album's folder image)
    snprintf(key, sizeof key, "%s", k);
    picture = src && decode(src, pos, len);
    if (picture && set_up) start_convert();
    else set_state(PVA_COVER_NONE);
}

// a stream (or nothing) plays: no cover
void pva_art_none(void)
{
    if (!on || (!key[0] && state == PVA_COVER_NONE && !cv)) return;
    cv = NULL;                          // (the ring is the stream's now)
    key[0] = 0;
    picture = false;
    set_state(PVA_COVER_NONE);
}

void pva_art_poll(void)
{
    if (state == PVA_COVER_MAKING && cv && pva_cover_convert_step(cv)) set_state(PVA_COVER_READY);
}

// ---------------------------------------------------------------- commands
int pva_art_cmd(uint8_t code, const uint8_t *args)
{
    if (!on) return PVA_E_STATE;
    if (code == PVA_C_COVER_SETUP)
    {
        uint16_t m = (uint16_t)(args[32] | args[33] << 8);
        bool changed = !set_up || memcmp(pal, args, 32) || m != free_mask;
        memcpy(pal, args, 32);
        free_mask = m;
        set_up = true;
        if (changed && picture && cv) start_convert();
        return PVA_OK;
    }
    // PVA_C_COVER_GET
    if (state == PVA_COVER_MAKING) return PVA_E_BUSY;
    if (state != PVA_COVER_READY || !cv) return PVA_E_NOTFOUND;
    for (unsigned i = 0; i < PVA_COVER_SIZE; i++) pva_reply_byte(out[i]);
    return PVA_OK;
}
