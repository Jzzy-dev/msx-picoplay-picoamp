// MSX PICOVERSE PROJECT
// pva_news.c - PicoVerse Audio Engine: news headlines from RSS feeds, for
// PicoAmp's teletext page.
//
// The feeds are [news] feed1..feed8 in PICOAMP.INI ("Name|URL"), else a few
// world services. A feed is read as it comes in over the ESP-01 (the web
// client's slot): the <item>s' title, description and date (RSS 2.0 and RSS
// 1.0/RDF; Atom's <entry>, <summary> and <updated> too). CDATA, entities and
// the HTML in descriptions are taken out, the text is made plain ASCII, and
// up to MAX_ITEMS stories are kept in memory taken from the arena when the
// first feed is asked for.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pva_internal.h"

#define MAX_FEEDS       8u
#define MAX_ITEMS       40u
#define POOL_WANT       12288u          // the stories' text
#define POOL_MIN        2048u
#define TITLE_MAX       110u
#define TEXT_MAX        330u
#define DATE_MAX        32u
#define FIELD_MAX       700u            // a field as it comes (with HTML), before it is cleaned

static const char *const def_feeds[] = {
    "BBC World|http://feeds.bbci.co.uk/news/world/rss.xml",
    "Al Jazeera|https://www.aljazeera.com/xml/rss/all.xml",
    "DW|https://rss.dw.com/xml/rss-en-all",
    "The Guardian|https://www.theguardian.com/world/rss",
    "NOS (NL)|https://feeds.nos.nl/nosnieuwsalgemeen",
};
#define N_DEF (sizeof def_feeds / sizeof def_feeds[0])

typedef struct { uint16_t title, text, date; } item_t;
static item_t   items[MAX_ITEMS];
static uint8_t  nitems;
static bool     full;                   // no more room: the rest of the feed is left
static char    *pool;
static size_t   pool_size, pool_used;
static bool     pool_tried;
static uint8_t  st = PVA_NEWS_IDLE, feed_no = 0xFF, err;
static bool     pending;
static uint8_t  want_feed;

// the parser
enum { X_TEXT, X_TAG, X_CDATA, X_COMMENT, X_SKIP };
static uint8_t  xs;
static char     tag[24];
static uint8_t  tlen;
static bool     tag_close, tag_skip;
static uint8_t  cd_match;               // "]]>" seen so far
static char     cdpre[9];               // "![CDATA[" being matched
static uint8_t  cdpre_n;
static bool     in_item;
static uint8_t  field;                  // 1 title, 2 text, 3 date
static char    *fbuf;                   // FIELD_MAX + 1
static size_t   flen;
static char     ent[10];
static uint8_t  elen;
static bool     in_ent;
static char     f_title[TITLE_MAX + 1], f_text[TEXT_MAX + 1], f_date[DATE_MAX + 1];

// ---------------------------------------------------------------- feeds
static bool feed(uint8_t i, char *name, size_t ns, char *url, size_t us)
{
    char k[16], v[300];
    snprintf(k, sizeof k, "news.feed%u", (unsigned)(i + 1u));
    const char *src = NULL;
    if (pva_cfg_get(k, v, sizeof v) && strchr(v, '|')) src = v;
    else
    {
        // none set at all: the world services
        char t[8];
        if (pva_cfg_get("news.feed1", t, sizeof t)) return false;
        if (i >= N_DEF) return false;
        snprintf(v, sizeof v, "%s", def_feeds[i]);
        src = v;
    }
    const char *bar = strchr(src, '|');
    size_t n = (size_t)(bar - src);
    if (n >= ns) n = ns - 1;
    memcpy(name, src, n);
    name[n] = 0;
    const char *u = bar + 1;
    while (*u == ' ') u++;
    snprintf(url, us, "%s", u);
    return name[0] && (!strncmp(url, "http://", 7) || !strncmp(url, "https://", 8));
}

