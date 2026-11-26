// MSX PICOVERSE PROJECT
// pva_media.c - PicoVerse Audio Engine: Network, the music on other computers
// in the house, as folders (the engine's "Network" folder in the root).
//
// Two kinds of source:
//  - PicoAmp for Windows (the MSX link's PC): /music/list?path=a/b gives a
//    folder's folders and files, a line each ("d name", "f name"), and
//    /music/file?path=a/b/c.mp3 a song (Range: seeking). Its address comes from
//    the engine ([network] pc = in PICOAMP.INI, a favourite on port 8765, the
//    MSX link that plays).
//  - UPnP / DLNA media servers (a NAS, Windows Media Player's sharing, Plex,
//    Jellyfin, MiniDLNA, Serviio, Twonky, ...): an SSDP M-SEARCH for
//    MediaServer:1 over UDP (as the Sonos search, through the ESP-01's UDP
//    functions), then each one's description (its name, its ContentDirectory's
//    control URL), and ContentDirectory Browse for a folder (its containers, and
//    its MP3 and WAV items: title, artist, album, size, the song's address),
//    100 entries at a time.
// A folder's entries go into the station directory's results (as the Sonos
// rooms do): name, address (a song's, a server folder's ID, a PC folder's
// name), "d" for a folder or "f" M/W artist 1F album for a song, and the size
// in KB. The engine makes its list of them and plays the songs as streams with
// a length (pva_net_start_file, pva_dec_open_remote).
//
// Memory: the work memory is the directory's cache (as the Sonos search's; the
// countries are asked again after), checked by a magic number: what else used
// it meanwhile makes the sources be searched again. No static RAM (the
// firmware's heap needs that); the search's UDP slot is the Sonos search's.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pva_internal.h"
#include "pva_xml.h"

#define MAGIC           0x4E455431u     // "NET1"
#define MAX_SRV         6u              // media servers kept
#define NAME_LEN        40u
#define LOC_LEN         112u
#define STK_LEN         320u
#define TPATH_LEN       160u
#define PAGE            100u            // a server's folder: so many entries at a time
#define SEARCH_MS       2000u           // the servers' answers, at most
#define T_UDP_MS        3000u
#define SEP             '\x1e'          // between the folders of the way down

typedef struct
{
    uint32_t magic;
    sx_t     a, b;                      // the SOAP answer; the DIDL-Lite inside it (or a description)
    // the job
    uint8_t  st, err, d, uconn, sends, ci, ncand, nsrv, job, src;
    int8_t   web_st;                    // our web request: 0 none, -1 it runs, 1 done, 2 failed
    bool     held, full, have_pc, d_named, art_lock, title_lock, found;
    uint16_t dlen, start, got, total, returned;
    uint32_t t0, sent, rcv_at;
    // the sources: [0] the PC (when its address is known), then the servers
    char     srv_name[MAX_SRV + 1][NAME_LEN];
    char     srv_ctl[MAX_SRV + 1][LOC_LEN];     // ContentDirectory's control URL; the PC's "http://ip:port"
    char     cand[MAX_SRV][96];                 // the search's answers: their descriptions
    // the way down from the source's top: IDs (a server) or names (the PC), and their names
    char     stk[STK_LEN], tpath[TPATH_LEN];
    char     n_stk[STK_LEN], n_tpath[TPATH_LEN];  // the job's: taken when it worked
    // a description being read
    char     d_name[NAME_LEN], d_type[72], d_ctl[LOC_LEN], d_base[LOC_LEN];
    // an entry being read
    bool     e_item;
    char     e_id[96], e_title[96], e_artist[64], e_album[64];
    char     e_url[256], r_url[256], r_proto[48], r_size[12];
    uint32_t e_kb;
    char     e_kind;
    // the PC's lines
    char     line[260];
    uint16_t ll;
    // the request
    char     url[280];
    char     action[96];
    char     body[700];
    char     dgram[360];
} media_t;
_Static_assert(sizeof(media_t) <= 6144u, "Network's work memory: the directory's cache (6 KB)");

#define MU (pva_sonos_udp())            // the search's UDP: the Sonos search's slot, borrowed

