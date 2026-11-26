// MSX PICOVERSE PROJECT
// pva_sonos.c - PicoVerse Audio Engine: Sonos speakers in the network, as a
// screen and remote (their sound stays on the speakers).
//
// The search (Internet radio/Sonos): an SSDP M-SEARCH for ZonePlayers over UDP
// (239.255.255.250:1900, through the ESP-01's UDP functions); the speakers
// answer with their address. One of them tells the rooms: ZoneGroupTopology
// GetZoneGroupState, a group of speakers named after the one that leads it
// ("Kitchen + 1"; a pair, a sub, surrounds are one room). [sonos] ip = in
// PICOAMP.INI: speakers to ask when the network keeps the search from them.
// The rooms go into the station directory's results, as a station list:
//
//     sonos://192.168.1.30:1400/RINCON_000E58123456789#Living Room
//
// Such a station plays as the MSX link's screen (pva_net hands it here): the
// room's song, artist and album, its time, playing or paused, its volume, made
// into the lines PicoAmp for Windows sends on /screen (S, T, F; V for bars
// that move on a pretend sound), and the keys of the screen go to the room:
// AVTransport Play / Pause (a station that cannot pause: Stop), Next, Previous,
// Seek, SetPlayMode; GroupRenderingControl Set/GetGroupVolume and Mute.
// No account and no key: the speakers' own UPnP control (SOAP over HTTP on
// port 1400, through pva_web), as the Sonos apps use it in the house. A room
// that joins another group (its track is "x-rincon:<the leader>") is followed
// to that group's leader.
//
// Memory: the search's in the directory's cache (the countries are asked
// again), the room's in the stream ring (no sound comes while a room plays).
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "pva_internal.h"

#define SEARCH_MS       1600u       // the speakers' answers, at most
#define T_UDP_MS        3000u
#define POLL_MS         1000u       // the room is asked again
#define SLOW_EVERY      4u          // its volume and play mode: every 4th time
#define FAIL_SHOW       3u          // no answer this many times: it says so
#define MAX_CAND        6u
#define ID_LEN          40u
#define NAME_LEN        48u
#define TXT             120u
#define OUT_SIZE        768u        // the screen's lines not read yet

#include "pva_xml.h"

// ---------------------------------------------------------------- the work memory
typedef struct
{
    sx_t     a, b;                      // the SOAP answer; the XML inside it
    uint8_t  what;                      // the request (Q_xxx)
    bool     in_b;                      // the answer's element holds XML: to b
    // a room's answers
    char     state[20], dur[12], rel[12], uri[48], mode[24], vol[8], mute[4];
    char     title[TXT], creator[TXT], album[TXT], sc[TXT + 40], station[TXT];
    // the zone groups: the group being read, the member being read
    char     coord[ID_LEN], m_uuid[ID_LEN], m_loc[64], m_name[NAME_LEN], m_inv[4], m_bridge[4];
    char     g_ip[16], g_name[NAME_LEN], g_id[ID_LEN];
    uint16_t g_port;
    uint8_t  g_visible;
    bool     g_found;
    uint8_t  rooms;
    char     find[ID_LEN];              // looking for this leader's address ("": all the rooms)
    char     found_ip[16];
    uint16_t found_port;
    // the request
    char     url[80];
    char     action[100];
    char     body[640];
    // the search
    char     cand_ip[MAX_CAND][16];
    uint16_t cand_port[MAX_CAND];
    uint8_t  ncand, ci;
    char     dgram[400];
    uint16_t dlen;
    uint32_t d_t0, d_sent, d_rcv_at;
    uint8_t  d_sends, uconn;
    // the screen's lines (a room plays)
    char     out[OUT_SIZE];
    uint16_t out_n;
    // the room (here, not in static RAM: the firmware's heap needs that)
    char     r_ip[16], r_id[ID_LEN], r_name[NAME_LEN];
    char     keys[4][20];               // keys not sent yet
    char     sent_s[3][TXT];            // the S line last made (artist, title, album)
    char     resolve[ID_LEN];           // the room joined this leader's group: its address is asked for
    uint8_t  lv[PVA_VIZ_BANDS];         // the pretend bars
    uint8_t  beat, nkeys, fails, q_rounds, p_state, p_repeat;
    int8_t   p_mute, want_mute;
    bool     radio, p_shuffle;
    uint16_t r_port, p_total;
    int16_t  p_vol, want_vol;
    int32_t  p_el_ms;
    uint32_t p_at, q_round_at, t_line_at, v_line_at, beat_at;
} work_t;

static work_t *W;                       // the one in use: the search's or the room's
static work_t *WR;                      // the room's (the stream ring)
static uint8_t q_step;                  // a room's questions of this round (Q_xxx), Q_NONE between rounds

// ---------------------------------------------------------------- SOAP
enum { SV_AVT, SV_GRC, SV_ZGT };
static const char *const sv_path[] = { "/MediaRenderer/AVTransport/Control", "/MediaRenderer/GroupRenderingControl/Control", "/ZoneGroupTopology/Control" };
static const char *const sv_urn[] = { "urn:schemas-upnp-org:service:AVTransport:1", "urn:schemas-upnp-org:service:GroupRenderingControl:1",
                                      "urn:schemas-upnp-org:service:ZoneGroupTopology:1" };

enum { Q_NONE, Q_TOPO, Q_POS, Q_TRANS, Q_MODE, Q_VOL, Q_MUTE, Q_MEDIA, Q_CMD };