bool pva_news_feeds(void)
{
    char name[40], url[300];
    uint8_t n = 0;
    for (uint8_t i = 0; i < MAX_FEEDS; i++) if (feed(i, name, sizeof name, url, sizeof url)) n++;
    pva_reply_byte(n);
    for (uint8_t i = 0; i < MAX_FEEDS; i++)
        if (feed(i, name, sizeof name, url, sizeof url)) pva_reply_str(name);
    return true;
}

void pva_news_state(uint8_t *s, uint8_t *count, uint8_t *f, uint8_t *e)
{
    *s = st;
    *count = st == PVA_NEWS_DONE ? nitems : 0;
    *f = feed_no;
    *e = err;
}

// ---------------------------------------------------------------- stories
static uint16_t pool_add(const char *s)
{
    size_t n = strlen(s) + 1;
    if (pool_used + n > pool_size) return 0xFFFF;
    memcpy(pool + pool_used, s, n);
    uint16_t o = (uint16_t)pool_used;
    pool_used += n;
    return o;
}

// HTML out, entities decoded already: tags dropped, white space made one space,
// UTF-8 to plain ASCII, cut to 'size'
static void clean(char *dst, size_t size, const char *s)
{
    char *t = fbuf;                     // (in place: fbuf is the field being finished)
    size_t o = 0;
    bool sp = true, in_tag = false, pend = false;
    for (; *s && o < FIELD_MAX; s++)
    {
        char c = *s;
        // a tag is a space between words, not before punctuation ("<b>story</b>,")
        if (in_tag) { if (c == '>') { in_tag = false; pend = true; } continue; }
        if (c == '<') { in_tag = true; continue; }
        if (c == '\r' || c == '\n' || c == '\t') c = ' ';
        if (pend && c != ' ' && !sp && !strchr(".,;:!?)'\"", c) && o < FIELD_MAX) t[o++] = ' ';
        pend = false;
        if (c == ' ') { if (sp) continue; sp = true; }
        else sp = false;
        t[o++] = c;
    }
    while (o && t[o - 1] == ' ') o--;
    t[o] = 0;
    pva_copy_ascii(dst, size, t, o);
}

static void item_end(void)
{
    if (full || !f_title[0]) return;
    size_t used = pool_used;
    item_t it;
    it.title = pool_add(f_title);
    it.text = pool_add(f_text);
    it.date = pool_add(f_date);
    if (it.title == 0xFFFF || it.text == 0xFFFF || it.date == 0xFFFF) { pool_used = used; full = true; return; }
    items[nitems++] = it;
    if (nitems >= MAX_ITEMS) full = true;
}

static void field_end(void)
{
    fbuf[flen] = 0;
    static char tmp[FIELD_MAX + 1];
    memcpy(tmp, fbuf, flen + 1);
    if (field == 1) clean(f_title, sizeof f_title, tmp);
    else if (field == 2 && !f_text[0]) clean(f_text, sizeof f_text, tmp);
    else if (field == 3)
    {
        // "Thu, 29 Oct 2026 20:15:00 GMT" -> "29 Oct 2026 20:15:00 GMT"; ISO dates as they are
        const char *d = tmp;
        const char *c = strchr(d, ',');
        if (c && c - d < 5) d = c + 1;
        while (*d == ' ') d++;
        clean(f_date, sizeof f_date, d);
    }
    field = 0;
    flen = 0;
}

static void put(char c)
{
    if (field && flen < FIELD_MAX) fbuf[flen++] = c;
}

static void put_cp(uint32_t cp)
{
    if (cp < 0x80) put((char)cp);
    else if (cp < 0x800) { put((char)(0xC0 | (cp >> 6))); put((char)(0x80 | (cp & 0x3F))); }
    else if (cp < 0x10000) { put((char)(0xE0 | (cp >> 12))); put((char)(0x80 | ((cp >> 6) & 0x3F))); put((char)(0x80 | (cp & 0x3F))); }
}