static media_t *mem(void)
{
    size_t sz;
    uint8_t *m = pva_dir_cache(&sz);
    if (!m || sz < sizeof(media_t)) return NULL;
    return (media_t *)(void *)m;
}
#define M (mem())

enum { J_NONE, J_SEARCH, J_BROWSE };
enum { D_IDLE, D_OPEN, D_SEND, D_RCV, D_CLOSE, D_DESC, D_DESCING, D_ASK, D_ASKING };

static void d_data(const uint8_t *p, size_t n)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC) return;
    size_t k = n;
    if (m->dlen + k >= sizeof m->dgram) k = sizeof m->dgram - 1u - m->dlen;
    memcpy(m->dgram + m->dlen, p, k);
    m->dlen = (uint16_t)(m->dlen + k);
    m->dgram[m->dlen] = 0;
}

bool pva_media_valid(void) { media_t *m = M; return m && m->magic == MAGIC && m->job == J_NONE && m->found; }
uint8_t pva_media_state(void) { media_t *m = M; return m && m->magic == MAGIC ? m->st : PVA_DIRS_IDLE; }
uint8_t pva_media_error(void) { media_t *m = M; return m && m->magic == MAGIC ? m->err : 0; }
uint8_t pva_media_count(void) { media_t *m = M; return m && m->magic == MAGIC ? m->nsrv : 0; }
const char *pva_media_name(uint8_t i) { media_t *m = M; return m && m->magic == MAGIC && i < m->nsrv ? m->srv_name[i] : ""; }
bool pva_media_more(void) { media_t *m = M; return m && m->magic == MAGIC && m->src < m->nsrv && (uint32_t)m->start + m->returned < m->total && !m->full; }

// "Server/Folder/Sub" (the folders' own '/' left as they are)
void pva_media_where(char *out, size_t n)
{
    media_t *m = M;
    out[0] = 0;
    if (!m || m->magic != MAGIC || m->src >= m->nsrv) return;
    snprintf(out, n, "%s%s%s", m->srv_name[m->src], m->tpath[0] ? "/" : "", m->tpath);
    for (char *p = out; *p; p++) if (*p == SEP) *p = '/';
}

static void web_done(bool ok) { media_t *m = M; if (m && m->magic == MAGIC && m->web_st) m->web_st = ok ? 1 : 2; }

static void end_job(uint8_t st, uint8_t err)
{
    media_t *m = M;
    if (m->held) { pva_esp_release(); m->held = false; }
    if (MU && m->job == J_SEARCH) { pva_esp_clear(MU); pva_sonos_udp_back(); }
    m->d = D_IDLE;
    m->job = J_NONE;
    m->st = st;
    m->err = err;
}

void pva_media_cancel(void)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC || m->job == J_NONE) return;
    if (m->web_st) { pva_web_abort(); m->web_st = 0; }
    end_job(PVA_DIRS_IDLE, 0);         // (a folder given up: the one before stays; a search: none, found stays false)
}

// ---------------------------------------------------------------- URLs
static bool split_url(const char *u, char *base, size_t bn)
{
    // "http://host:port/path..." -> "http://host:port"
    const char *p = strstr(u, "://");
    if (!p) return false;
    const char *e = strchr(p + 3, '/');
    size_t k = e ? (size_t)(e - u) : strlen(u);
    if (k >= bn) return false;
    memcpy(base, u, k);
    base[k] = 0;
    return true;
}

// a URL in a description: absolute, from the host, or from the description's folder
static void resolve(char *out, size_t n, const char *base, const char *rel)
{
    if (strstr(rel, "://")) { snprintf(out, n, "%s", rel); return; }
    char root[LOC_LEN];
    if (!split_url(base, root, sizeof root)) { out[0] = 0; return; }
    if (rel[0] == '/') { snprintf(out, n, "%s%s", root, rel); return; }
    snprintf(out, n, "%s", base);
    char *q = strchr(out + strlen(root), '?');
    if (q) *q = 0;
    char *s = strrchr(out + strlen(root), '/');
    if (s) s[1] = 0; else { size_t l = strlen(out); if (l + 1 < n) { out[l] = '/'; out[l + 1] = 0; } }
    size_t l = strlen(out);
    snprintf(out + l, n - l, "%s", rel);
}