static bool soap_answer(const uint8_t *p, size_t n);
static int8_t  web_st;                  // our web request: 0 none, -1 it runs, 1 done, 2 failed
#define web_mine (web_st != 0)
static void soap_done(bool ok) { if (web_st) web_st = ok ? 1 : 2; }

static int soap(const char *ip, uint16_t port, uint8_t sv, const char *action, const char *args, uint8_t what)
{
    snprintf(W->url, sizeof W->url, "http://%s:%u%s", ip, (unsigned)port, sv_path[sv]);
    snprintf(W->action, sizeof W->action, "%s#%s", sv_urn[sv], action);
    int n = snprintf(W->body, sizeof W->body,
                     "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                     "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:%s xmlns:u=\"%s\">%s</u:%s></s:Body></s:Envelope>",
                     action, sv_urn[sv], args, action);
    if (n <= 0 || (size_t)n >= sizeof W->body) return PVA_E_ARGS;
    W->what = what;
    W->in_b = false;
    sx_reset(&W->a);
    sx_reset(&W->b);
    pva_web_no_lend();
    int r = pva_web_soap(W->url, W->action, W->body, (size_t)n, soap_answer, soap_done);
    if (r == PVA_OK) web_st = -1;
    return r;
}

// ---- what the answers hold
static char *cap_of(const char *el, size_t *size)
{
    static const struct { const char *el; uint16_t off, size; } t[] = {
        { "CurrentTransportState", offsetof(work_t, state), sizeof ((work_t *)0)->state },
        { "TrackDuration", offsetof(work_t, dur), sizeof ((work_t *)0)->dur },
        { "RelTime", offsetof(work_t, rel), sizeof ((work_t *)0)->rel },
        { "TrackURI", offsetof(work_t, uri), sizeof ((work_t *)0)->uri },
        { "PlayMode", offsetof(work_t, mode), sizeof ((work_t *)0)->mode },
        { "CurrentVolume", offsetof(work_t, vol), sizeof ((work_t *)0)->vol },
        { "CurrentMute", offsetof(work_t, mute), sizeof ((work_t *)0)->mute } };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++)
        if (!strcmp(el, t[i].el)) { *size = t[i].size; return (char *)W + t[i].off; }
    return NULL;
}

// the XML inside: DIDL-Lite (a track's, a station's), or the zone groups
static void b_text(sx_t *x, char c)
{
    if (W->what == Q_MEDIA) { if (!strcmp(x->el, "title")) put_c(W->station, sizeof W->station, c); return; }
    if (!strcmp(x->el, "title")) put_c(W->title, sizeof W->title, c);
    else if (!strcmp(x->el, "creator")) put_c(W->creator, sizeof W->creator, c);
    else if (!strcmp(x->el, "album")) put_c(W->album, sizeof W->album, c);
    else if (!strcmp(x->el, "streamContent")) put_c(W->sc, sizeof W->sc, c);
}

static void b_attr(sx_t *x, char c)
{
    if (W->what != Q_TOPO) return;
    if (!strcmp(x->tag, "ZoneGroup")) { if (!strcmp(x->an, "Coordinator")) put_c(W->coord, sizeof W->coord, c); return; }
    if (strcmp(x->tag, "ZoneGroupMember")) return;
    if (!strcmp(x->an, "UUID")) put_c(W->m_uuid, sizeof W->m_uuid, c);
    else if (!strcmp(x->an, "Location")) put_c(W->m_loc, sizeof W->m_loc, c);
    else if (!strcmp(x->an, "ZoneName")) put_c(W->m_name, sizeof W->m_name, c);
    else if (!strcmp(x->an, "Invisible")) put_c(W->m_inv, sizeof W->m_inv, c);
    else if (!strcmp(x->an, "IsZoneBridge")) put_c(W->m_bridge, sizeof W->m_bridge, c);
}

// "http://192.168.1.30:1400/xml/device_description.xml" -> ip, port
static bool location(const char *loc, char *ip, size_t ipn, uint16_t *port)
{
    if (strncmp(loc, "http://", 7)) return false;
    const char *h = loc + 7, *e = h;
    while (*e && *e != ':' && *e != '/') e++;
    size_t l = (size_t)(e - h);
    if (!l || l >= ipn) return false;
    memcpy(ip, h, l);
    ip[l] = 0;
    *port = *e == ':' ? (uint16_t)atoi(e + 1) : 80;
    return *port != 0;
}

static void room_done(void)
{
    if (!W->g_found || !W->g_name[0]) return;
    if (W->find[0])
    {
        if (!strcmp(W->g_id, W->find)) { snprintf(W->found_ip, sizeof W->found_ip, "%s", W->g_ip); W->found_port = W->g_port; }
        return;
    }
    char name[NAME_LEN + 8], u[256], nm[NAME_LEN + 8];
    if (W->g_visible > 1) snprintf(name, sizeof name, "%.40s + %u", W->g_name, (unsigned)(W->g_visible - 1u));
    else snprintf(name, sizeof name, "%s", W->g_name);
    pva_copy_ascii(nm, sizeof nm, name, strlen(name));
    snprintf(u, sizeof u, "sonos://%s:%u/%s#%s", W->g_ip, (unsigned)W->g_port, W->g_id, nm);
    if (pva_dir_add(nm, u)) W->rooms++;
}

