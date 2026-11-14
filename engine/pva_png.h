// MSX PICOVERSE PROJECT
// pva_png.h - a small PNG reader for the station logos: the file is fed in
// as it comes from the web (any pieces), the picture comes out a row at a
// time as RGB (transparent parts on the player's navy). No interlaced PNGs,
// rows of at most PVA_PNG_ROW bytes. Its memory (pva_png_t, about 48 KB with
// the inflate window) is the caller's.
//
// Plain C without the engine (PicoAmp for Windows and the web may use it too).
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#ifndef PVA_PNG_H
#define PVA_PNG_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "miniz/miniz.h"

#define PVA_PNG_ROW     4100u       // a row's bytes at most (1024 pixels RGBA, 2048 RGB ...)

// a row of the picture: y, w pixels of RGB
typedef void (*pva_png_row_fn)(void *ctx, int y, int w, const uint8_t *rgb);
// the size, before the first row
typedef void (*pva_png_size_fn)(void *ctx, int w, int h);

typedef struct
{
    // chunks
    uint8_t  st, hb[8];
    uint32_t hn, left;              // header bytes in hb; bytes left of the chunk's data
    char     type[5];
    uint8_t  ihdr[13];
    uint32_t ihdr_n;
    // the picture
    uint32_t w, h, y;
    uint8_t  depth, ctype, bpp;     // bits a sample, colour type, bytes a pixel (at least 1)
    uint32_t rowbytes, rowpos;
    uint8_t  pal[256][3], alpha[256];
    uint8_t  bg[3];
    bool     done, bad;
    // the data
    tinfl_decompressor inf;
    size_t   dict_ofs;
    uint8_t *dict;                  // TINFL_LZ_DICT_SIZE bytes, the caller's (may be elsewhere)
    uint8_t  cur[PVA_PNG_ROW + 1], prev[PVA_PNG_ROW + 1];
    uint8_t  rgb[PVA_PNG_ROW];      // (an RGB row: at most 1366 pixels... the row limit holds it)
    pva_png_row_fn  row_fn;
    pva_png_size_fn size_fn;
    void    *ctx;
} pva_png_t;

void pva_png_begin(pva_png_t *p, uint8_t *dict, pva_png_size_fn size, pva_png_row_fn row, void *ctx);
// 0: more, 1: the picture is complete, -1: not a PNG this reads
int  pva_png_feed(pva_png_t *p, const uint8_t *data, size_t n);
bool pva_png_is(const uint8_t *data, size_t n);     // the PNG signature

#endif