static void pct(char *out, size_t n, const char *s)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t o = strlen(out);
    for (; *s && o + 4 < n; s++)
    {
        unsigned char c = (unsigned char)*s;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' || c == '/')
            out[o++] = (char)c;
        else { out[o++] = '%'; out[o++] = hex[c >> 4]; out[o++] = hex[c & 15]; }
    }
    out[o] = 0;
}

static void xml_esc(char *out, size_t n, const char *s)
{
    size_t o = strlen(out);
    for (; *s && o + 7 < n; s++)
    {
        const char *r = *s == '&' ? "&amp;" : *s == '<' ? "&lt;" : *s == '>' ? "&gt;" : *s == '"' ? "&quot;" : NULL;
        if (r) { memcpy(out + o, r, strlen(r)); o += strlen(r); }
        else out[o++] = *s;
    }
    out[o] = 0;
}

// the last folder of a way down ("" at the top)
static const char *last_of(const char *stk)
{
    const char *s = strrchr(stk, SEP);
    return s ? s + 1 : stk;
}

// ---------------------------------------------------------------- the search
static void add_cand(const char *loc)
{
    media_t *m = M;
    if (!loc[0] || strlen(loc) >= sizeof m->cand[0] || m->ncand >= MAX_SRV) return;
    for (uint8_t i = 0; i < m->ncand; i++) if (!strcmp(m->cand[i], loc)) return;
    snprintf(m->cand[m->ncand++], sizeof m->cand[0], "%s", loc);
}

static void d_datagram(void)
{
    media_t *m = M;
    for (char *l = m->dgram; l && *l; )
    {
        if (!strncmp(l, "LOCATION:", 9) || !strncmp(l, "Location:", 9) || !strncmp(l, "location:", 9))
        {
            char v[LOC_LEN];
            const char *s = l + 9;
            while (*s == ' ') s++;
            size_t k = strcspn(s, "\r\n");
            if (k < sizeof v)
            {
                memcpy(v, s, k);
                v[k] = 0;
                add_cand(v);
            }
        }
        l = strchr(l, '\n');
        if (l) l++;
    }
}

static void d_send(void)
{
    media_t *m = M;
    static const char msg[] = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
                              "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n";
    uint8_t a[7] = { m->uconn, 239, 255, 255, 250, (uint8_t)(1900 & 0xFF), (uint8_t)(1900 >> 8) };
    pva_esp_request(MU, PVA_FN_UDPSEND, a, 7, (const uint8_t *)msg, sizeof msg - 1u, T_UDP_MS);
    m->sent = pva_hal_millis();
    m->sends++;
    m->d = D_SEND;
}

// a description: its friendlyName, URLBase, and ContentDirectory's controlURL
static void ds_text(sx_t *x, char c)
{
    media_t *m = M;
    if (!strcmp(x->el, "friendlyName")) { if (!m->d_named) put_c(m->d_name, NAME_LEN, c); }
    else if (!strcmp(x->el, "URLBase")) put_c(m->d_base, LOC_LEN, c);
    else if (!strcmp(x->el, "serviceType")) put_c(m->d_type, sizeof m->d_type, c);
    else if (!strcmp(x->el, "controlURL")) put_c(m->line, sizeof m->line, c);
}

static void ds_tagend(sx_t *x)
{
    media_t *m = M;
    if (x->closing && !strcmp(x->tag, "friendlyName")) m->d_named = true;      // (the first name: the device's)
    else if (!strcmp(x->tag, "service"))
    {
        if (x->closing && strstr(m->d_type, "ContentDirectory") && !m->d_ctl[0]) snprintf(m->d_ctl, LOC_LEN, "%s", m->line);
        m->d_type[0] = 0;
        m->line[0] = 0;
    }
}

static bool ds_body(const uint8_t *p, size_t n)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC) return true;
    for (size_t i = 0; i < n; i++) sx_byte(&m->a, (char)p[i]);
    return false;
}

