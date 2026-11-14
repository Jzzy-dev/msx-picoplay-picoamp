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
// A station's logo (engine 0.15): Radio Browser is asked for the station
// (by its uuid when it came from the directory, else by its address, else by
// its name), its "favicon" is fetched (PNG or JPEG) and made a cover as a
// picture is. That needs the stream ring too, so it is done before the
// stream starts (PICOAMP's state stays LOADING meanwhile, 6 s at most), and
// the result is kept on the card (PICOAMP/LOGOS/xxxxxxxx.LGO, 1.6 KB): the
// next time the station starts at once, and COVER_GET reads the cover from
// there while the stream has the ring. Only where the engine may write the
// card (the PicoAmp ROM); a station that has no logo is kept as such.
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
#include "pva_png.h"

#define KEY_MAX     260

static pva_cover_t *cv;
static uint8_t     *work;           // TJpgDec's
static uint8_t     *out;            // PVA_COVER_SIZE
static FIL         *f;
static uint32_t     f_left;         // bytes of the picture still to read
static const uint8_t *m_src;        // (or from memory: a logo's JPEG)
static size_t       m_len, m_pos;
static uint8_t      pal[32];
static uint16_t     free_mask;
static bool         set_up;
static uint8_t      state = PVA_COVER_NONE;
static uint8_t      gen;
static char         key[KEY_MAX];   // where the picture came from ("" none)
static bool         picture;        // cv->img holds the picture of key

#define WORK_SIZE   (TJPGD_WORKSPACE_SIZE + 64)
#define MEM_SIZE    (((sizeof(pva_cover_t) + 3u) & ~3u) + WORK_SIZE + PVA_COVER_SIZE + ((sizeof(FIL) + 3u) & ~3u) + 16u)
#define MEM_LOGO    (MEM_SIZE + TINFL_LZ_DICT_SIZE + 8u)     // and a PNG's dictionary (or a JPEG's bytes);
                                                            // the PNG reader itself: the MP3 decoder's pool

static bool    on;                  // covers are made (the memory is there when a file plays)
static uint8_t *own;                // the arena's, when it gave it

static uint8_t *logo_mem;           // after f: a PNG reader or a JPEG's bytes

static void place(uint8_t *m)
{
    cv = (pva_cover_t *)m;
    m += (sizeof(pva_cover_t) + 3u) & ~3u;
    work = m;
    m += WORK_SIZE;
    out = m;
    m += (PVA_COVER_SIZE + 3u) & ~3u;
    f = (FIL *)m;
    m += (sizeof(FIL) + 3u) & ~3u;
    logo_mem = (uint8_t *)(((uintptr_t)m + 7u) & ~(uintptr_t)7u);
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
    if (m_src)
    {
        if (n > m_len - m_pos) n = m_len - m_pos;
        if (buf) memcpy(buf, m_src + m_pos, n);
        m_pos += n;
        return n;
    }
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
    m_src = NULL;
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
static void logo_end(void);
static bool    from_card;           // the cover is the card's (a station's logo): COVER_GET reads it there
static char    card_path[40];

void pva_art_track(const char *path, uint32_t pic_pos, uint32_t pic_len)
{
    if (!on) return;
    logo_end();
    from_card = false;
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
    logo_end();
    from_card = false;
    if (!on || (!key[0] && state == PVA_COVER_NONE && !cv)) return;
    cv = NULL;                          // (the ring is the stream's now)
    key[0] = 0;
    picture = false;
    set_state(PVA_COVER_NONE);
}

static void logo_poll(void);
static void logo_made(void);

void pva_art_poll(void)
{
    logo_poll();
    if (state == PVA_COVER_MAKING && cv && pva_cover_convert_step(cv))
    {
        set_state(PVA_COVER_READY);
        logo_made();
    }
}

// ---------------------------------------------------------------- a station's logo
#define LGO_HEAD    12u             // "PVLG", version, kind, 0, 0, u32 the palette's hash
#define LOGO_MS     6000u           // the stream waits for the logo this long at most
#define RB_BASE     "http://all.api.radio-browser.info/json/stations/"

enum { L_IDLE, L_WAITWEB, L_LOOKUP, L_FETCH, L_CONVERT };
static uint8_t  l_state;
static uint8_t  l_try;              // 0 the uuid (or the address), 1 the address, 2 the name
static uint8_t  l_gen;              // (a done callback of an older job is not ours)
static uint32_t l_t0;
static const char *l_url, *l_uuid, *l_name;   // (the engine's, kept while the stream waits)
static char     l_q[384];           // the request asked for next (and the logo's address, as it is read)
#define fav     l_q
static uint8_t  fav_st;             // reading "favicon":"...": 0 looking, 1 in it, 2 done
static char     roll[12];           // (the last bytes, to find "favicon":")
static bool     looked_ok;          // Radio Browser answered (no logo: kept as such)
static uint8_t  img_kind;           // 0 not yet, 1 PNG, 2 JPEG, 3 neither
static uint32_t img_len;
static bool     img_ok;
static bool     l_img;
static uint32_t logo_max;           // a JPEG logo's bytes at most              // the next request is the logo (else a question to Radio Browser)

bool pva_card_writes(void);
#define card_fil (*pva_dec_fil())       // (the decoder's: no file plays when a station does)

static uint32_t fnv(const void *p, size_t n, uint32_t h)
{
    for (size_t i = 0; i < n; i++) { h ^= ((const uint8_t *)p)[i]; h *= 16777619u; }
    return h;
}
static uint32_t pal_hash(void) { return fnv(&free_mask, 2, fnv(pal, 32, 2166136261u)); }

static void enc(char *o, size_t size, const char *s)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t k = 0;
    for (; *s && k + 4 < size; s++)
    {
        unsigned char c = (unsigned char)*s;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') o[k++] = (char)c;
        else { o[k++] = '%'; o[k++] = hex[c >> 4]; o[k++] = hex[c & 15]; }
    }
    o[k] = 0;
}