static void entity(void)
{
    ent[elen] = 0;
    if (ent[0] == '#')
    {
        uint32_t cp = ent[1] == 'x' || ent[1] == 'X' ? (uint32_t)strtoul(ent + 2, NULL, 16) : (uint32_t)strtoul(ent + 1, NULL, 10);
        if (cp == 160) cp = ' ';
        else if (cp == 8216 || cp == 8217) cp = '\'';
        else if (cp == 8220 || cp == 8221) cp = '"';
        else if (cp == 8211 || cp == 8212) cp = '-';
        put_cp(cp);
    }
    else if (!strcmp(ent, "amp")) put('&');
    else if (!strcmp(ent, "lt")) put('<');
    else if (!strcmp(ent, "gt")) put('>');
    else if (!strcmp(ent, "quot")) put('"');
    else if (!strcmp(ent, "apos")) put('\'');
    else if (!strcmp(ent, "nbsp")) put(' ');
    else { put('&'); for (uint8_t i = 0; i < elen; i++) put(ent[i]); put(';'); }
}

static void text_char(char c)
{
    if (!field) return;
    if (in_ent)
    {
        if (c == ';') { in_ent = false; entity(); return; }
        if (elen < sizeof ent - 1 && c != ' ' && c != '<') { ent[elen++] = c; return; }
        in_ent = false;
        put('&');
        for (uint8_t i = 0; i < elen; i++) put(ent[i]);
    }
    if (c == '&') { in_ent = true; elen = 0; return; }
    put(c);
}

static void tag_done(void)
{
    tag[tlen] = 0;
    // the name without a namespace prefix ("dc:date" -> "date")
    const char *t = strchr(tag, ':');
    t = t ? t + 1 : tag;
    if (!tag_close)
    {
        if (!strcmp(t, "item") || !strcmp(t, "entry"))
        {
            in_item = true;
            f_title[0] = f_text[0] = f_date[0] = 0;
        }
        else if (in_item && !tag_skip)
        {
            uint8_t f = !strcmp(t, "title") ? 1 : (!strcmp(t, "description") || !strcmp(t, "summary")) ? 2 :
                        (!strcmp(t, "pubDate") || !strcmp(t, "date") || !strcmp(t, "updated")) ? 3 : 0;
            if (f) { field = f; flen = 0; in_ent = false; }
        }
    }
    else
    {
        if (field) field_end();
        if (!strcmp(t, "item") || !strcmp(t, "entry")) { in_item = false; item_end(); }
    }
}

static void xml_byte(char c)
{
    switch (xs)
    {
        case X_TEXT:
            if (c == '<') { xs = X_TAG; tlen = 0; tag_close = false; tag_skip = false; cdpre_n = 0; return; }
            text_char(c);
            return;
        case X_TAG:
            if (tlen == 0 && !tag_close && cdpre_n == 0 && c == '/') { tag_close = true; return; }
            if (tlen == 0 && !tag_close && (c == '!' || cdpre_n))
            {
                // <![CDATA[ ... ]]> or <!-- ... -->
                if (cdpre_n < 8) cdpre[cdpre_n++] = c;
                cdpre[cdpre_n] = 0;
                if (!strcmp(cdpre, "![CDATA[")) { xs = X_CDATA; cd_match = 0; return; }
                if (!strcmp(cdpre, "!--")) { xs = X_COMMENT; cd_match = 0; return; }
                if (strncmp("![CDATA[", cdpre, cdpre_n) && strncmp("!--", cdpre, cdpre_n)) xs = X_SKIP;
                return;
            }
            if (c == '?') { xs = X_SKIP; return; }
            if (c == '>' || c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '/')
            {
                if (c == '/' && !tag_close) tag_skip = true;     // <tag/>: empty
                tag_done();
                if (c == '>') { xs = X_TEXT; if (tag_skip && field) field_end(); }
                else xs = X_SKIP;
                return;
            }
            if (tlen < sizeof tag - 1) tag[tlen++] = c;
            return;
        case X_SKIP:                    // the rest of a tag (attributes)
            if (c == '/') tag_skip = true;
            else if (c == '>') { xs = X_TEXT; if (tag_skip && field && !tag_close) field_end(); }
            else tag_skip = false;
            return;
        case X_CDATA:
            if (c == ']') { if (cd_match < 2) cd_match++; else put(']'); return; }
            if (c == '>' && cd_match == 2) { xs = X_TEXT; return; }
            while (cd_match) { put(']'); cd_match--; }
            put(c);
            return;
        case X_COMMENT:
            if (c == '-') { if (cd_match < 2) cd_match++; return; }
            if (c == '>' && cd_match == 2) { xs = X_TEXT; return; }
            cd_match = 0;
            return;
    }
}