static void desc_done(void)
{
    // a server with a ContentDirectory: one of the sources
    media_t *m = M;
    if (!m->d_ctl[0] || m->nsrv > MAX_SRV) return;
    char ctl[LOC_LEN];
    resolve(ctl, sizeof ctl, m->d_base[0] ? m->d_base : m->cand[m->ci], m->d_ctl);
    if (!ctl[0]) return;
    for (uint8_t i = 0; i < m->nsrv; i++) if (!strcmp(m->srv_ctl[i], ctl)) return;
    char nm[NAME_LEN];
    pva_copy_ascii(nm, sizeof nm, m->d_name[0] ? m->d_name : "Media server", strlen(m->d_name[0] ? m->d_name : "Media server"));
    // (two of the same name: the second gets its address)
    for (uint8_t i = 0; i < m->nsrv; i++)
        if (!strcmp(m->srv_name[i], nm))
        {
            char h[LOC_LEN];
            if (split_url(ctl, h, sizeof h)) { size_t l = strlen(nm); snprintf(nm + l, sizeof nm - l, " (%s)", strstr(h, "://") ? strstr(h, "://") + 3 : h); }
            break;
        }
    snprintf(m->srv_name[m->nsrv], NAME_LEN, "%s", nm);
    snprintf(m->srv_ctl[m->nsrv], LOC_LEN, "%s", ctl);
    m->nsrv++;
    pva_log("network: %.30s", nm);
}

// pc: "http://ip:port" of PicoAmp for Windows (NULL / "": none known)
int pva_media_search(const char *pc)
{
    media_t *m = M;
    if (!m) return PVA_E_NOWIFI;
    if (!pva_hal_net_present()) return PVA_E_NOWIFI;
    if (m->magic == MAGIC && m->job != J_NONE) pva_media_cancel();
    memset(m, 0, sizeof *m);
    m->magic = MAGIC;
    m->src = 0xFF;
    if (pc && pc[0] && strlen(pc) < LOC_LEN)
    {
        snprintf(m->srv_name[0], NAME_LEN, "PicoAmp on the PC");
        snprintf(m->srv_ctl[0], LOC_LEN, "%s", pc);
        m->nsrv = 1;
        m->have_pc = true;
    }
    m->job = J_SEARCH;
    m->st = PVA_DIRS_LOADING;
    if (!MU || !pva_esp_acquire()) { m->d = D_DESC; m->ci = 0; return PVA_E_BUSY; }      // (the PC alone)
    m->held = true;
    MU->data = d_data;
    uint8_t a[3] = { 0xFF, 0xFF, 1 };       // a port of its choice, transient
    pva_esp_request(MU, PVA_FN_UDPOPEN, a, 3, NULL, 0, T_UDP_MS);
    m->d = D_OPEN;
    m->t0 = pva_hal_millis();
    pva_log("network: search");
    return PVA_E_BUSY;
}