// the card's file: what is known of this station's logo (none, or the cover)
static void card_write(uint8_t kind)
{
    if (!pva_card_writes()) return;
    f_mkdir("0:/PICOAMP");
    f_mkdir("0:/PICOAMP/LOGOS");
    if (f_open(&card_fil, card_path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) return;
    uint8_t h[LGO_HEAD] = { 'P', 'V', 'L', 'G', 1, kind, 0, 0 };
    uint32_t ph = pal_hash();
    memcpy(h + 8, &ph, 4);
    UINT bw;
    bool ok = f_write(&card_fil, h, LGO_HEAD, &bw) == FR_OK && bw == LGO_HEAD;
    if (ok && kind == PVA_COVER_READY) ok = f_write(&card_fil, out, PVA_COVER_SIZE, &bw) == FR_OK && bw == PVA_COVER_SIZE;
    f_close(&card_fil);
    if (!ok) f_unlink(card_path);
    else pva_log("logo: kept %s (%s)", card_path + 17, kind == PVA_COVER_READY ? "cover" : "none");
}

// 1: the card has the cover, 0: it knows there is none, -1: it knows nothing (or for another palette)
static int card_read(void)
{
    if (f_open(&card_fil, card_path, FA_READ) != FR_OK) return -1;
    uint8_t h[LGO_HEAD];
    UINT br = 0;
    int r = -1;
    if (f_read(&card_fil, h, LGO_HEAD, &br) == FR_OK && br == LGO_HEAD && !memcmp(h, "PVLG", 4) && h[4] == 1)
    {
        uint32_t ph;
        memcpy(&ph, h + 8, 4);
        if (h[5] != PVA_COVER_READY) r = 0;
        else if (ph == pal_hash() && f_size(&card_fil) >= LGO_HEAD + PVA_COVER_SIZE) r = 1;
    }
    f_close(&card_fil);
    return r;
}

static void logo_end(void)
{
    if (l_state == L_IDLE) return;
    l_gen++;
    if (state == PVA_COVER_MAKING) set_state(PVA_COVER_NONE);   // (half made: the ring goes to the stream)
    l_state = L_IDLE;
    cv = NULL;
}

bool pva_art_station_busy(void) { return l_state != L_IDLE; }
void pva_art_station_cancel(void) { if (l_state != L_IDLE) pva_log("logo: given up"); logo_end(); }

// the answer about the station: its "favicon"
static bool lk_body(const uint8_t *p, size_t n)
{
    if (l_state != L_LOOKUP) return true;   // (a job given up: its request ends)
    for (size_t i = 0; i < n && fav_st < 2; i++)
    {
        char c = (char)p[i];
        if (fav_st == 0)
        {
            memmove(roll, roll + 1, sizeof roll - 2);
            roll[sizeof roll - 2] = c;
            roll[sizeof roll - 1] = 0;
            if (!memcmp(roll + 1, "favicon\":\"", 10)) { fav_st = 1; fav[0] = 0; }
        }
        else if (c == '"') fav_st = 2;
        else if (c != '\\')                    // ("\/" in JSON: "/")
        {
            size_t k = strlen(fav);
            if (k + 1 < sizeof fav) { fav[k] = c; fav[k + 1] = 0; }
        }
    }
    return fav_st == 2;
}

static void lk_done(bool ok)
{
    if (l_state != L_LOOKUP) return;
    if (ok) looked_ok = true;
    l_state = L_WAITWEB;                    // (the next request: logo_poll)
    if (fav_st == 2 && (!strncmp(fav, "http://", 7) || !strncmp(fav, "https://", 8)))
    {
        l_img = true;
        img_kind = 0;
        img_len = 0;
        img_ok = false;
        return;
    }
    fav[0] = 0;
    // not found that way: the next way
    char e[300];
    while (++l_try <= 2)
    {
        if (l_try == 1 && l_uuid[0]) { enc(e, sizeof e, l_url); snprintf(l_q, sizeof l_q, RB_BASE "byurl?url=%s", e); return; }
        if (l_try == 2 && l_name[0])
        {
            enc(e, sizeof e, l_name);
            snprintf(l_q, sizeof l_q, RB_BASE "search?name=%s&nameExact=true&limit=1&order=votes&reverse=true&hidebroken=true", e);
            return;
        }
    }
    // no logo for it
    if (looked_ok) card_write(PVA_COVER_NONE);
    logo_end();
}

static void png_size(void *ctx, int w, int h) { (void)ctx; pva_cover_begin(cv, w, h); }
static void png_row(void *ctx, int y, int w, const uint8_t *rgb) { (void)ctx; pva_cover_block(cv, 0, y, w, 1, rgb); }

// the logo itself: a PNG read as it comes, a JPEG kept until it is all there
static bool img_body(const uint8_t *p, size_t n)
{
    if (l_state != L_FETCH) return true;    // (given up: the ring may be the stream's already)
    pva_png_t *png = pva_dec_scratch(sizeof(pva_png_t));
    if (!img_kind)
    {
        if (pva_png_is(p, n) && png) { img_kind = 1; pva_png_begin(png, logo_mem, png_size, png_row, NULL); }
        else if (n >= 2 && p[0] == 0xFF && p[1] == 0xD8) img_kind = 2;
        else { img_kind = 3; return true; }
    }
    if (img_kind == 1)
    {
        int r = pva_png_feed(png, p, n);
        if (r < 0) { img_kind = 3; return true; }
        if (r > 0) { img_ok = true; return true; }
        return false;
    }
    if (img_kind == 2)
    {
        if (img_len + n > logo_max) { img_kind = 3; return true; }
        memcpy(logo_mem + img_len, p, n);
        img_len += (uint32_t)n;
        return false;
    }
    return true;
}

static void img_done(bool ok)
{
    if (l_state != L_FETCH) return;
    if (img_kind == 2 && ok)
    {
        m_src = logo_mem; m_len = img_len; m_pos = 0;
        JDEC jd;
        if (jd_prepare(&jd, jpg_in, work, WORK_SIZE, NULL) == JDR_OK)
        {
            uint8_t sc = 0;
            unsigned m = jd.width < jd.height ? jd.width : jd.height;
            while (sc < 3 && (m >> (sc + 1)) >= PVA_COVER_PX) sc++;
            pva_cover_begin(cv, jd.width >> sc, jd.height >> sc);
            img_ok = jd_decomp(&jd, jpg_out, sc) == JDR_OK;
        }
        m_src = NULL;
    }
    if (img_ok)
    {
        pva_cover_end(cv);
        l_state = L_CONVERT;
        pva_cover_convert_begin(cv, pal, free_mask, out);
        set_state(PVA_COVER_MAKING);
        return;
    }
    pva_log("logo: %s", img_kind == 3 ? "not a PNG or JPEG it reads" : "not fetched");
    if (img_kind == 3 || (img_kind && ok)) card_write(PVA_COVER_NONE);
    logo_end();
}

// a cover made from the logo: onto the card, from there on
static void logo_made(void)
{
    if (l_state != L_CONVERT) return;
    card_write(PVA_COVER_READY);
    from_card = card_read() == 1;
    if (!from_card) set_state(PVA_COVER_NONE);      // (the card did not take it: the ring goes to the stream)
    logo_end();
}

static void logo_poll(void)
{
    if (l_state == L_IDLE) return;
    if (pva_hal_millis() - l_t0 > LOGO_MS)
    {
        pva_log("logo: too slow, the station starts");
        logo_end();
        return;
    }
    if (l_state == L_WAITWEB)
    {
        bool img = l_img;
        if (pva_web_get(l_q, img ? img_body : lk_body, img ? img_done : lk_done) == PVA_OK)
        {
            l_state = img ? L_FETCH : L_LOOKUP;
            if (!img) { fav_st = 0; memset(roll, 0, sizeof roll); }
        }
        else if (!pva_web_busy()) { logo_end(); }       // (no WiFi)
    }
    else if (l_state == L_CONVERT && state == PVA_COVER_MAKING && cv)
    {
        // the stream waits: a few steps at a time
        for (int i = 0; i < 4 && state == PVA_COVER_MAKING; i++)
            if (pva_cover_convert_step(cv)) { set_state(PVA_COVER_READY); logo_made(); }
    }
}

bool pva_art_station(const char *url, const char *uuid, const char *name)
{
    logo_end();
    key[0] = 0;
    picture = false;
    from_card = false;
    if (!on || !set_up || !pva_card_writes()) { if (state != PVA_COVER_NONE || cv) set_state(PVA_COVER_NONE); cv = NULL; return true; }
    cv = NULL;
    snprintf(card_path, sizeof card_path, "0:/PICOAMP/LOGOS/%08lX.LGO", (unsigned long)fnv(url, strlen(url), 2166136261u));
    int known = card_read();
    if (known == 1) { from_card = true; set_state(PVA_COVER_READY); return true; }
    set_state(PVA_COVER_NONE);
    if (known == 0) return true;
    // not known yet: asked, fetched and made now, while the ring is free
    uint8_t *m = pva_net_ring_idle(MEM_LOGO);
    if (!m) return true;
    place(m);
    logo_max = (uint32_t)(m + pva_net_capacity() - logo_mem);
    l_url = url;
    l_uuid = uuid ? uuid : "";
    l_name = name ? name : "";
    char e[300];
    l_try = 0;
    if (l_uuid[0]) snprintf(l_q, sizeof l_q, RB_BASE "byuuid/%s", l_uuid);
    else { l_try = 1; enc(e, sizeof e, l_url); snprintf(l_q, sizeof l_q, RB_BASE "byurl?url=%s", e); }
    l_img = false;
    looked_ok = false;
    l_gen++;
    l_t0 = pva_hal_millis();
    l_state = L_WAITWEB;
    pva_log("logo: asking for %.40s", url);
    return false;
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
    if (state != PVA_COVER_READY) return PVA_E_NOTFOUND;
    if (from_card)
    {
        // a station's logo: from the card (the stream has the ring)
        FIL *cf = pva_dec_fil();            // (not f: that is in the ring)
        if (f_open(cf, card_path, FA_READ) != FR_OK) return PVA_E_NOTFOUND;
        uint8_t b[64];
        UINT br = 0;
        bool ok = f_lseek(cf, LGO_HEAD) == FR_OK;
        for (unsigned i = 0; ok && i < PVA_COVER_SIZE; i += br)
        {
            if (f_read(cf, b, sizeof b, &br) != FR_OK || !br) { ok = false; break; }
            for (UINT k = 0; k < br && i + k < PVA_COVER_SIZE; k++) pva_reply_byte(b[k]);
        }
        f_close(cf);
        return ok ? PVA_OK : PVA_E_IO;
    }
    if (!cv) return PVA_E_NOTFOUND;
    for (unsigned i = 0; i < PVA_COVER_SIZE; i++) pva_reply_byte(out[i]);
    return PVA_OK;
}