static bool body(const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) xml_byte((char)p[i]);
    return full;                        // enough
}

static void fetch_done(bool ok)
{
    if (ok || nitems)
    {
        st = PVA_NEWS_DONE;
        err = 0;
    }
    else
    {
        st = PVA_NEWS_FAILED;
        err = pva_web_error() ? pva_web_error() : PVA_NERR_HTTP;
    }
    pva_log("news: %u stories (%s)", (unsigned)nitems, ok ? "ok" : "failed");
}

// ---------------------------------------------------------------- commands
int pva_news_fetch(uint8_t f)
{
    char name[40], url[300];
    if (!feed(f, name, sizeof name, url, sizeof url)) return PVA_E_RANGE;
    if (!pva_hal_net_present()) return PVA_E_NOWIFI;
    if (!pool && !pool_tried)
    {
        pool_tried = true;
        size_t fr = pva_arena_free();
        size_t want = POOL_WANT + FIELD_MAX + 1u;
        if (fr > want + 2048u) pool_size = POOL_WANT;
        else if (fr > POOL_MIN + FIELD_MAX + 1u + 1024u) pool_size = fr - FIELD_MAX - 1u - 1024u;   // (the Nextor modes: less)
        else pool_size = 0;
        if (pool_size)
        {
            fbuf = pva_alloc(FIELD_MAX + 1u);
            pool = fbuf ? pva_alloc(pool_size) : NULL;
        }
        if (!pool) pva_log("news: no memory");
    }
    if (!pool) { st = PVA_NEWS_NOMEM; return PVA_E_FULL; }
    want_feed = f;
    pending = true;
    st = PVA_NEWS_LOADING;
    feed_no = f;
    err = 0;
    return PVA_OK;
}

void pva_news_poll(void)
{
    if (!pending || pva_web_busy()) return;
    pending = false;
    char name[40], url[300];
    if (!feed(want_feed, name, sizeof name, url, sizeof url)) { st = PVA_NEWS_FAILED; return; }
    nitems = 0;
    pool_used = 0;
    full = false;
    xs = X_TEXT;
    in_item = false;
    field = 0;
    flen = 0;
    in_ent = false;
    if (pva_web_get(url, body, fetch_done) != PVA_OK) { st = PVA_NEWS_FAILED; err = PVA_NERR_NOWIFI; }
}

int pva_news_list(uint8_t first, uint8_t count)
{
    if (st != PVA_NEWS_DONE) return PVA_E_STATE;
    for (uint8_t i = first; i < nitems && count; i++, count--) pva_reply_str(pool + items[i].title);
    return PVA_OK;
}

int pva_news_item(uint8_t i)
{
    if (st != PVA_NEWS_DONE || i >= nitems) return PVA_E_RANGE;
    pva_reply_str(pool + items[i].title);
    pva_reply_str(pool + items[i].text);
    pva_reply_str(pool + items[i].date);
    return PVA_OK;
}