static void search_poll(media_t *m)
{
    uint32_t now = pva_hal_millis();
    if (m->d != D_DESC && m->d != D_DESCING) pva_esp_io();
    switch (m->d)
    {
        case D_OPEN:
            if (!pva_esp_finished(MU)) return;
            if (MU->rsp_timeout || MU->rc || MU->pgot < 1)
            {
                pva_log("network: no UDP (%u)", (unsigned)MU->rc);      // (an older ESP firmware: the PC alone)
                pva_esp_clear(MU);
                if (m->held) { pva_esp_release(); m->held = false; }
                m->d = D_DESC;
                m->ci = 0;
                return;
            }
            m->uconn = MU->pfirst[0];
            pva_esp_clear(MU);
            m->sends = 0;
            d_send();
            return;
        case D_SEND:
            if (!pva_esp_finished(MU)) return;
            pva_esp_clear(MU);
            m->d = D_RCV;
            m->rcv_at = now;
            return;
        case D_RCV:
            if (MU->want_fn == PVA_FN_UDPRCV)
            {
                if (!pva_esp_finished(MU)) return;
                bool got = !MU->rsp_timeout && MU->rc == 0 && MU->pgot > 6;
                pva_esp_clear(MU);
                if (got) { d_datagram(); m->rcv_at = now; }
                else m->rcv_at = now + 60u;
            }
            if (now - m->t0 >= SEARCH_MS)
            {
                uint8_t a = m->uconn;
                pva_esp_request(MU, PVA_FN_UDPCLOSE, &a, 1, NULL, 0, T_UDP_MS);
                m->d = D_CLOSE;
                return;
            }
            if (m->sends < 3 && now - m->sent >= 600u) { d_send(); return; }
            if ((int32_t)(now - m->rcv_at) >= 0)
            {
                uint8_t a[3] = { m->uconn, 0x00, 0x04 };
                m->dlen = 0;
                m->dgram[0] = 0;
                pva_esp_request(MU, PVA_FN_UDPRCV, a, 3, NULL, 0, T_UDP_MS);
            }
            return;
        case D_CLOSE:
            if (!pva_esp_finished(MU)) return;
            pva_esp_clear(MU);
            if (m->held) { pva_esp_release(); m->held = false; }
            m->ci = 0;
            m->d = D_DESC;
            return;
        case D_DESC:
            // each answer's description
            if (m->ci >= m->ncand) { m->found = true; end_job(PVA_DIRS_DONE, 0); pva_log("network: %u sources", (unsigned)m->nsrv); return; }
            if (pva_web_busy()) return;
            m->d_name[0] = m->d_type[0] = m->d_ctl[0] = m->d_base[0] = m->line[0] = 0;
            m->d_named = false;
            sx_reset(&m->a);
            m->a.text = ds_text;
            m->a.attr = NULL;
            m->a.tagend = ds_tagend;
            pva_web_no_lend();
            if (pva_web_get(m->cand[m->ci], ds_body, web_done) == PVA_OK) { m->web_st = -1; m->d = D_DESCING; }
            else m->ci++;
            return;
        case D_DESCING:
            if (m->web_st <= 0) return;
            if (m->web_st == 1) desc_done();
            m->web_st = 0;
            m->ci++;
            m->d = D_DESC;
            return;
    }
}

// ---------------------------------------------------------------- a folder
static void e_clear(media_t *m)
{
    m->e_id[0] = m->e_title[0] = m->e_artist[0] = m->e_album[0] = m->e_url[0] = 0;
    m->r_url[0] = m->r_proto[0] = m->r_size[0] = 0;
    m->e_kb = 0;
    m->e_kind = 0;
    m->art_lock = m->title_lock = false;
}

static bool starts_ci(const char *a, const char *pre)
{
    for (; *pre; a++, pre++)
    {
        char x = *a >= 'A' && *a <= 'Z' ? (char)(*a + 32) : *a;
        if (x != *pre) return false;
    }
    return true;
}

// M (MP3), W (WAV) or 0, from a res's protocolInfo ("http-get:*:audio/mpeg:...") or its address
static char kind_of(const char *proto, const char *url)
{
    const char *t = strchr(proto, ':');
    t = t ? strchr(t + 1, ':') : NULL;
    if (t)
    {
        t++;
        if (starts_ci(t, "audio/mpeg") || starts_ci(t, "audio/mp3") || starts_ci(t, "audio/x-mpeg")) return 'M';
        if (starts_ci(t, "audio/wav") || starts_ci(t, "audio/x-wav") || starts_ci(t, "audio/wave") || starts_ci(t, "audio/vnd.wave")) return 'W';
        if (*t && *t != '*') return 0;
    }
    int k = pva_kind_from_name(url);
    char e[8];
    const char *q = strchr(url, '?');
    if (q)
    {
        // (the name before the query)
        size_t n = (size_t)(q - url);
        const char *dot = NULL;
        for (size_t i = 0; i < n; i++) if (url[i] == '.') dot = url + i;
        if (dot && (size_t)(q - dot) < sizeof e) { memcpy(e, dot, (size_t)(q - dot)); e[q - dot] = 0; k = pva_kind_from_name(e); }
    }
    return k == PVA_DE_MP3 ? 'M' : k == PVA_DE_WAV ? 'W' : 0;
}

static void add_entry(media_t *m, const char *name, const char *url, const char *extra, uint32_t kb)
{
    if (m->full || !name[0]) return;
    if (!pva_dir_add_entry(name, url, extra, (uint16_t)(kb > 65535u ? 65535u : kb))) m->full = true;
    else m->got++;
}