static void b_tagend(sx_t *x)
{
    if (W->what != Q_TOPO) return;
    if (!strcmp(x->tag, "ZoneGroup"))
    {
        // (its Coordinator came with the tag; the members follow)
        if (x->closing) { room_done(); W->coord[0] = 0; return; }
        W->g_found = false;
        W->g_visible = 0;
        W->g_name[0] = 0;
        if (x->empty) W->coord[0] = 0;
        return;
    }
    if (strcmp(x->tag, "ZoneGroupMember") || x->closing)
    {
        if (strcmp(x->tag, "ZoneGroupMember")) { W->m_uuid[0] = W->m_loc[0] = W->m_name[0] = W->m_inv[0] = W->m_bridge[0] = 0; }
        return;
    }
    // a member: counted when it is seen (not a bridge, not a bonded one); the leader names the room
    if (strcmp(W->m_bridge, "1"))
    {
        if (strcmp(W->m_inv, "1")) W->g_visible++;
        if (!strcmp(W->m_uuid, W->coord) && location(W->m_loc, W->g_ip, sizeof W->g_ip, &W->g_port))
        {
            W->g_found = true;
            snprintf(W->g_name, sizeof W->g_name, "%s", W->m_name);
            snprintf(W->g_id, sizeof W->g_id, "%s", W->m_uuid);
        }
    }
    W->m_uuid[0] = W->m_loc[0] = W->m_name[0] = W->m_inv[0] = W->m_bridge[0] = 0;
}

static void a_text(sx_t *x, char c)
{
    if (!strcmp(x->el, "TrackMetaData") || !strcmp(x->el, "CurrentURIMetaData") || !strcmp(x->el, "ZoneGroupState"))
    {
        sx_byte(&W->b, c);
        return;
    }
    size_t n;
    char *b = cap_of(x->el, &n);
    if (b) put_c(b, n, c);
}

static void a_tagend(sx_t *x)
{
    // (a new element of XML inside: its reader from the start)
    if (!x->closing && (!strcmp(x->tag, "TrackMetaData") || !strcmp(x->tag, "CurrentURIMetaData") || !strcmp(x->tag, "ZoneGroupState")))
        sx_reset(&W->b);
}

static bool soap_answer(const uint8_t *p, size_t n)
{
    if (!W) return true;
    for (size_t i = 0; i < n; i++) sx_byte(&W->a, (char)p[i]);
    return false;
}

static void work_init(work_t *w)
{
    memset(w, 0, sizeof *w);
    w->a.text = a_text;
    w->a.tagend = a_tagend;
    w->b.text = b_text;
    w->b.attr = b_attr;
    w->b.tagend = b_tagend;
}

// the web request that runs: ours and done (true), with *ok its outcome
static bool web_finished(bool *ok)
{
    if (web_st <= 0) return false;
    *ok = web_st == 1;
    web_st = 0;
    return true;
}

// ---------------------------------------------------------------- the search
static pva_esp_slot_t *US;              // UDP
static uint8_t  dst = PVA_DIRS_IDLE, derr;
enum { D_IDLE, D_OPEN, D_SEND, D_RCV, D_CLOSE, D_ASK, D_ASKING };
static uint8_t  d;
static bool     d_held;
#define uconn    (W->uconn)             // (the search's state is in its work memory)
#define d_t0     (W->d_t0)
#define d_sent   (W->d_sent)
#define d_rcv_at (W->d_rcv_at)
#define d_sends  (W->d_sends)

static void d_data(const uint8_t *p, size_t n)
{
    if (!W) return;
    size_t k = n;
    if (W->dlen + k >= sizeof W->dgram) k = sizeof W->dgram - 1u - W->dlen;
    memcpy(W->dgram + W->dlen, p, k);
    W->dlen = (uint16_t)(W->dlen + k);
    W->dgram[W->dlen] = 0;
}

// the search's UDP slot: Network's search (pva_media.c) borrows it, with its own data function
pva_esp_slot_t *pva_sonos_udp(void) { return US; }
void pva_sonos_udp_back(void) { if (US) US->data = d_data; }

void pva_sonos_init(void)
{
    US = pva_net_spare_take(sizeof *US);
    if (!US) return;
    US->data = d_data;
    pva_esp_register(US);
}

static void add_cand(const char *ip, uint16_t port)
{
    if (!ip[0] || W->ncand >= MAX_CAND) return;
    for (uint8_t i = 0; i < W->ncand; i++) if (!strcmp(W->cand_ip[i], ip) && W->cand_port[i] == port) return;
    snprintf(W->cand_ip[W->ncand], sizeof W->cand_ip[0], "%s", ip);
    W->cand_port[W->ncand++] = port;
}

// an answer to the search: its LOCATION header
static void d_datagram(void)
{
    for (char *l = W->dgram; l && *l; )
    {
        if (!strncmp(l, "LOCATION:", 9) || !strncmp(l, "Location:", 9) || !strncmp(l, "location:", 9))
        {
            char v[80], ip[16];
            uint16_t port;
            const char *s = l + 9;
            while (*s == ' ') s++;
            size_t k = strcspn(s, "\r\n");
            if (k >= sizeof v) k = sizeof v - 1;
            memcpy(v, s, k);
            v[k] = 0;
            if (location(v, ip, sizeof ip, &port)) add_cand(ip, port);
        }
        l = strchr(l, '\n');
        if (l) l++;
    }
}

static void d_end(uint8_t state, uint8_t err)
{
    if (d_held) { pva_esp_release(); d_held = false; }
    if (US) pva_esp_clear(US);
    d = D_IDLE;
    dst = state;
    derr = err;
    W = WR;
    pva_log("sonos: %s, %u rooms", state == PVA_DIRS_DONE ? "done" : "failed", state == PVA_DIRS_DONE ? (unsigned)pva_dir_count() : 0u);
}

