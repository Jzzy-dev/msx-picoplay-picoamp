// MSX PICOVERSE PROJECT
// pva_png.c - a small PNG reader for the station logos (see pva_png.h).
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <string.h>
#include "pva_png.h"

static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', 13, 10, 26, 10 };

bool pva_png_is(const uint8_t *d, size_t n) { return n >= 8 && !memcmp(d, sig, 8); }

enum { S_SIG, S_HEAD, S_DATA, S_CRC, S_END };

void pva_png_begin(pva_png_t *p, uint8_t *dict, pva_png_size_fn size, pva_png_row_fn row, void *ctx)
{
    memset(p, 0, offsetof(pva_png_t, inf));
    tinfl_init(&p->inf);
    p->dict = dict;
    p->dict_ofs = 0;
    p->size_fn = size;
    p->row_fn = row;
    p->ctx = ctx;
    p->bg[0] = 0; p->bg[1] = 0; p->bg[2] = 73;          // the player's navy (under transparent parts)
    memset(p->alpha, 255, sizeof p->alpha);
}

static uint32_t be32(const uint8_t *b) { return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; }

static bool header(pva_png_t *p)
{
    p->w = be32(p->ihdr);
    p->h = be32(p->ihdr + 4);
    p->depth = p->ihdr[8];
    p->ctype = p->ihdr[9];
    if (p->ihdr[12] || !p->w || !p->h || p->w > 8192 || p->h > 8192) return false;      // (interlaced: no)
    static const uint8_t chans[7] = { 1, 0, 3, 1, 2, 0, 4 };
    if (p->ctype > 6 || !chans[p->ctype]) return false;
    uint32_t bits = (uint32_t)chans[p->ctype] * p->depth;
    if (p->depth != 1 && p->depth != 2 && p->depth != 4 && p->depth != 8 && p->depth != 16) return false;
    p->rowbytes = (p->w * bits + 7) / 8;
    if (p->rowbytes > PVA_PNG_ROW || p->w * 3 > PVA_PNG_ROW) return false;
    p->bpp = (uint8_t)(bits >= 8 ? bits / 8 : 1);
    if (p->size_fn) p->size_fn(p->ctx, (int)p->w, (int)p->h);
    return true;
}