// DIDL-Lite: containers (folders) and items (songs)
static void b_text(sx_t *x, char c)
{
    media_t *m = M;
    if (!strcmp(x->el, "title")) { if (!m->title_lock) put_c(m->e_title, sizeof m->e_title, c); }
    else if (!strcmp(x->el, "artist") || !strcmp(x->el, "creator")) { if (!m->art_lock) put_c(m->e_artist, sizeof m->e_artist, c); }
    else if (!strcmp(x->el, "album")) put_c(m->e_album, sizeof m->e_album, c);
    else if (!strcmp(x->el, "res")) put_c(m->r_url, sizeof m->r_url, c);
}

static void b_attr(sx_t *x, char c)
{
    media_t *m = M;
    if ((!strcmp(x->tag, "container") || !strcmp(x->tag, "item")) && !strcmp(x->an, "id")) put_c(m->e_id, sizeof m->e_id, c);
    else if (!strcmp(x->tag, "res") && !strcmp(x->an, "protocolInfo")) put_c(m->r_proto, sizeof m->r_proto, c);
    else if (!strcmp(x->tag, "res") && !strcmp(x->an, "size")) put_c(m->r_size, sizeof m->r_size, c);
}

static void b_tagend(sx_t *x)
{
    media_t *m = M;
    if (!x->closing && (!strcmp(x->tag, "container") || !strcmp(x->tag, "item")))
    {
        // (its id came with the tag: kept)
        char id[96];
        snprintf(id, sizeof id, "%s", m->e_id);
        e_clear(m);
        snprintf(m->e_id, sizeof m->e_id, "%s", id);
        m->e_item = !strcmp(x->tag, "item");
        return;
    }
    // (the first title and artist: an item may name several)
    if (x->closing && !strcmp(x->tag, "title") && m->e_title[0]) { m->title_lock = true; return; }
    if (x->closing && (!strcmp(x->tag, "artist") || !strcmp(x->tag, "creator")) && m->e_artist[0]) { m->art_lock = true; return; }
    if (!x->closing && !strcmp(x->tag, "res") && !x->empty) return;
    if ((x->closing || x->empty) && !strcmp(x->tag, "res"))
    {
        // the first MP3 (or WAV) of the item's addresses
        char *u = m->r_url;
        while (*u == ' ' || *u == '\n' || *u == '\r' || *u == '\t') u++;
        size_t l = strlen(u);
        while (l && (u[l - 1] == ' ' || u[l - 1] == '\n' || u[l - 1] == '\r' || u[l - 1] == '\t')) u[--l] = 0;
        char k = kind_of(m->r_proto, u);
        if (k && (!m->e_kind || (m->e_kind == 'W' && k == 'M')) && l && l <= 255u && !strncmp(u, "http://", 7))
        {
            m->e_kind = k;
            snprintf(m->e_url, sizeof m->e_url, "%s", u);
            m->e_kb = (uint32_t)(strtoull(m->r_size, NULL, 10) / 1024u);
        }
        m->r_url[0] = m->r_proto[0] = m->r_size[0] = 0;
        return;
    }
    if (x->closing && !strcmp(x->tag, "container"))
    {
        if (m->e_id[0] && strlen(m->e_id) + 1u < sizeof m->e_id) add_entry(m, m->e_title, m->e_id, "d", 0);
        e_clear(m);
        return;
    }
    if (x->closing && !strcmp(x->tag, "item"))
    {
        if (m->e_kind)
        {
            char extra[2 + 64 + 1 + 64 + 1];
            snprintf(extra, sizeof extra, "f%c%s\x1f%s", m->e_kind, m->e_artist, m->e_album);
            add_entry(m, m->e_title, m->e_url, extra, m->e_kb);
        }
        e_clear(m);
    }
}

// the SOAP answer: Result (the DIDL-Lite, escaped) to the second reader; how many there are
static void a_text(sx_t *x, char c)
{
    media_t *m = M;
    if (!strcmp(x->el, "Result")) sx_byte(&m->b, c);
    else if (!strcmp(x->el, "TotalMatches") && c >= '0' && c <= '9') m->total = (uint16_t)(m->total * 10u + (uint16_t)(c - '0'));
    else if (!strcmp(x->el, "NumberReturned") && c >= '0' && c <= '9') m->returned = (uint16_t)(m->returned * 10u + (uint16_t)(c - '0'));
}