int pva_sonos_search(void)
{
    if (d != D_IDLE) return PVA_E_BUSY;
    if (!US || !pva_hal_net_present()) return PVA_E_NOWIFI;
    US->data = d_data;
    size_t sz;
    uint8_t *m = pva_dir_cache(&sz);
    if (!m || sz < sizeof(work_t)) return PVA_E_NOWIFI;
    if (web_mine) { pva_web_abort(); web_st = 0; q_step = 0; }    // (the room's question: asked again after)
    W = (work_t *)(void *)m;
    work_init(W);
    pva_dir_clear();
    // the speakers named in PICOAMP.INI
    char list[120];
    if (pva_cfg_get("sonos.ip", list, sizeof list))
        for (char *t = strtok(list, ", ;"); t; t = strtok(NULL, ", ;"))
        {
            char *c = strchr(t, ':');
            uint16_t port = c ? (uint16_t)atoi(c + 1) : 1400u;
            if (c) *c = 0;
            add_cand(t, port);
        }
    if (!pva_esp_acquire()) { W = WR; return PVA_E_NOWIFI; }
    d_held = true;
    uint8_t a[3] = { 0xFF, 0xFF, 1 };       // a port of its choice, transient
    pva_esp_request(US, PVA_FN_UDPOPEN, a, 3, NULL, 0, T_UDP_MS);
    d = D_OPEN;
    d_t0 = pva_hal_millis();
    dst = PVA_DIRS_LOADING;
    derr = 0;
    pva_log("sonos: search");
    return PVA_E_BUSY;
}

uint8_t pva_sonos_state(void) { return dst; }
uint8_t pva_sonos_error(void) { return derr; }

void pva_sonos_cancel(void)
{
    if (d == D_IDLE) return;
    if (d == D_ASKING && web_mine) { pva_web_abort(); web_st = 0; }
    d_end(PVA_DIRS_IDLE, 0);
}

static void d_send(void)
{
    static const char msg[] = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
                              "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n";
    uint8_t a[7] = { uconn, 239, 255, 255, 250, (uint8_t)(1900 & 0xFF), (uint8_t)(1900 >> 8) };
    pva_esp_request(US, PVA_FN_UDPSEND, a, 7, (const uint8_t *)msg, sizeof msg - 1u, T_UDP_MS);
    d_sent = pva_hal_millis();
    d_sends++;
    d = D_SEND;
}

static void d_poll(void)
{
    if (d == D_IDLE) return;
    uint32_t now = pva_hal_millis();
    if (d != D_ASK && d != D_ASKING) pva_esp_io();
    switch (d)
    {
        case D_OPEN:
            if (!pva_esp_finished(US)) return;
            if (US->rsp_timeout || US->rc || US->pgot < 1)
            {
                // no UDP (an older ESP firmware): only the speakers in PICOAMP.INI
                pva_log("sonos: no UDP (%u)", (unsigned)US->rc);
                pva_esp_clear(US);
                d = D_ASK;
                W->ci = 0;
                return;
            }
            uconn = US->pfirst[0];
            pva_esp_clear(US);
            d_sends = 0;
            d_send();
            return;
        case D_SEND:
            if (!pva_esp_finished(US)) return;
            pva_esp_clear(US);
            d = D_RCV;
            d_rcv_at = now;
            return;
        case D_RCV:
            if (US->want_fn == PVA_FN_UDPRCV)
            {
                if (!pva_esp_finished(US)) return;
                bool got = !US->rsp_timeout && US->rc == 0 && US->pgot > 6;
                pva_esp_clear(US);
                if (got) { d_datagram(); d_rcv_at = now; }   // (more may be waiting: at once)
                else d_rcv_at = now + 60u;
            }
            if (now - d_t0 >= SEARCH_MS)
            {
                uint8_t a = uconn;
                pva_esp_request(US, PVA_FN_UDPCLOSE, &a, 1, NULL, 0, T_UDP_MS);
                d = D_CLOSE;
                return;
            }
            if (d_sends < 2 && now - d_sent >= 500u) { d_send(); return; }
            if ((int32_t)(now - d_rcv_at) >= 0)
            {
                uint8_t a[3] = { uconn, 0x00, 0x04 };     // (up to 1024 bytes: what does not fit is left out)
                W->dlen = 0;
                W->dgram[0] = 0;
                pva_esp_request(US, PVA_FN_UDPRCV, a, 3, NULL, 0, T_UDP_MS);
            }
            return;
        case D_CLOSE:
            if (!pva_esp_finished(US)) return;
            pva_esp_clear(US);
            if (d_held) { pva_esp_release(); d_held = false; }
            W->ci = 0;
            d = D_ASK;
            return;
        case D_ASK:
            // the rooms, from the first speaker that answers
            if (W->ci >= W->ncand) { d_end(PVA_DIRS_FAILED, W->ncand ? PVA_NERR_CONNECT : PVA_NERR_DNS); return; }
            if (pva_web_busy()) return;
            W->rooms = 0;
            W->find[0] = 0;
            W->coord[0] = W->m_uuid[0] = W->m_loc[0] = W->m_name[0] = W->m_inv[0] = W->m_bridge[0] = 0;
            if (soap(W->cand_ip[W->ci], W->cand_port[W->ci], SV_ZGT, "GetZoneGroupState", "", Q_TOPO) == PVA_OK) d = D_ASKING;
            else W->ci++;
            return;
        case D_ASKING:
        {
            bool ok;
            if (!web_finished(&ok)) return;
            if (ok && W->rooms) { pva_dir_sort(); d_end(PVA_DIRS_DONE, 0); return; }
            pva_dir_clear();
            W->ci++;
            d = D_ASK;
            return;
        }
    }
}

