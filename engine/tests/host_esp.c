// Simulated ESP-01 (UNAPI ESP8266 firmware) for the host test and the openMSX
// device: it reads the engine's requests, answers them after a configurable
// delay through a UART of limited speed, and serves HTTP streams made from a
// local MP3 file.
//
// Hosts / URLs it knows:
//   radio.test (10.0.0.1)
//     /stream.mp3     ICY stream, metaint 8192, icy-name "Test FM", titles
//                     "Artist One - Song A", "Artist Two - Song B", ... changing
//     /plain          stream without metadata
//     /redirect       302 to http://radio2.test:8000/live
//     /relative       302 to /stream.mp3
//     /list.pls       audio/x-scpls body pointing at /stream.mp3
//     /aac            content-type audio/aacp
//     /missing        404
//   radio2.test (10.0.0.2) port 8000  /live  plain stream
//   secure.test (10.0.0.3)            TLS only, /stream.mp3
//   all.api.radio-browser.info, de1.api.radio-browser.info (10.0.0.4) and
//   nl1.api.radio-browser.info (10.0.0.5): a small Radio Browser API
//     /json/countries           a few countries (UTF-8 escapes, one empty)
//     /json/stations/search     stations by country / tag / order, with AAC,
//                               HLS, broken and over-long ones mixed in;
//                               tag=many gives 150 stations
//     /json/url/<uuid>          counts a click
//   anything else: DNS error

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "../pva_internal.h"

// ---------------- configuration (tests change these) ----------------
bool     host_esp_present = true;
uint8_t  host_esp_wifi_state = 2;           // NET_STATE answer, 2 = connected
uint32_t host_esp_uart_bpms = 86;           // 859372 baud / 10 bits / 1000
uint32_t host_esp_server_bps = 24000;       // server sends this many bytes/s (128 kbit/s = 16000)
uint32_t host_esp_latency_ms = 2;           // answer delay of the ESP
uint32_t host_esp_dns_ms = 40;
uint32_t host_esp_open_ms = 60;
uint32_t host_esp_tls_ms = 1800;
uint32_t host_esp_rcv_limit = 1024;         // most data bytes in one TCP_RCV answer
uint32_t host_esp_drop_after = 0;           // close each stream after this many body bytes (0 = never)
uint32_t host_esp_stall_at = 0;             // pause the server at this body byte ...
uint32_t host_esp_stall_ms = 0;             // ... for this long
size_t   host_stream_ram_size = 128u * 1024u;
uint32_t host_esp_rtt_ms = 0;               // > 0: TCP window limit (2144 bytes per round trip)
bool     host_esp_close_silent = true;      // as the real ESP: TCP_RCV of a closed connection
                                            // answers "no data", only TCP_STATE tells the close
uint32_t host_esp_state_asks;
uint32_t host_esp_delay_next_rcv;           // > 0: the next TCP_RCV answer comes this late (once)
bool     host_esp_api_down = false;         // 10.0.0.4 refuses connections (a mirror must be used)
bool     host_esp_api_all_down = false;     // all API servers refuse
uint32_t host_esp_api_bps = 20000;          // API reply speed
uint32_t host_esp_clicks;
char     host_esp_last_click[48];
char     host_esp_last_api[300];

// statistics for the checks
uint32_t host_esp_opens, host_esp_closes, host_esp_tls_opens, host_esp_requests, host_esp_rcvs;
char     host_esp_last_sni[64];
char     host_esp_last_get[300];
uint32_t host_esp_rx_dropped;               // bytes the engine never read (stray)

// ---------------- audio source ----------------
static uint8_t *src;
static size_t   src_len;