static bool soap_body(const uint8_t *p, size_t n)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC) return true;
    for (size_t i = 0; i < n; i++) sx_byte(&m->a, (char)p[i]);
    return false;
}

// the PC's list: "d name" / "f name" lines
static void pc_line(media_t *m)
{
    m->line[m->ll] = 0;
    m->ll = 0;
    char *l = m->line;
    size_t n = strlen(l);
    while (n && (l[n - 1] == '\r' || l[n - 1] == ' ')) l[--n] = 0;
    if (n < 3 || l[1] != ' ') return;
    const char *name = l + 2;
    if (l[0] == 'd') { add_entry(m, name, name, "d", 0); return; }
    if (l[0] != 'f') return;
    int k = pva_kind_from_name(name);
    if (k != PVA_DE_MP3 && k != PVA_DE_WAV) return;
    char u[300];
    snprintf(u, sizeof u, "%s/music/file?path=", m->srv_ctl[m->src]);
    char path[STK_LEN + 260];
    snprintf(path, sizeof path, "%s%s%s", m->n_stk, m->n_stk[0] ? "/" : "", name);
    for (char *p = path; *p; p++) if (*p == SEP) *p = '/';
    pct(u, sizeof u, path);
    if (strlen(u) > 255u) return;
    // (the title: the name without .mp3)
    char t[96];
    snprintf(t, sizeof t, "%s", name);
    char *dot = strrchr(t, '.');
    if (dot) *dot = 0;
    add_entry(m, t, u, k == PVA_DE_MP3 ? "fM\x1f" : "fW\x1f", 0);
}

static bool pc_body(const uint8_t *p, size_t n)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC) return true;
    for (size_t i = 0; i < n; i++)
    {
        if (p[i] == '\n') pc_line(m);
        else if (m->ll + 1u < sizeof m->line) m->line[m->ll++] = (char)p[i];
    }
    return false;
}

static int ask(media_t *m)
{
    m->total = m->returned = 0;
    m->full = false;
    if (m->src == 0 && m->have_pc)
    {
        snprintf(m->url, sizeof m->url, "%s/music/list?path=", m->srv_ctl[0]);
        char path[STK_LEN];
        snprintf(path, sizeof path, "%s", m->n_stk);
        for (char *p = path; *p; p++) if (*p == SEP) *p = '/';
        pct(m->url, sizeof m->url, path);
        m->ll = 0;
        pva_web_no_lend();
        int r = pva_web_get(m->url, pc_body, web_done);
        if (r == PVA_OK) m->web_st = -1;
        return r;
    }
    const char *id = m->n_stk[0] ? last_of(m->n_stk) : "0";
    snprintf(m->action, sizeof m->action, "urn:schemas-upnp-org:service:ContentDirectory:1#Browse");
    snprintf(m->body, sizeof m->body,
             "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
             "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">"
             "<ObjectID>");
    xml_esc(m->body, sizeof m->body, id);
    size_t l = strlen(m->body);
    int n = snprintf(m->body + l, sizeof m->body - l,
                     "</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>%u</StartingIndex>"
                     "<RequestedCount>%u</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>",
                     (unsigned)m->start, PAGE);
    if (n <= 0 || l + (size_t)n >= sizeof m->body) return PVA_E_ARGS;
    sx_reset(&m->a);
    sx_reset(&m->b);
    m->a.text = a_text; m->a.attr = NULL; m->a.tagend = NULL;
    m->b.text = b_text; m->b.attr = b_attr; m->b.tagend = b_tagend;
    e_clear(m);
    pva_web_no_lend();
    int r = pva_web_soap(m->srv_ctl[m->src], m->action, m->body, l + (size_t)n, soap_body, web_done);
    if (r == PVA_OK) m->web_st = -1;
    return r;
}

static int browse(media_t *m, uint16_t start, bool more)
{
    if (!more) pva_dir_clear();
    m->got = more ? m->got : 0;
    m->start = start;
    m->job = J_BROWSE;
    m->st = PVA_DIRS_LOADING;
    m->err = 0;
    m->d = D_ASK;
    return PVA_E_BUSY;
}