// ---------------------------------------------------------------- a room plays
static bool     on;
// (the room's state is in its work memory: the firmware's static RAM is short)
#define r_ip       (WR->r_ip)
#define r_id       (WR->r_id)
#define r_name     (WR->r_name)
#define keys       (WR->keys)
#define sent_s     (WR->sent_s)
#define resolve    (WR->resolve)
#define lv         (WR->lv)
#define r_port     (WR->r_port)
#define q_round_at (WR->q_round_at)     // when the last round of questions began
#define q_rounds   (WR->q_rounds)
#define fails      (WR->fails)
#define radio      (WR->radio)
#define p_state    (WR->p_state)        // 'p' playing, 'a' paused, 's' stopped
#define p_el_ms    (WR->p_el_ms)
#define p_at       (WR->p_at)
#define p_total    (WR->p_total)
#define p_vol      (WR->p_vol)
#define p_mute     (WR->p_mute)
#define p_shuffle  (WR->p_shuffle)
#define p_repeat   (WR->p_repeat)       // 0 off, 1 all, 2 one
#define want_vol   (WR->want_vol)       // a volume key not sent yet (-1: none)
#define want_mute  (WR->want_mute)
#define nkeys      (WR->nkeys)
#define t_line_at  (WR->t_line_at)
#define v_line_at  (WR->v_line_at)
#define beat       (WR->beat)
#define beat_at    (WR->beat_at)
// the pretend bars
static uint32_t rnd = 12345u;

bool pva_sonos_url(const char *u) { return u && !strncmp(u, "sonos://", 8); }
bool pva_sonos_on(void) { return on; }

static void out_put(const char *s, size_t n)
{
    if (!WR || WR->out_n + n > sizeof WR->out) return;      // (not read: dropped)
    memcpy(WR->out + WR->out_n, s, n);
    WR->out_n = (uint16_t)(WR->out_n + n);
}

static void line_t(void)
{
    char b[64];
    int32_t e = p_el_ms + (p_state == 'p' ? (int32_t)(pva_hal_millis() - p_at) : 0);
    if (p_total && e > (int32_t)p_total * 1000) e = (int32_t)p_total * 1000;
    int16_t v = want_vol >= 0 ? want_vol : p_vol;
    int8_t mu = want_mute >= 0 ? want_mute : p_mute;
    int n = v >= 0 ? snprintf(b, sizeof b, "T%ld %u %c %d %d\n", (long)e, (unsigned)p_total, p_state ? p_state : 's', v, mu > 0 ? 1 : 0)
                   : snprintf(b, sizeof b, "T%ld %u %c\n", (long)e, (unsigned)p_total, p_state ? p_state : 's');
    out_put(b, (size_t)n);
    t_line_at = pva_hal_millis();
}

static void line_s(const char *artist, const char *title, const char *album)
{
    char a[PVA_ST_ARTIST_LEN], t[PVA_ST_TITLE_LEN], al[PVA_ST_ALBUM_LEN];
    pva_copy_ascii(a, sizeof a, artist, strlen(artist));
    pva_copy_ascii(t, sizeof t, title, strlen(title));
    pva_copy_ascii(al, sizeof al, album, strlen(album));
    if (!strcmp(a, sent_s[0]) && !strcmp(t, sent_s[1]) && !strcmp(al, sent_s[2])) return;
    snprintf(sent_s[0], TXT, "%s", a);
    snprintf(sent_s[1], TXT, "%s", t);
    snprintf(sent_s[2], TXT, "%s", al);
    char b[PVA_ST_ARTIST_LEN + PVA_ST_TITLE_LEN + PVA_ST_ALBUM_LEN + 8];
    int n = snprintf(b, sizeof b, "S%s\t%s\t%s\n", a, t, al);
    out_put(b, (size_t)n);
}

static void line_f(void)
{
    char b[PVA_ST_FMT_TEXT_LEN + 4], nm[PVA_ST_FMT_TEXT_LEN];
    snprintf(nm, sizeof nm, "SONOS %s", r_name);
    for (char *p = nm; *p; p++) if (*p >= 'a' && *p <= 'z') *p = (char)(*p - 32);
    int n = snprintf(b, sizeof b, "F%s\n", nm);
    out_put(b, (size_t)n);
}

// the bars: a pretend sound while it plays (the room's own does not come here), still while it pauses
static void line_v(void)
{
    uint32_t now = pva_hal_millis();
    char b[PVA_VIZ_BANDS + 2 + PVA_VIZ_WAVE + 4];
    size_t k = 0;
    b[k++] = 'V';
    bool plays = p_state == 'p' && p_mute != 1;
    if (plays && now - beat_at >= 480u + (rnd >> 28) * 10u) { beat_at = now; beat = 10; }
    for (unsigned i = 0; i < PVA_VIZ_BANDS; i++)
    {
        rnd = rnd * 1103515245u + 12345u;
        int target = 0;
        if (plays)
        {
            // more in the low bands, a beat in the lowest, a little noise everywhere
            int base = 20 - (int)(i * 14u / PVA_VIZ_BANDS);
            target = base + (int)((rnd >> 16) % 9u) - 4 + (i < 6 ? beat : beat / 3);
            if (p_vol >= 0) target = target * (40 + p_vol) / 140;
        }
        if (target < 0) target = 0;
        if (target > 31) target = 31;
        lv[i] = (uint8_t)(target > lv[i] ? target : lv[i] > 2 ? lv[i] - 2 : 0);
        b[k++] = (char)('0' + lv[i]);
    }
    if (beat) beat--;
    unsigned l = 0;
    for (unsigned i = 0; i < 8; i++) l += lv[i];
    l /= 8;
    b[k++] = (char)('0' + l);
    b[k++] = (char)('0' + (l > 1 ? l - 1 : l));
    for (unsigned i = 0; i < PVA_VIZ_WAVE; i++)
    {
        rnd = rnd * 1103515245u + 12345u;
        int s = plays ? (int)((rnd >> 16) % (2u * l + 1u)) - (int)l : 0;    // -l..l, in steps of 3 (the line's form)
        b[k++] = (char)(' ' + (s * 3 + 128) / 3);
    }
    b[k++] = '\n';
    out_put(b, k);
    v_line_at = now;
}

