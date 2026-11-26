// MSX PICOVERSE PROJECT
// pva_xml.h - PicoVerse Audio Engine: a small streaming XML reader, for the
// UPnP answers (pva_sonos.c, pva_media.c). Header only: each file has its own copy.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#ifndef PVA_XML_H
#define PVA_XML_H

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

// Text and attribute values come character by character (entities decoded, as
// UTF-8); a tag's end says which tag it was. The text of a SOAP answer's
// element that holds XML (escaped) goes into a second reader.
typedef struct sx sx_t;
struct sx
{
    void   (*text)(sx_t *x, char c);    // a character of the text of element x->el
    void   (*attr)(sx_t *x, char c);    // a character of the value of attribute x->an of tag x->tag
    void   (*tagend)(sx_t *x);          // a tag ended: x->tag, x->closing, x->empty
    uint8_t st, tl, al, entl;
    char    q;
    bool    closing, empty;
    char    tag[24], an[20], el[24], ent[10];
};
enum { SX_TEXT, SX_TAG, SX_IN, SX_ANAME, SX_AEQ, SX_AVAL, SX_SKIP };

static void sx_reset(sx_t *x)
{
    x->st = SX_TEXT;
    x->tl = x->al = x->entl = 0;
    x->el[0] = x->tag[0] = x->an[0] = 0;
}

static void sx_emit(sx_t *x, char c)
{
    if (x->st == SX_AVAL) { if (x->attr) x->attr(x, c); }
    else if (x->text && x->el[0]) x->text(x, c);
}

static void sx_utf8(sx_t *x, uint32_t c)
{
    if (c < 0x80) sx_emit(x, (char)c);
    else if (c < 0x800) { sx_emit(x, (char)(0xC0 | (c >> 6))); sx_emit(x, (char)(0x80 | (c & 63))); }
    else if (c < 0x10000) { sx_emit(x, (char)(0xE0 | (c >> 12))); sx_emit(x, (char)(0x80 | ((c >> 6) & 63))); sx_emit(x, (char)(0x80 | (c & 63))); }
}

static void sx_entity(sx_t *x)
{
    const char *e = x->ent;
    x->ent[x->entl] = 0;
    x->entl = 0;
    if (!strcmp(e, "lt")) sx_emit(x, '<');
    else if (!strcmp(e, "gt")) sx_emit(x, '>');
    else if (!strcmp(e, "amp")) sx_emit(x, '&');
    else if (!strcmp(e, "quot")) sx_emit(x, '"');
    else if (!strcmp(e, "apos")) sx_emit(x, '\'');
    else if (e[0] == '#') sx_utf8(x, (uint32_t)(e[1] == 'x' || e[1] == 'X' ? strtoul(e + 2, NULL, 16) : strtoul(e + 1, NULL, 10)));
}

static bool sx_space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

static void sx_tag_done(sx_t *x)
{
    x->tag[x->tl] = 0;
    if (x->closing) x->el[0] = 0;
    else if (!x->empty) memcpy(x->el, x->tag, sizeof x->el);
    x->st = SX_TEXT;
    if (x->tagend) x->tagend(x);
}

static void sx_byte(sx_t *x, char c)
{
    if (x->entl)
    {
        if (c == ';') { x->entl--; sx_entity(x); return; }
        if (x->entl < sizeof x->ent) { x->ent[x->entl - 1] = c; x->entl++; return; }
        x->entl = 0;                    // (not an entity: dropped)
    }
    switch (x->st)
    {
        case SX_TEXT:
            if (c == '<') { x->st = SX_TAG; x->tl = 0; x->closing = x->empty = false; }
            else if (c == '&') x->entl = 1;
            else sx_emit(x, c);
            return;
        case SX_TAG:
            if (!x->tl && c == '/') x->closing = true;
            else if (!x->tl && !x->closing && (c == '?' || c == '!')) x->st = SX_SKIP;
            else if (c == '>') sx_tag_done(x);
            else if (c == '/') { x->empty = true; x->st = SX_IN; }
            else if (sx_space(c)) { if (x->tl) { x->tag[x->tl] = 0; x->st = SX_IN; } }
            else if (c == ':') x->tl = 0;
            else if (x->tl + 1u < sizeof x->tag) x->tag[x->tl++] = c;
            return;
        case SX_IN:
            if (c == '>') sx_tag_done(x);
            else if (c == '/') x->empty = true;
            else if (!sx_space(c)) { x->st = SX_ANAME; x->al = 0; x->an[x->al++] = c; }
            return;
        case SX_ANAME:
            if (c == '=') { x->an[x->al] = 0; x->st = SX_AEQ; }
            else if (c == '>') sx_tag_done(x);
            else if (c == ':') x->al = 0;
            else if (!sx_space(c) && x->al + 1u < sizeof x->an) x->an[x->al++] = c;
            return;
        case SX_AEQ:
            if (c == '"' || c == '\'') { x->q = c; x->st = SX_AVAL; }
            return;
        case SX_AVAL:
            if (c == x->q) x->st = SX_IN;
            else if (c == '&') x->entl = 1;
            else sx_emit(x, c);
            return;
        default:
            if (c == '>') x->st = SX_TEXT;
            return;
    }
}

static void put_c(char *b, size_t size, char c)
{
    size_t n = strlen(b);
    if (n + 1 < size) { b[n] = c; b[n + 1] = 0; }
}

#endif