static bool ready(media_t *m) { return m && m->magic == MAGIC && m->job == J_NONE; }

// a source's top folder (i: of pva_media_name)
int pva_media_open(uint8_t i)
{
    media_t *m = M;
    if (!ready(m) || i >= m->nsrv) return PVA_E_STATE;
    m->src = i;
    m->n_stk[0] = m->n_tpath[0] = 0;
    return browse(m, 0, false);
}

// a folder of the list: its ID (a server) or name (the PC), and its name
int pva_media_enter(const char *id, const char *name)
{
    media_t *m = M;
    if (!ready(m) || m->src >= m->nsrv) return PVA_E_STATE;
    if (strlen(m->stk) + strlen(id) + 2u > STK_LEN) return PVA_E_ARGS;
    snprintf(m->n_stk, STK_LEN, "%s%s%s", m->stk, m->stk[0] ? "\x1e" : "", id);
    char nm[48];
    pva_copy_ascii(nm, sizeof nm, name, strlen(name));
    snprintf(m->n_tpath, TPATH_LEN, "%s%s%s", m->tpath, m->tpath[0] ? "\x1e" : "", nm);
    return browse(m, 0, false);
}

// the folder above: PVA_E_RANGE at the source's top (then the sources' list)
int pva_media_up(void)
{
    media_t *m = M;
    if (!ready(m) || m->src >= m->nsrv) return PVA_E_STATE;
    if (!m->stk[0]) return PVA_E_RANGE;
    snprintf(m->n_stk, STK_LEN, "%s", m->stk);
    snprintf(m->n_tpath, TPATH_LEN, "%s", m->tpath);
    char *s = strrchr(m->n_stk, SEP);
    if (s) *s = 0; else m->n_stk[0] = 0;
    s = strrchr(m->n_tpath, SEP);
    if (s) *s = 0; else m->n_tpath[0] = 0;
    return browse(m, 0, false);
}

// the folder's next entries (a server's), added to the list
int pva_media_next(void)
{
    media_t *m = M;
    if (!ready(m) || !pva_media_more()) return PVA_E_STATE;
    snprintf(m->n_stk, STK_LEN, "%s", m->stk);
    snprintf(m->n_tpath, TPATH_LEN, "%s", m->tpath);
    return browse(m, (uint16_t)(m->start + m->returned), true);
}

static void browse_poll(media_t *m)
{
    switch (m->d)
    {
        case D_ASK:
            if (pva_web_busy()) return;
            if (ask(m) != PVA_OK) { end_job(PVA_DIRS_FAILED, PVA_NERR_NOWIFI); return; }
            m->d = D_ASKING;
            return;
        case D_ASKING:
        {
            if (m->web_st <= 0) return;
            bool ok = m->web_st == 1;
            m->web_st = 0;
            if (!ok)
            {
                end_job(PVA_DIRS_FAILED, pva_web_error() ? pva_web_error() : PVA_NERR_HTTP);
                pva_log("network: no folder (%u, HTTP %u)", (unsigned)m->err, (unsigned)pva_web_http());
                return;
            }
            if (m->src == 0 && m->have_pc)
            {
                if (m->ll) pc_line(m);
                m->total = m->returned = m->got;    // (all of it at once)
                pva_dir_sort();             // (folders first, by name)
            }
            else if (!m->total)
                m->total = (uint16_t)(m->start + m->returned + (m->returned >= PAGE ? 1u : 0u));   // (a server that does not say: more while pages are full)
            snprintf(m->stk, STK_LEN, "%s", m->n_stk);
            snprintf(m->tpath, TPATH_LEN, "%s", m->n_tpath);
            end_job(PVA_DIRS_DONE, 0);
            pva_log("network: %u of %u", (unsigned)(m->start + m->got), (unsigned)m->total);
            return;
        }
    }
}

void pva_media_poll(void)
{
    media_t *m = M;
    if (!m || m->magic != MAGIC || m->job == J_NONE) return;
    if (m->job == J_SEARCH) search_poll(m);
    else browse_poll(m);
}