static int hms(const char *t)          // "0:03:45" -> seconds (-1: none)
{
    int h, m, s;
    if (sscanf(t, "%d:%d:%d", &h, &m, &s) != 3) return -1;
    return h * 3600 + m * 60 + s;
}

static bool radio_uri(const char *u)
{
    static const char *const pre[] = { "x-sonosapi-stream:", "x-sonosapi-radio:", "x-rincon-mp3radio:", "x-sonosapi-hls:",
                                       "aac:", "hls-radio:", NULL };
    for (int i = 0; pre[i]; i++) if (!strncmp(u, pre[i], strlen(pre[i]))) return true;
    return false;
}

// the round's answers made into the screen's lines
static void publish(void)
{
    char t[TXT], a[TXT], al[TXT];
    snprintf(t, sizeof t, "%s", W->title);
    snprintf(a, sizeof a, "%s", W->creator);
    snprintf(al, sizeof al, "%s", W->album);
    int total = hms(W->dur), rel = hms(W->rel);
    radio = radio_uri(W->uri) || (total <= 0 && W->sc[0]);
    if (!strncmp(W->uri, "x-rincon-stream:", 16)) { snprintf(t, sizeof t, "Line-in"); a[0] = al[0] = 0; }
    else if (!strncmp(W->uri, "x-sonos-htastream:", 18)) { snprintf(t, sizeof t, "TV"); a[0] = al[0] = 0; }
    if (radio)
    {
        // a station: the song it plays ("Artist - Title", or "TYPE=SNG|TITLE t|ARTIST a|..."), its name
        char st[TXT];
        snprintf(st, sizeof st, "%s", W->station[0] ? W->station : t);
        const char *sc = W->sc;
        char *ti = strstr(sc, "TITLE "), *ar = strstr(sc, "ARTIST ");
        if (!strncmp(sc, "ZPSTR_", 6)) sc = "";
        if (ti && strchr(sc, '|'))
        {
            snprintf(t, sizeof t, "%.*s", (int)strcspn(ti + 6, "|"), ti + 6);
            if (ar) snprintf(a, sizeof a, "%.*s", (int)strcspn(ar + 7, "|"), ar + 7); else a[0] = 0;
        }
        else if (strstr(sc, " - "))
        {
            const char *dsh = strstr(sc, " - ");
            snprintf(a, sizeof a, "%.*s", (int)(dsh - sc), sc);
            snprintf(t, sizeof t, "%s", dsh + 3);
        }
        else if (sc[0]) { snprintf(t, sizeof t, "%s", sc); a[0] = 0; }
        else { snprintf(t, sizeof t, "%s", st); a[0] = 0; }
        snprintf(al, sizeof al, "%s", st);
        total = 0;
    }
    if (W->state[0])
        p_state = !strcmp(W->state, "PLAYING") || !strcmp(W->state, "TRANSITIONING") ? 'p' : !strcmp(W->state, "PAUSED_PLAYBACK") ? 'a' : 's';
    if (!t[0] && p_state == 's') snprintf(a, sizeof a, "Nothing plays in %s", r_name);
    p_total = (uint16_t)(total > 0 ? total : 0);
    if (rel >= 0) { p_el_ms = rel * 1000; p_at = pva_hal_millis(); }
    if (W->mode[0])
    {
        p_shuffle = !strncmp(W->mode, "SHUFFLE", 7);
        p_repeat = strstr(W->mode, "REPEAT_ONE") ? 2 : (!strcmp(W->mode, "REPEAT_ALL") || !strcmp(W->mode, "SHUFFLE")) ? 1 : 0;
    }
    if (W->vol[0]) p_vol = (int16_t)atoi(W->vol);
    if (W->mute[0]) p_mute = (int8_t)(atoi(W->mute) != 0);
    line_s(a, t, al);
    line_t();
}

static void clear_answers(void)
{
    W->state[0] = W->dur[0] = W->rel[0] = W->uri[0] = W->mode[0] = W->vol[0] = W->mute[0] = 0;
    W->title[0] = W->creator[0] = W->album[0] = W->sc[0] = 0;
}