int host_esp_load_audio(const char *mp3_path)
{
    FILE *f = fopen(mp3_path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    free(src);
    src = malloc((size_t)n);
    src_len = fread(src, 1, (size_t)n, f) ;
    fclose(f);
    // skip an ID3v2 tag: a stream starts with frames
    if (src_len > 10 && !memcmp(src, "ID3", 3))
    {
        size_t t = 10u + (((size_t)src[6] & 0x7F) << 21 | ((size_t)src[7] & 0x7F) << 14 | ((size_t)src[8] & 0x7F) << 7 | (src[9] & 0x7F));
        if (t < src_len) { memmove(src, src + t, src_len - t); src_len -= t; }
    }
    return 0;
}

// ---------------- byte queues ----------------
typedef struct { uint8_t *b; size_t len, cap; } bq_t;
static void bq_put(bq_t *q, const void *p, size_t n)
{
    if (q->len + n > q->cap) { q->cap = (q->len + n) * 2 + 256; q->b = realloc(q->b, q->cap); }
    memcpy(q->b + q->len, p, n);
    q->len += n;
}
static void bq_drop(bq_t *q, size_t n) { if (n > q->len) n = q->len; memmove(q->b, q->b + n, q->len - n); q->len -= n; }

// pending answers: released to the UART at 'at'
typedef struct ans { uint32_t at; bq_t data; struct ans *next; } ans_t;
static ans_t *answers;
static bq_t uart_rx;            // bytes on their way to the engine (already "on the wire")
static bq_t tx;                 // request bytes from the engine
static bool owned;
static uint32_t now_ms;

static void answer(uint32_t delay, uint8_t fn, uint8_t rc, const void *p, size_t n)
{
    ans_t *a = calloc(1, sizeof *a);
    a->at = now_ms + delay;
    uint8_t h[4] = { fn, rc, (uint8_t)(n >> 8), (uint8_t)n };
    bq_put(&a->data, h, 4);
    if (rc == 0 && n) bq_put(&a->data, p, n);
    ans_t **pp = &answers;
    while (*pp) pp = &(*pp)->next;
    *pp = a;
}

// ---------------- connections / HTTP servers ----------------
typedef struct
{
    bool     used, tls;
    uint8_t  ip[4];
    uint16_t port;
    bq_t     reqbuf;
    bool     got_request;
    bq_t     out;               // bytes the server has sent (TCP receive buffer of the ESP)
    // stream generator
    int      kind;              // 0 none, 1 icy, 2 plain, 3 fixed body (headers+body in out already)
    uint32_t metaint, until_meta, title_no, meta_count;
    size_t   src_pos;
    uint32_t body_sent;
    double   credit;
    bool     closed;            // server closed (after the data in 'out')
    uint32_t stall_until;
    bq_t     pend;              // kind 4: reply that trickles out at host_esp_api_bps
} conn_t;
static conn_t conns[5];         // 1..4

static const char *titles[] = { "Artist One - Song A", "Artist Two - Song B", "Caf\xc3\xa9 Trio - Song C" };

static void http_reply(conn_t *c, const char *head, const char *body)
{
    bq_put(&c->out, head, strlen(head));
    if (body) bq_put(&c->out, body, strlen(body));
    c->kind = 3;
    c->closed = true;
}

// ---------------- the Radio Browser API ----------------
typedef struct { const char *name, *url, *codec, *country, *tags; int bitrate, hls, ok; } st_t;
static const st_t stations[] = {
    { "Test FM", "http://radio.test/stream.mp3", "MP3", "The Netherlands", "pop,80s,rock", 128, 0, 1 },
    { "Radio Two Live", "http://radio2.test:8000/live", "MP3", "Germany", "jazz,smooth jazz", 128, 0, 1 },
    { "  Plain \\\"Quoted\\\" Radio", "http://radio.test/plain", "mp3", "The Netherlands", "jazz,90s", 128, 0, 1 },
    { "Caf\\u00e9 AAC", "http://radio.test/aac", "AAC+", "Germany", "jazz", 64, 0, 1 },
    { "HLS One", "http://radio.test/hls.m3u8", "MP3", "Germany", "pop", 128, 1, 1 },
    { "Broken FM", "http://radio.test/stream.mp3", "MP3", "Germany", "pop,jazz", 128, 0, 0 },
    { "Secure Jazz", "https://secure.test/stream.mp3", "MP3", "C\\u00f4te D'ivoire", "jazz,80s", 192, 0, 1 },
    { "NC Secure", "https://secure.test/stream.mp3", "MP3", "New Caledonia", "pacific", 128, 0, 1 },
    { "NC Plain", "http://radio.test/plain", "MP3", "New Caledonia", "pacific", 128, 0, 1 },
    { "NC Live", "http://radio2.test:8000/live", "MP3", "New Caledonia", "pacific", 128, 0, 1 },
    { "Long URL", "http://radio.test/stream.mp3?xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "MP3", "Germany", "pop", 128, 0, 1 },
};

static void station_json(bq_t *b, const st_t *t, int i)
{
    char j[1200];
    int n = snprintf(j, sizeof j,
        "{\"changeuuid\":\"c-%d\",\"stationuuid\":\"9617a958-0601-11e8-ae97-52543be04c%02d\",\"serveruuid\":null,"
        "\"name\":\"%s\",\"url\":\"%s\",\"url_resolved\":\"%s\",\"homepage\":\"http://x.test/\",\"favicon\":\"\","
        "\"tags\":\"%s\",\"country\":\"%s\",\"countrycode\":\"XX\",\"iso_3166_2\":null,\"state\":\"\","
        "\"language\":\"dutch,english\",\"languagecodes\":\"nl\",\"votes\":%d,\"lastchangetime\":\"2024-01-01 10:00:00\","
        "\"codec\":\"%s\",\"bitrate\":%d,\"hls\":%d,\"lastcheckok\":%d,\"clickcount\":%d,\"clicktrend\":-1,"
        "\"ssl_error\":0,\"geo_lat\":52.1,\"geo_long\":-4.5e0,\"has_extended_info\":false}",
        i, i % 100, t->name, t->url, t->url, t->tags, t->country, 100 - i, t->codec, t->bitrate, t->hls, t->ok, 1000 - i);
    bq_put(b, j, (size_t)n);
}

static void api(conn_t *c, const char *path)
{
    bq_t b = { 0 };
    snprintf(host_esp_last_api, sizeof host_esp_last_api, "%s", path);
    bool clen = c->ip[3] == 5;              // the second server always sends Content-Length
    if (!strncmp(path, "/json/countries", 15))
    {
        const char *j = "[{\"name\":\"C\\u00f4te D'ivoire\",\"iso_3166_1\":\"CI\",\"stationcount\":12},\n"
                        " {\"name\":\"Germany\",\"iso_3166_1\":\"DE\",\"stationcount\":3210},\n"
                        " {\"name\":\"New Caledonia\",\"iso_3166_1\":\"NC\",\"stationcount\":3},\n"
                        " {\"name\":\"Nowhere\",\"iso_3166_1\":\"NO\",\"stationcount\":0},\n"
                        " {\"name\":\"The Netherlands\",\"iso_3166_1\":\"NL\",\"stationcount\":987}]";
        bq_put(&b, j, strlen(j));
    }
    else if (!strncmp(path, "/json/stations/search?", 22))
    {
        const char *q = path + 22;
        char country[64] = "", tag[64] = "";
        const char *p;
        if ((p = strstr(q, "country=")) && (p == q || p[-1] == '&')) sscanf(p + 8, "%63[^&]", country);
        if ((p = strstr(q, "tag="))) sscanf(p + 4, "%63[^&]", tag);
        char name[64] = "";
        if ((p = strstr(q, "name=")) && (p == q || p[-1] == '&')) sscanf(p + 5, "%63[^&]", name);
        for (char *s2 = name, *d = name; ; )
        {
            if (*s2 == '%' && s2[1] && s2[2]) { char h[3] = { s2[1], s2[2], 0 }; *d++ = (char)strtol(h, NULL, 16); s2 += 3; }
            else if (!(*d++ = *s2++)) break;
        }
        // undo the URL encoding
        for (char *s2 = country, *d = country; ; )
        {
            if (*s2 == '%' && s2[1] && s2[2]) { char h[3] = { s2[1], s2[2], 0 }; *d++ = (char)strtol(h, NULL, 16); s2 += 3; }
            else if (!(*d++ = *s2++)) break;
        }
        for (char *s2 = tag, *d = tag; ; )
        {
            if (*s2 == '%' && s2[1] && s2[2]) { char h[3] = { s2[1], s2[2], 0 }; *d++ = (char)strtol(h, NULL, 16); s2 += 3; }
            else if (!(*d++ = *s2++)) break;
        }
        bq_put(&b, "[", 1);
        int n = 0;
        int limit = 100000, offset = 0;
        if ((p = strstr(q, "limit="))) limit = atoi(p + 6);
        if ((p = strstr(q, "offset="))) offset = atoi(p + 7);
        if (!strcmp(tag, "many") || !strcmp(tag, "rock"))
        {
            // 150 stations, in pages (limit / offset)
            for (int i = offset; i < 150 && i < offset + limit; i++)
            {
                char nm[40];
                snprintf(nm, sizeof nm, "%s Station %03d", tag[0] == 'r' ? "Rock" : "Many", i);
                char su[48];
                snprintf(su, sizeof su, "http://radio.test/plain?n=%03d", i);
                st_t t = { nm, su, "MP3", "Germany", tag, 128, 0, 1 };
                if (n++) bq_put(&b, ",", 1);
                station_json(&b, &t, i);
            }
        }
        else
            for (int i = 0; i < (int)(sizeof stations / sizeof stations[0]); i++)
            {
                const st_t *t = &stations[i];
                char cj[64];
                // the country in the table is JSON-escaped: compare the escape of 'country'
                snprintf(cj, sizeof cj, "%s", t->country);
                if (!strcmp(cj, "C\\u00f4te D'ivoire")) snprintf(cj, sizeof cj, "C\xc3\xb4te D'ivoire");
                if (country[0] && strcmp(country, cj)) continue;
                if (tag[0] && !strstr(t->tags, tag)) continue;
                if (name[0])                    // a part of the name, any case
                {
                    char a[200], b2[64];
                    size_t k;
                    for (k = 0; t->name[k] && k < sizeof a - 1; k++) a[k] = (char)tolower((unsigned char)t->name[k]);
                    a[k] = 0;
                    for (k = 0; name[k] && k < sizeof b2 - 1; k++) b2[k] = (char)tolower((unsigned char)name[k]);
                    b2[k] = 0;
                    if (!strstr(a, b2)) continue;
                }
                if (n++) bq_put(&b, ",", 1);
                station_json(&b, t, i);
            }
        bq_put(&b, "]", 1);
    }
    else if (!strncmp(path, "/json/url/", 10))
    {
        host_esp_clicks++;
        snprintf(host_esp_last_click, sizeof host_esp_last_click, "%s", path + 10);
        const char *j = "{\"ok\":true,\"message\":\"retrieved station url\",\"stationuuid\":\"x\",\"name\":\"x\",\"url\":\"http://radio.test/stream.mp3\"}";
        bq_put(&b, j, strlen(j));
    }
    else
    {
        http_reply(c, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n", "<html>no</html>");
        free(b.b);
        return;
    }
    if (b.len < 2048) clen = true;          // nginx: small replies have a length, big ones end with the close
    char hd[200];
    snprintf(hd, sizeof hd, "HTTP/1.1 200 OK\r\nServer: nginx\r\nContent-Type: application/json; charset=utf-8\r\n%s%s\r\n",
             clen ? "Content-Length: " : "", "");
    if (clen) { char l[40]; snprintf(l, sizeof l, "Content-Length: %u\r\n", (unsigned)b.len); snprintf(hd, sizeof hd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n%s\r\n", l); }
    bq_put(&c->out, hd, strlen(hd));
    bq_put(&c->pend, b.b, b.len);
    free(b.b);
    c->kind = 4;
    c->credit = 0;
}

static void serve(conn_t *c)
{
    char *r = (char *)c->reqbuf.b;
    char path[256] = "", hosth[128] = "";
    sscanf(r, "GET %255s", path);
    if (strncmp(path, "/json/", 6)) { char *qm = strchr(path, '?'); if (qm) *qm = 0; }   // a stream's ?query does not matter
    char *h = strstr(r, "\r\nHost: ");
    if (h) sscanf(h + 8, "%127[^\r]", hosth);
    snprintf(host_esp_last_get, sizeof host_esp_last_get, "%s", r);
    host_esp_requests++;
    bool icy_meta = strstr(r, "Icy-MetaData: 1") != NULL;
    bool r1 = c->ip[3] == 1, r2 = c->ip[3] == 2, sec = c->ip[3] == 3;
    if (c->ip[3] == 4 || c->ip[3] == 5)
    {
        if (!strstr(r, "User-Agent: ")) { http_reply(c, "HTTP/1.1 403 Forbidden\r\n\r\n", NULL); return; }
        api(c, path);
        return;
    }
    if (sec && !c->tls) { http_reply(c, "HTTP/1.1 400 Bad Request\r\n\r\n", NULL); return; }
    if ((r1 && !strcmp(path, "/stream.mp3")) || (sec && !strcmp(path, "/stream.mp3")))
    {
        char hd[300];
        snprintf(hd, sizeof hd, "ICY 200 OK\r\nicy-name: %s\r\ncontent-type: audio/mpeg\r\n%s\r\n",
                 sec ? "Secure Radio" : "Test FM", icy_meta ? "icy-metaint: 8192\r\n" : "");
        bq_put(&c->out, hd, strlen(hd));
        c->kind = 1;
        c->metaint = icy_meta ? 8192 : 0;
        c->until_meta = c->metaint;
        return;
    }
    if ((r1 && !strcmp(path, "/plain")) || (r2 && c->port == 8000 && !strcmp(path, "/live")))
    {
        const char *hd = "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nServer: test\r\n\r\n";
        bq_put(&c->out, hd, strlen(hd));
        c->kind = 2;
        return;
    }
    if (r1 && !strcmp(path, "/redirect")) { http_reply(c, "HTTP/1.1 302 Found\r\nLocation: http://radio2.test:8000/live\r\n\r\n", NULL); return; }
    if (r1 && !strcmp(path, "/relative")) { http_reply(c, "HTTP/1.1 301 Moved\r\nLocation: /stream.mp3\r\n\r\n", NULL); return; }
    if (r1 && !strcmp(path, "/list.pls"))
    {
        http_reply(c, "HTTP/1.1 200 OK\r\nContent-Type: audio/x-scpls\r\n\r\n",
                   "[playlist]\r\nNumberOfEntries=1\r\nFile1=http://radio.test/stream.mp3\r\nTitle1=Test FM\r\nLength1=-1\r\n");
        return;
    }
    if (r1 && !strcmp(path, "/aac")) { http_reply(c, "HTTP/1.1 200 OK\r\nContent-Type: audio/aacp\r\n\r\n", "xxxx"); return; }
    http_reply(c, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n", "<html>no</html>");
}

static void gen(conn_t *c, uint32_t ms)
{
    if (c->kind == 4)
    {
        // an API reply: at host_esp_api_bps, then the server closes
        c->credit += (double)host_esp_api_bps * ms / 1000.0;
        size_t k = (size_t)c->credit;
        if (k > c->pend.len) k = c->pend.len;
        if (c->out.len > 16384) k = 0;
        c->credit -= (double)k;
        bq_put(&c->out, c->pend.b, k);
        bq_drop(&c->pend, k);
        if (!c->pend.len) c->closed = true;
        return;
    }
    if (c->kind != 1 && c->kind != 2) return;
    if (c->closed) return;
    if (c->stall_until && now_ms < c->stall_until) return;
    double bps = host_esp_server_bps;
    if (host_esp_rtt_ms && 2144.0 * 1000.0 / host_esp_rtt_ms < bps) bps = 2144.0 * 1000.0 / host_esp_rtt_ms;
    c->credit += bps * ms / 1000.0;
    size_t want = (size_t)c->credit;
    if (c->out.len > 16384) want = 0;           // TCP window full: server waits
    c->credit -= (double)want;
    if (c->credit > 4096) c->credit = 4096;
    uint8_t tmp[4096];
    while (want)
    {
        size_t k = want > sizeof tmp ? sizeof tmp : want;
        size_t o = 0;
        while (o < k)
        {
            if (c->metaint && c->until_meta == 0)
            {
                // a title every 6th block (about 3 s at 128 kbit/s), else an empty block
                if (c->meta_count++ % 6u == 0u)
                {
                    char m[96] = { 0 };
                    int n = snprintf(m, sizeof m, "StreamTitle='%s';", titles[c->title_no++ % 3]);
                    int blocks = (n + 15) / 16;
                    tmp[o++] = (uint8_t)blocks;
                    bq_put(&c->out, tmp, o);
                    o = 0;
                    bq_put(&c->out, m, (size_t)blocks * 16u);
                }
                else tmp[o++] = 0;
                c->until_meta = c->metaint;
                continue;
            }
            tmp[o++] = src[c->src_pos];
            c->src_pos = (c->src_pos + 1) % src_len;
            c->body_sent++;
            if (c->metaint) c->until_meta--;
            if (host_esp_stall_at && c->body_sent == host_esp_stall_at) { c->stall_until = now_ms + host_esp_stall_ms; host_esp_stall_at = 0; break; }
            if (host_esp_drop_after && c->body_sent >= host_esp_drop_after) { c->closed = true; break; }
        }
        bq_put(&c->out, tmp, o);
        want -= k;
        if (c->closed || (c->stall_until && now_ms < c->stall_until)) break;
    }
}

static int dns(const char *name, uint8_t *ip)
{
    static const struct { const char *n; uint8_t ip[4]; } t[] = {
        { "radio.test", { 10, 0, 0, 1 } }, { "radio2.test", { 10, 0, 0, 2 } }, { "secure.test", { 10, 0, 0, 3 } },
        { "all.api.radio-browser.info", { 10, 0, 0, 4 } }, { "de1.api.radio-browser.info", { 10, 0, 0, 4 } },
        { "nl1.api.radio-browser.info", { 10, 0, 0, 5 } } };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) if (!strcmp(name, t[i].n)) { memcpy(ip, t[i].ip, 4); return 0; }
    return -1;
}

static void request(const uint8_t *p, size_t n)
{
    uint8_t fn = p[0];
    const uint8_t *a = p + 3;
    size_t len = n - 3;
    uint32_t L = host_esp_latency_ms;
    switch (fn)
    {
        case 3: answer(L, fn, 0, &host_esp_wifi_state, 1); break;
        case 206:
        {
            char name[80] = "";
            size_t k = len - 1 < sizeof name - 1 ? len - 1 : sizeof name - 1;
            memcpy(name, a + 1, k);
            name[k] = 0;
            uint8_t ip[4];
            if (dns(name, ip) == 0) answer(host_esp_dns_ms, fn, 0, ip, 4);
            else answer(host_esp_dns_ms, fn, 2, NULL, 0);
            break;
        }
        case 13:
        {
            int slot = 0;
            for (int i = 1; i <= 4; i++) if (!conns[i].used) { slot = i; break; }
            bool tls = (a[10] & 0x04) != 0;
            bool tls_busy = false;
            for (int i = 1; i <= 4; i++) if (conns[i].used && conns[i].tls) tls_busy = true;
            if (!slot || (tls && tls_busy)) { answer(host_esp_open_ms, fn, 9, NULL, 0); break; }   // ERR_NO_FREE_CONN
            uint16_t port = (uint16_t)(a[4] | (a[5] << 8));
            bool known = (a[0] == 10 && a[3] >= 1 && a[3] <= 5);
            if ((a[3] == 4 && host_esp_api_down) || (a[3] >= 4 && host_esp_api_all_down)) known = false;
            if (!slot || !known || (a[3] == 2 && port != 8000)) { answer(host_esp_open_ms, fn, 3, NULL, 0); break; }
            conn_t *c = &conns[slot];
            memset(c, 0, sizeof *c);
            c->used = true;
            c->tls = tls;
            memcpy(c->ip, a, 4);
            c->port = port;
            host_esp_opens++;
            if (tls)
            {
                host_esp_tls_opens++;
                size_t k = len > 11 ? len - 11 : 0;
                if (k > sizeof host_esp_last_sni - 1) k = sizeof host_esp_last_sni - 1;
                memcpy(host_esp_last_sni, a + 11, k);
                host_esp_last_sni[k] = 0;
            }
            uint8_t cn = (uint8_t)slot;
            answer(host_esp_open_ms + (tls ? host_esp_tls_ms : 0), fn, 0, &cn, 1);
            break;
        }
        case 14:
        case 15:
        {
            uint8_t cn = a[0];
            if (cn >= 1 && cn <= 4 && conns[cn].used)
            {
                free(conns[cn].reqbuf.b);
                free(conns[cn].out.b);
                free(conns[cn].pend.b);
                memset(&conns[cn], 0, sizeof conns[cn]);
                host_esp_closes++;
                answer(L, fn, 0, NULL, 0);
            }
            else answer(L, fn, 11, NULL, 0);
            break;
        }
        case 17:
        {
            uint8_t cn = a[0];
            if (cn < 1 || cn > 4 || !conns[cn].used) { answer(L, fn, 11, NULL, 0); break; }
            conn_t *c = &conns[cn];
            bq_put(&c->reqbuf, a + 2, len - 2);
            uint8_t z = 0;
            bq_put(&c->reqbuf, &z, 1);
            c->reqbuf.len--;
            if (!c->got_request && strstr((char *)c->reqbuf.b, "\r\n\r\n")) { c->got_request = true; serve(c); }
            answer(L, fn, 0, NULL, 0);
            break;
        }
        case 18:
        {
            host_esp_rcvs++;
            uint8_t cn = a[0];
            uint16_t want = (uint16_t)(a[1] | (a[2] << 8));
            if (cn < 1 || cn > 4 || !conns[cn].used) { answer(L, fn, 11, NULL, 0); break; }
            conn_t *c = &conns[cn];
            if (c->out.len == 0 && c->closed && !host_esp_close_silent) { answer(L, fn, 11, NULL, 0); break; }
            size_t k = c->out.len;
            if (k > want) k = want;
            if (k > host_esp_rcv_limit) k = host_esp_rcv_limit;
            uint8_t *buf = malloc(k + 2);
            buf[0] = 0; buf[1] = 0;
            memcpy(buf + 2, c->out.b, k);
            bq_drop(&c->out, k);
            answer(L + host_esp_delay_next_rcv, fn, 0, buf, k + 2);
            host_esp_delay_next_rcv = 0;
            free(buf);
            break;
        }
        case 16:
        {
            host_esp_state_asks++;
            uint8_t cn = a[0];
            if (cn < 1 || cn > 4 || !conns[cn].used) { answer(L, fn, 11, NULL, 0); break; }
            conn_t *c = &conns[cn];
            uint8_t r[16] = { 0 };
            r[1] = c->closed ? 7 : 4;               // CLOSE-WAIT / ESTABLISHED
            r[2] = (uint8_t)c->out.len;
            r[3] = (uint8_t)(c->out.len >> 8);
            r[6] = 0xFF; r[7] = 0xFF;
            answer(L, fn, 0, r, 16);
            break;
        }
        default:
            answer(L, fn, 1, NULL, 0);
    }
}

static void parse_tx(void)
{
    while (tx.len >= 3)
    {
        size_t len = ((size_t)tx.b[1] << 8) | tx.b[2];
        if (tx.len < 3 + len) return;
        request(tx.b, 3 + len);
        bq_drop(&tx, 3 + len);
    }
}

// called every simulated millisecond
void host_esp_tick(uint32_t now)
{
    uint32_t ms = now > now_ms ? now - now_ms : 0;
    now_ms = now;
    for (int i = 1; i <= 4; i++) if (conns[i].used) gen(&conns[i], ms ? ms : 0);
    // move released answers onto the wire, at most uart_bpms bytes per ms
    size_t budget = (size_t)host_esp_uart_bpms * (ms ? ms : 1);
    while (answers && answers->at <= now_ms && budget)
    {
        ans_t *a = answers;
        size_t k = a->data.len < budget ? a->data.len : budget;
        bq_put(&uart_rx, a->data.b, k);
        bq_drop(&a->data, k);
        budget -= k;
        if (!a->data.len) { answers = a->next; free(a->data.b); free(a); }
    }
}

void host_esp_reset(void)
{
    for (int i = 1; i <= 4; i++) { free(conns[i].reqbuf.b); free(conns[i].out.b); free(conns[i].pend.b); memset(&conns[i], 0, sizeof conns[i]); }
    while (answers) { ans_t *a = answers; answers = a->next; free(a->data.b); free(a); }
    uart_rx.len = 0;
    tx.len = 0;
}

// a connection some earlier program left open in the ESP (survives an MSX reset)
void host_esp_leftover(bool tls)
{
    for (int i = 1; i <= 4; i++)
        if (!conns[i].used) { memset(&conns[i], 0, sizeof conns[i]); conns[i].used = true; conns[i].tls = tls; conns[i].ip[0] = 192; host_esp_opens++; return; }
}

int host_esp_open_conns(void)
{
    int n = 0;
    for (int i = 1; i <= 4; i++) n += conns[i].used;
    return n;
}

bool host_esp_owned(void) { return owned; }

// ---------------- HAL ----------------
bool pva_hal_net_present(void) { return host_esp_present; }

bool pva_hal_net_open(void)
{
    if (!host_esp_present) return false;
    owned = true;
    return true;
}

void pva_hal_net_close(void)
{
    owned = false;
    host_esp_rx_dropped += (uint32_t)uart_rx.len;
    uart_rx.len = 0;
}

size_t pva_hal_net_write(const uint8_t *p, size_t n)
{
    if (!owned) return 0;
    bq_put(&tx, p, n);
    parse_tx();
    return n;
}

size_t pva_hal_net_read(uint8_t *p, size_t n)
{
    if (!owned) return 0;
    if (n > uart_rx.len) n = uart_rx.len;
    memcpy(p, uart_rx.b, n);
    bq_drop(&uart_rx, n);
    return n;
}

static uint8_t stream_ram[128u * 1024u];
uint8_t *pva_hal_stream_ram(size_t *size)
{
    *size = host_stream_ram_size < sizeof stream_ram ? host_stream_ram_size : sizeof stream_ram;
    return *size ? stream_ram : NULL;
}