static uint8_t paeth(int a, int b, int c)
{
    int pp = a + b - c, pa = pp > a ? pp - a : a - pp, pb = pp > b ? pp - b : b - pp, pc = pp > c ? pp - c : c - pp;
    return (uint8_t)(pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
}

// a whole row in cur (its filter byte first): unfiltered, to RGB, out
static void row_done(pva_png_t *p)
{
    uint8_t f = p->cur[0], *r = p->cur + 1, *q = p->prev + 1;
    uint32_t n = p->rowbytes, b = p->bpp;
    for (uint32_t i = 0; i < n; i++)
    {
        int a = i >= b ? r[i - b] : 0, up = q[i], c = i >= b ? q[i - b] : 0;
        switch (f)
        {
        case 1: r[i] = (uint8_t)(r[i] + a); break;
        case 2: r[i] = (uint8_t)(r[i] + up); break;
        case 3: r[i] = (uint8_t)(r[i] + ((a + up) >> 1)); break;
        case 4: r[i] = (uint8_t)(r[i] + paeth(a, up, c)); break;
        default: break;
        }
    }
    uint8_t *o = p->rgb;
    int d = p->depth;
    for (uint32_t x = 0; x < p->w; x++)
    {
        int R, G, B, A = 255;
        if (d < 8)                                          // grey or palette, 1-4 bits
        {
            uint32_t bit = x * (uint32_t)d;
            int v = (r[bit >> 3] >> (8 - d - (int)(bit & 7))) & ((1 << d) - 1);
            if (p->ctype == 3) { R = p->pal[v][0]; G = p->pal[v][1]; B = p->pal[v][2]; A = p->alpha[v]; }
            else { R = G = B = v * 255 / ((1 << d) - 1); }
        }
        else
        {
            const uint8_t *s = r + x * b;
            int st = d == 16 ? 2 : 1;                       // (16 bits: the high byte)
            switch (p->ctype)
            {
            case 0: R = G = B = s[0]; break;
            case 2: R = s[0]; G = s[st]; B = s[2 * st]; break;
            case 3: R = p->pal[s[0]][0]; G = p->pal[s[0]][1]; B = p->pal[s[0]][2]; A = p->alpha[s[0]]; break;
            case 4: R = G = B = s[0]; A = s[st]; break;
            default: R = s[0]; G = s[st]; B = s[2 * st]; A = s[3 * st]; break;
            }
        }
        if (A < 255)
        {
            R = (R * A + p->bg[0] * (255 - A)) / 255;
            G = (G * A + p->bg[1] * (255 - A)) / 255;
            B = (B * A + p->bg[2] * (255 - A)) / 255;
        }
        *o++ = (uint8_t)R; *o++ = (uint8_t)G; *o++ = (uint8_t)B;
    }
    if (p->row_fn) p->row_fn(p->ctx, (int)p->y, (int)p->w, p->rgb);
    memcpy(p->prev, p->cur, p->rowbytes + 1);
    if (++p->y >= p->h) p->done = true;
}

// image data (from IDAT chunks): inflated into the window, rows taken from it
static bool idat(pva_png_t *p, const uint8_t *in, size_t n, bool last)
{
    while (!p->done)
    {
        size_t in_n = n, out_n = TINFL_LZ_DICT_SIZE - p->dict_ofs;
        tinfl_status s = tinfl_decompress(&p->inf, in, &in_n, p->dict, p->dict + p->dict_ofs, &out_n,
                                          TINFL_FLAG_PARSE_ZLIB_HEADER | (last ? 0 : TINFL_FLAG_HAS_MORE_INPUT));
        in += in_n;
        n -= in_n;
        for (size_t i = 0; i < out_n && !p->done; i++)
        {
            p->cur[p->rowpos++] = p->dict[p->dict_ofs + i];
            if (p->rowpos == p->rowbytes + 1) { p->rowpos = 0; row_done(p); }
        }
        p->dict_ofs = (p->dict_ofs + out_n) & (TINFL_LZ_DICT_SIZE - 1);
        if (s < TINFL_STATUS_DONE) return false;
        if (s == TINFL_STATUS_DONE) return true;
        if (s == TINFL_STATUS_NEEDS_MORE_INPUT && !n) return true;
        if (!n && !out_n) return true;
    }
    return true;
}

int pva_png_feed(pva_png_t *p, const uint8_t *d, size_t n)
{
    while (n && !p->bad && !p->done)
    {
        if (p->st == S_SIG)
        {
            while (n && p->hn < 8) { if (*d != sig[p->hn]) { p->bad = true; break; } p->hn++; d++; n--; }
            if (p->hn == 8) { p->st = S_HEAD; p->hn = 0; }
        }
        else if (p->st == S_HEAD)
        {
            while (n && p->hn < 8) { p->hb[p->hn++] = *d++; n--; }
            if (p->hn < 8) break;
            p->left = be32(p->hb);
            memcpy(p->type, p->hb + 4, 4);
            p->type[4] = 0;
            p->hn = 0;
            p->st = S_DATA;
            if (!memcmp(p->type, "IEND", 4)) { p->st = S_END; break; }
        }
        else if (p->st == S_DATA)
        {
            size_t k = n < p->left ? n : p->left;
            if (!memcmp(p->type, "IHDR", 4))
            {
                for (size_t i = 0; i < k; i++) if (p->ihdr_n < 13) p->ihdr[p->ihdr_n++] = d[i];
                if (k == p->left && !header(p)) { p->bad = true; break; }
            }
            else if (!memcmp(p->type, "PLTE", 4))
            {
                for (size_t i = 0; i < k; i++)
                {
                    uint32_t at = 0;
                    // (the byte's place in the chunk: the bytes before it in this chunk)
                    at = (uint32_t)(p->hn + i);
                    if (at < 768) p->pal[at / 3][at % 3] = d[i];
                }
                p->hn += (uint32_t)k;
            }
            else if (!memcmp(p->type, "tRNS", 4) && p->ctype == 3)
            {
                for (size_t i = 0; i < k; i++) if (p->hn + i < 256) p->alpha[p->hn + i] = d[i];
                p->hn += (uint32_t)k;
            }
            else if (!memcmp(p->type, "IDAT", 4))
            {
                if (!p->w || !idat(p, d, k, false)) { p->bad = true; break; }
            }
            d += k;
            n -= k;
            p->left -= (uint32_t)k;
            if (!p->left) { p->st = S_CRC; p->hn = 0; }
        }
        else if (p->st == S_CRC)
        {
            while (n && p->hn < 4) { p->hn++; d++; n--; }
            if (p->hn == 4) { p->st = S_HEAD; p->hn = 0; }
        }
        else break;
    }
    if (p->bad) return -1;
    return p->done ? 1 : 0;
}