int pva_sonos_start(const char *u)
{
    size_t sz;
    uint8_t *m = pva_net_sonos_mem(&sz);
    if (!m || sz < sizeof(work_t)) return PVA_E_NOWIFI;
    // sonos://<ip>:<port>/<id>#<name>
    const char *h = u + 8, *c = strchr(h, ':'), *sl = strchr(h, '/'), *hash = strchr(h, '#');
    size_t hl = (size_t)((c ? c : sl ? sl : h) - h), il = sl ? (hash ? (size_t)(hash - sl - 1) : strlen(sl + 1)) : 0;
    if (!sl || (c && c > sl) || !hl || hl >= 16 || !il || il >= ID_LEN) return PVA_E_ARGS;
    if (web_mine && W == WR) { pva_web_abort(); web_st = 0; }
    WR = (work_t *)(void *)m;
    work_init(WR);
    snprintf(r_ip, sizeof r_ip, "%.*s", (int)hl, h);
    r_port = c ? (uint16_t)atoi(c + 1) : 1400u;
    snprintf(r_id, sizeof r_id, "%.*s", (int)il, sl + 1);
    snprintf(r_name, sizeof r_name, "%s", hash ? hash + 1 : "");
    if (d == D_IDLE) W = WR;
    on = true;
    q_step = Q_NONE;
    q_round_at = 0;
    q_rounds = 0;
    fails = 0;
    radio = false;
    p_state = 's';
    p_el_ms = 0;
    p_at = pva_hal_millis();
    p_total = 0;
    p_vol = -1;
    p_mute = -1;
    want_vol = -1;
    want_mute = -1;
    nkeys = 0;
    resolve[0] = 0;
    sent_s[0][0] = sent_s[1][0] = sent_s[2][0] = 1;     // (the first S line goes)
    pva_log("sonos: %s at %s:%u", r_name, r_ip, (unsigned)r_port);
    line_f();
    line_s("Sonos", r_name[0] ? r_name : "A room", "");
    line_t();
    return PVA_OK;
}

void pva_sonos_stop(void)
{
    if (!on) return;
    on = false;
    if (web_mine && W == WR) { pva_web_abort(); web_st = 0; }
    WR = NULL;
    if (d == D_IDLE) W = NULL;
    pva_log("sonos: stopped");
}

size_t pva_sonos_read(uint8_t *dst, size_t n)
{
    if (!on || !WR) return 0;
    uint32_t now = pva_hal_millis();
    if (now - v_line_at >= 40u) line_v();
    if (now - t_line_at >= 500u) line_t();
    size_t k = WR->out_n < n ? WR->out_n : n;
    memcpy(dst, WR->out, k);
    memmove(WR->out, WR->out + k, WR->out_n - k);
    WR->out_n = (uint16_t)(WR->out_n - k);
    return k;
}

// a key of the screen ("toggle", "next", "seek&to=95", "vol&v=40", "mute&on=1", "shuffle&on=1", "repeat&on=2")
void pva_sonos_key(const char *k)
{
    if (!on) return;
    const char *v = strchr(k, '=');
    int a = v ? atoi(v + 1) : 0;
    if (!strncmp(k, "vol&", 4)) { if (v) want_vol = (int16_t)(a < 0 ? 0 : a > 100 ? 100 : a); return; }
    if (!strncmp(k, "mute&", 5)) { want_mute = (int8_t)(a != 0); return; }
    if (radio && (!strcmp(k, "next") || !strcmp(k, "prev") || !strncmp(k, "seek", 4) || !strncmp(k, "shuffle", 7) || !strncmp(k, "repeat", 6))) return;
    if (nkeys >= 4) return;
    snprintf(keys[nkeys++], sizeof keys[0], "%s", k);
    // what shows at once (the room says it on the next round)
    if (!strcmp(k, "toggle") && p_state != 's')
    {
        if (p_state == 'p') { p_el_ms += (int32_t)(pva_hal_millis() - p_at); p_state = 'a'; }
        else p_state = 'p';
        p_at = pva_hal_millis();
        line_t();
    }
}

// a key as a SOAP request (false: nothing to send)
static bool send_key(const char *k)
{
    char args[160];
    const char *v = strchr(k, '=');
    int a = v ? atoi(v + 1) : 0;
    if (!strcmp(k, "toggle") || !strcmp(k, "play") || !strcmp(k, "pause"))
    {
        // (the state already shows what it is to be)
        bool play = !strcmp(k, "play") || (!strcmp(k, "toggle") && p_state == 'p');
        if (play) return soap(r_ip, r_port, SV_AVT, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>", Q_CMD) == PVA_OK;
        return soap(r_ip, r_port, SV_AVT, radio ? "Stop" : "Pause", "<InstanceID>0</InstanceID>", Q_CMD) == PVA_OK;
    }
    if (!strcmp(k, "next")) return soap(r_ip, r_port, SV_AVT, "Next", "<InstanceID>0</InstanceID>", Q_CMD) == PVA_OK;
    if (!strcmp(k, "prev")) return soap(r_ip, r_port, SV_AVT, "Previous", "<InstanceID>0</InstanceID>", Q_CMD) == PVA_OK;
    if (!strncmp(k, "seek", 4))
    {
        int to = !strncmp(k, "seek&to=", 8) ? a : (int)((p_el_ms + (p_state == 'p' ? (int32_t)(pva_hal_millis() - p_at) : 0)) / 1000) + a;
        if (to < 0) to = 0;
        if (p_total && to >= p_total) to = p_total - 1;
        snprintf(args, sizeof args, "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%d:%02d:%02d</Target>", to / 3600, to / 60 % 60, to % 60);
        p_el_ms = to * 1000;
        p_at = pva_hal_millis();
        return soap(r_ip, r_port, SV_AVT, "Seek", args, Q_CMD) == PVA_OK;
    }
    if (!strncmp(k, "shuffle", 7) || !strncmp(k, "repeat", 6))
    {
        if (k[0] == 's') p_shuffle = a != 0; else p_repeat = (uint8_t)(a > 2 ? 2 : a);
        static const char *const modes[2][3] = { { "NORMAL", "REPEAT_ALL", "REPEAT_ONE" }, { "SHUFFLE_NOREPEAT", "SHUFFLE", "SHUFFLE_REPEAT_ONE" } };
        snprintf(args, sizeof args, "<InstanceID>0</InstanceID><NewPlayMode>%s</NewPlayMode>", modes[p_shuffle][p_repeat]);
        return soap(r_ip, r_port, SV_AVT, "SetPlayMode", args, Q_CMD) == PVA_OK;
    }
    return false;
}

// a station: its name (asked once, and again now and then)
static bool need_media(void) { return (radio_uri(W->uri) || W->sc[0]) && (!W->station[0] || q_rounds % SLOW_EVERY == 1u); }

static void room_poll(void)
{
    if (!on || !WR || d != D_IDLE) return;
    W = WR;
    uint32_t now = pva_hal_millis();
    bool ok;
    if (web_mine)
    {
        if (!web_finished(&ok)) return;
        uint8_t what = W->what;
        if (what == Q_CMD) { q_round_at = 0; return; }      // (a round at once: what the key changed)
        if (what == Q_TOPO)
        {
            // the leader of the group the room joined: its address
            if (ok && W->found_ip[0]) { snprintf(r_ip, sizeof r_ip, "%s", W->found_ip); r_port = W->found_port; snprintf(r_id, sizeof r_id, "%s", resolve); pva_log("sonos: the room is in %s's group now", r_id); }
            resolve[0] = 0;
            q_step = Q_NONE;
            q_round_at = 0;
            return;
        }
        if (!ok)
        {
            q_step = Q_NONE;
            if (++fails == FAIL_SHOW)
            {
                char t[NAME_LEN + 24];
                snprintf(t, sizeof t, "%s does not answer", r_name[0] ? r_name : "The room");
                p_state = 's';
                line_s(t, "", "");
                line_t();
            }
            return;
        }
        if (what == Q_POS && !strncmp(W->uri, "x-rincon:", 9))
        {
            // the room joined another group: that group's leader, through the zone groups
            snprintf(resolve, sizeof resolve, "%s", W->uri + 9);
            q_step = Q_TOPO;
        }
        else if (what == Q_POS) q_step = Q_TRANS;
        else if (what == Q_TRANS) q_step = (q_rounds % SLOW_EVERY == 1u) ? Q_MODE : need_media() ? Q_MEDIA : Q_NONE;
        else if (what == Q_MODE) q_step = Q_VOL;
        else if (what == Q_VOL) q_step = Q_MUTE;
        else if (what == Q_MUTE) q_step = need_media() ? Q_MEDIA : Q_NONE;
        else q_step = Q_NONE;
        if (q_step == Q_NONE) { fails = 0; publish(); }
    }
    if (pva_web_busy()) return;
    // the keys first, then the round's next question
    if (want_vol >= 0)
    {
        char a[120];
        snprintf(a, sizeof a, "<InstanceID>0</InstanceID><DesiredVolume>%d</DesiredVolume>", want_vol);
        if (soap(r_ip, r_port, SV_GRC, "SetGroupVolume", a, Q_CMD) == PVA_OK) { p_vol = want_vol; want_vol = -1; }
        return;
    }
    if (want_mute >= 0)
    {
        char a[120];
        snprintf(a, sizeof a, "<InstanceID>0</InstanceID><DesiredMute>%d</DesiredMute>", want_mute);
        if (soap(r_ip, r_port, SV_GRC, "SetGroupMute", a, Q_CMD) == PVA_OK) { p_mute = want_mute; want_mute = -1; }
        return;
    }
    if (nkeys)
    {
        char k[20];
        snprintf(k, sizeof k, "%s", keys[0]);
        memmove(keys, keys + 1, sizeof keys[0] * (size_t)(nkeys - 1));
        nkeys--;
        send_key(k);
        return;
    }
    if (q_step == Q_NONE)
    {
        uint32_t every = fails >= FAIL_SHOW ? 3u * POLL_MS : POLL_MS;
        if (q_round_at && now - q_round_at < every) return;
        q_round_at = now;
        q_rounds++;
        clear_answers();
        q_step = Q_POS;
    }
    static const char *const inst = "<InstanceID>0</InstanceID>";
    switch (q_step)
    {
        case Q_POS:   soap(r_ip, r_port, SV_AVT, "GetPositionInfo", inst, Q_POS); break;
        case Q_TRANS: soap(r_ip, r_port, SV_AVT, "GetTransportInfo", inst, Q_TRANS); break;
        case Q_MODE:  soap(r_ip, r_port, SV_AVT, "GetTransportSettings", inst, Q_MODE); break;
        case Q_VOL:   soap(r_ip, r_port, SV_GRC, "GetGroupVolume", inst, Q_VOL); break;
        case Q_MUTE:  soap(r_ip, r_port, SV_GRC, "GetGroupMute", inst, Q_MUTE); break;
        case Q_MEDIA: W->station[0] = 0; soap(r_ip, r_port, SV_AVT, "GetMediaInfo", inst, Q_MEDIA); break;
        case Q_TOPO:
            W->find[0] = 0;
            snprintf(W->find, sizeof W->find, "%s", resolve);
            W->found_ip[0] = 0;
            soap(r_ip, r_port, SV_ZGT, "GetZoneGroupState", "", Q_TOPO);
            break;
    }
}

void pva_sonos_poll(void)
{
    d_poll();
    room_poll();
}
