/*
 * PicoPlay - music player for SymbOS on the MSX PicoVerse 2350
 *
 * The PicoVerse cartridge reads the music from its microSD card and decodes
 * it itself (PicoVerse Audio Engine, LoadROM -p1). This program only sends
 * short commands to the engine and shows its status block. It never waits
 * for the engine without giving the CPU back to SymbOS, and every wait has a
 * time limit, so a missing or stuck cartridge can not freeze the system.
 *
 * Build: cc pvplay.c pvwin.s -o PICOPLAY.EXE   (SymbOS C Compiler)
 */

#ifdef PV_HOST_TEST
#include "test/host_symbos.h"
#else
#include <symbos.h>
#endif
#include <string.h>
#include <stdio.h>
#include "pva_proto.h"

#define APP_VERSION "0.4"

/* ------------------------------------------------------------ engine access */
extern void pv_setslot(unsigned char prim, unsigned char sub);
extern unsigned char pv_peek(unsigned short addr);
extern void pv_poke(unsigned short addr, unsigned char value);
extern void pv_read(unsigned short addr, char *dst, unsigned short len);
extern void pv_write(unsigned short addr, char *src, unsigned short len);
extern void pv_post(unsigned char token, unsigned char code);
extern unsigned char pv_prim, pv_sub;

#define W(off) (PVA_WIN_BASE + (off))

_transfer char xbuf[PVA_REPLY_SIZE + 2];    /* copy buffer, must be in page 3 */
_transfer char stbuf[PVA_STATUS_SIZE];
char st[PVA_STATUS_SIZE];                   /* last consistent status block */
unsigned short reply_len;
unsigned char token;
unsigned char engine_ok;                    /* 0 = not found, 1 = ok, 2 = not answering */
unsigned char last_hb;
unsigned short hb_time;

#define ST16(o) ((unsigned short)(unsigned char)st[o] | ((unsigned short)(unsigned char)st[(o) + 1] << 8))

static unsigned char detect(void)
{
    static unsigned char prims[4] = { 1, 2, 0, 3 };
    static unsigned char subs[4] = { 3, 0, 1, 2 };
    unsigned char p, s;
    for (p = 0; p < 4; ++p) {
        for (s = 0; s < 4; ++s) {
            pv_setslot(prims[p], subs[s]);
            pv_read(W(PVA_R_ID), xbuf, 8);
            if (!memcmp(xbuf, "PVAUDIO", 8))
                return 1;
        }
    }
    return 0;
}

/* Send one command and wait (giving the CPU back) for its answer, 3 s at most.
 * Returns the engine result, or -1 when the engine did not answer. */
static int pv_cmd(unsigned char code, char *args, unsigned short alen)
{
    unsigned short t0;
    unsigned char r;
    if (engine_ok == 0)
        return -1;
    if (alen) {
        memcpy(xbuf, args, alen);
        pv_write(W(PVA_R_ARGS), xbuf, alen);
    }
    ++token;
    pv_post(token, code);
    t0 = Sys_Counter16();
    while (pv_peek(W(PVA_R_DONE_TOKEN)) != token) {
        if ((unsigned short)(Sys_Counter16() - t0) > 300) {
            engine_ok = 2;
            return -1;
        }
        Idle();
    }
    engine_ok = 1;
    r = pv_peek(W(PVA_R_RESULT));
    reply_len = pv_peek(W(PVA_R_REPLY_LEN)) | ((unsigned short)pv_peek(W(PVA_R_REPLY_LEN + 1)) << 8);
    if (reply_len > PVA_REPLY_SIZE)
        reply_len = PVA_REPLY_SIZE;
    if (reply_len)
        pv_read(W(PVA_R_REPLY), xbuf, reply_len);
    xbuf[reply_len] = 0;
    return r;
}

static int pv_cmd_u16(unsigned char code, unsigned short v)
{
    char a[2];
    a[0] = (char)v;
    a[1] = (char)(v >> 8);
    return pv_cmd(code, a, 2);
}

static int pv_cmd_u8(unsigned char code, unsigned char v)
{
    return pv_cmd(code, (char *)&v, 1);
}

static unsigned char read_status(void)
{
    unsigned char i, s1;
    for (i = 0; i < 5; ++i) {
        s1 = pv_peek(W(PVA_R_STATUS + PVA_ST_SEQ));
        pv_read(W(PVA_R_STATUS), stbuf, PVA_STATUS_SIZE);
        if ((unsigned char)stbuf[0] == s1 && !(s1 & 1)) {
            memcpy(st, stbuf, PVA_STATUS_SIZE);
            return 1;
        }
    }
    return 0;
}

#ifdef PV_HOST_TEST
#include "test/host_gui.h"
#else
#include "pvgui.h"
#endif

signed char win_id = -1;
signed char text_id = -1;
signed char eq_id = -1;
/* Saving right after a redraw of the equalizer window made SymbOS 4.0 drop
   the window (seen in openMSX): the settings are written a few ticks later. */
unsigned char eq_dirty;
static void eq_save(void);
signed char timer_id = -1;

/* Every way out must stop the wake timer first: it runs in our memory. */
static void eq_close(void);
static void app_quit(void)
{
    eq_close();                             /* saves the equalizer */
    if (timer_id >= 0)
        Timer_Delete(timer_id);
    timer_id = -1;
    exit(0);
}

/* ------------------------------------------------------------ helpers */
/* Redraw requests without waiting. SCC's Win_Redraw() spins until the
   desktop's message queue has room; when the desktop is busy (another window
   opening, the Task Manager) that spinning starves it and the desktop locks
   up. Here a request that does not fit is kept and sent on a later tick, and
   at most MAX_SENDS requests go out per tick. */
#define MAX_SENDS 3
_transfer char rmsg[14];
unsigned short redraw_pending;              /* one bit per control */
unsigned char status_pending, sends_left = MAX_SENDS;

static unsigned char desk_send(unsigned char cmd, unsigned char what)
{
#ifdef PV_HOST_TEST
    if (cmd == 34) Win_Redraw(win_id, (signed char)what, 0); else Win_Redraw_Status(win_id);
    return 1;
#else
    rmsg[0] = cmd;
    rmsg[1] = (char)win_id;
    rmsg[2] = (char)what;
    rmsg[3] = 0;
    return Msg_Send(_sympid, 2, rmsg) != 0;
#endif
}

static void redraw_status(void)
{
    if (win_id < 0)
        return;
    if (sends_left && desk_send(37, 0)) {
        --sends_left;
        status_pending = 0;
    } else
        status_pending = 1;
}

static void set_status(char *s)
{
    strncpy(txt_status, s, TXT_STATUS_SIZE - 1);
    txt_status[TXT_STATUS_SIZE - 1] = 0;
    redraw_status();
}

static void error_status(char *what, int r)
{
    char t[80];
    if (r < 0)
        sprintf(t, "%s: the engine does not answer", what);
    else if (r == PVA_E_NOCARD)
        sprintf(t, "%s: microSD not mounted (FRESULT %u)", what, (unsigned char)st[PVA_ST_MOUNT_FR]);
    else if (r == PVA_E_NOTFOUND)
        sprintf(t, "%s: not found", what);
    else if (r == PVA_E_FORMAT)
        sprintf(t, "%s: not a playable file", what);
    else if (r == PVA_E_IO)
        sprintf(t, "%s: read error (FRESULT %u)", what, (unsigned char)st[PVA_ST_FRESULT]);
    else if (r == PVA_E_NOWIFI)
        sprintf(t, "%s: no WiFi (ESP) in this firmware", what);
    else
        sprintf(t, "%s: error %d", what, r);
    set_status(t);
}

/* numbers without sprintf: SCC's printf formats through 32-bit division,
   which is slow on a Z80 */
static char *put_u(char *d, unsigned short v)
{
    char b[6];
    unsigned char n = 0;
    do {
        b[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        *d++ = b[--n];
    *d = 0;
    return d;
}

static char *put2(char *d, unsigned char v)
{
    *d++ = (char)('0' + v / 10);
    *d++ = (char)('0' + v % 10);
    *d = 0;
    return d;
}

static void fmt_time(char *d, unsigned short s)
{
    unsigned short m = s / 60;
    unsigned char sec = (unsigned char)(s % 60);
    if (m >= 60) {
        d = put_u(d, m / 60);
        *d++ = ':';
        m %= 60;
    }
    d = put2(d, (unsigned char)m);
    *d++ = ':';
    put2(d, sec);
}

static void redraw(unsigned char c)
{
    if (win_id < 0)
        return;
    if (sends_left && desk_send(34, c)) {
        --sends_left;
        redraw_pending &= (unsigned short)~(1U << c);
    } else
        redraw_pending |= (unsigned short)(1U << c);
}

/* start of a tick: a new budget, then what is still waiting */
static void flush_redraws(void)
{
    unsigned char c;
    sends_left = MAX_SENDS;
    if (status_pending)
        redraw_status();
    for (c = 0; c < C_COUNT && redraw_pending && sends_left; ++c)
        if (redraw_pending & (1U << c))
            redraw(c);
}

/* ------------------------------------------------------------ folder list */
static void fill_page(void)
{
    unsigned short idx, got, p;
    unsigned char r = 0, i, l, type;
    unsigned long size;
    char a[3];
    if (page_first > 0) {
        strcpy(row_name[r], "<< previous entries");
        row_info[r][0] = 0;
        row_entry[r] = -1;
        row_type[r] = 0;
        ++r;
    }
    idx = page_first;
    while (idx < dir_count && r < LIST_PAGE + (page_first > 0 ? 1 : 0)) {
        a[0] = (char)idx;
        a[1] = (char)(idx >> 8);
        a[2] = 30;
        if (pv_cmd(PVA_C_DIR_READ, a, 3) != PVA_OK || reply_len == 0)
            break;
        got = 0;
        for (p = 0; p + 6 <= reply_len && idx < dir_count && r < LIST_PAGE + (page_first > 0 ? 1 : 0); ) {
            type = (unsigned char)xbuf[p];
            size = (unsigned char)xbuf[p + 1] | ((unsigned long)(unsigned char)xbuf[p + 2] << 8) |
                   ((unsigned long)(unsigned char)xbuf[p + 3] << 16) | ((unsigned long)(unsigned char)xbuf[p + 4] << 24);
            l = (unsigned char)xbuf[p + 5];
            if (type == PVA_DE_DIR || type == PVA_DE_PARENT) {
                row_name[r][0] = '[';
                for (i = 0; i < l && i < NAME_LEN - 2; ++i)
                    row_name[r][i + 1] = xbuf[p + 6 + i];
                row_name[r][i + 1] = ']';
                row_name[r][i + 2] = 0;
                if (type == PVA_DE_PARENT)
                    strcpy(row_info[r], "up");
                else if (size && size < 65536UL)
                    put_u(row_info[r], (unsigned short)size);      /* a country: its stations */
                else
                    strcpy(row_info[r], "dir");
            } else {
                for (i = 0; i < l && i < NAME_LEN; ++i)
                    row_name[r][i] = xbuf[p + 6 + i];
                row_name[r][i] = 0;
                if (type == PVA_DE_M3U)
                    strcpy(row_info[r], "list");
                else if (type == PVA_DE_URL) {
                    /* a station: its bitrate */
                    if (size && size < 1000)
                        strcpy(put_u(row_info[r], (unsigned short)size), "k");
                    else
                        strcpy(row_info[r], "radio");
                }
                else if (size >= 10240000UL)
                    sprintf(row_info[r], "%luM", size >> 20);
                else
                    sprintf(row_info[r], "%luK", (size + 1023) >> 10);
            }
            row_entry[r] = (short)idx;
            row_type[r] = type;
            ++r;
            ++idx;
            ++got;
            p += 6 + l;
        }
        if (!got)
            break;
    }
    if (idx < dir_count) {
        strcpy(row_name[r], ">> more entries");
        row_info[r][0] = 0;
        row_entry[r] = -2;
        row_type[r] = 0;
        ++r;
    }
    for (i = 0; i < r; ++i) {
        rows[i].flags = i;
        rows[i].value1 = row_name[i];
        rows[i].value2 = row_info[i];
    }
    if (r)
        rows[0].flags |= ROW_MARKED;
    cd_list.lines = r;
    cd_list.scroll = 0;
    cd_list.clicked = 0;
    redraw(C_LIST);
}

/* keyboard selection: move the marked row and keep it in view */
#define LIST_VISIBLE 9
static void select_row(short n)
{
    unsigned short i;
    if (!cd_list.lines)
        return;
    if (n < 0)
        n = 0;
    if (n >= (short)cd_list.lines)
        n = cd_list.lines - 1;
    for (i = 0; i < cd_list.lines; ++i)
        rows[i].flags &= ~ROW_MARKED;
    rows[n].flags |= ROW_MARKED;
    cd_list.clicked = n;
    if (n < (short)cd_list.scroll)
        cd_list.scroll = n;
    else if (n >= (short)(cd_list.scroll + LIST_VISIBLE))
        cd_list.scroll = n - LIST_VISIBLE + 1;
    redraw(C_LIST);
}

static void show_folder_reply(void)
{
    dir_count = (unsigned char)xbuf[0] | ((unsigned short)(unsigned char)xbuf[1] << 8);
    strncpy(txt_path, xbuf + 2, TXT_PATH_SIZE - 1);
    txt_path[TXT_PATH_SIZE - 1] = 0;
    redraw(C_PATH);
    page_first = 0;
    fill_page();
}

static void open_folder(char *path)
{
    int r = pv_cmd(PVA_C_DIR_OPEN, path, strlen(path) + 1);
    if (r != PVA_OK) {
        error_status("Folder", r);
        return;
    }
    show_folder_reply();
}

/* a radio list being fetched (DIR_ENTER answered BUSY) */
static unsigned char dir_loading;
static short more_from = -1;        /* the "More stations..." entry that was opened */
static char *net_reason(unsigned char e);

static void check_dir_loading(void)
{
    unsigned char ds = pv_peek(W(PVA_R_STATUS + PVA_ST_DIR_STATE));
    char t[60];
    if (ds == PVA_DIRS_LOADING)
        return;
    dir_loading = 0;
    if (ds == PVA_DIRS_DONE) {
        open_folder("");
        if (more_from >= 0 && more_from < (short)dir_count) {
            /* the first new station, where "More stations..." was */
            page_first = (unsigned short)more_from / LIST_PAGE * LIST_PAGE;
            fill_page();
            select_row((short)(more_from - page_first + (page_first ? 1 : 0)));
        }
        more_from = -1;
        strcpy(put_u(t, dir_count ? dir_count - 1 : 0), dir_count == 2 ? " entry" : " entries");
        set_status(t);
    } else if (ds == PVA_DIRS_FAILED) {
        strcpy(t, "Station list: ");
        strcat(t, net_reason(pv_peek(W(PVA_R_STATUS + PVA_ST_DIR_ERR))));
        set_status(t);
    }
}

static void activate_row(unsigned short row)
{
    short e;
    int r;
    if (row >= cd_list.lines)
        return;
    e = row_entry[row];
    if (e == -1) {
        page_first = page_first > LIST_PAGE ? page_first - LIST_PAGE : 0;
        fill_page();
        return;
    }
    if (e == -2) {
        page_first += LIST_PAGE;
        fill_page();
        return;
    }
    if (row_type[row] == PVA_DE_DIR || row_type[row] == PVA_DE_PARENT) {
        r = pv_cmd_u16(PVA_C_DIR_ENTER, (unsigned short)e);
        if (r == PVA_E_BUSY) {
            /* a radio list is fetched: the tick opens it when it is there */
            dir_loading = 1;
            /* "More stations..." (the last row of a station list): show the new ones */
            more_from = (e + 1 == (short)dir_count && row_type[0] == PVA_DE_PARENT &&
                         !strncmp(txt_path, "/Internet radio/", 16)) ? e : -1;
            set_status("Loading the station list...");
        } else if (r != PVA_OK)
            error_status("Folder", r);
        else
            show_folder_reply();
        return;
    }
    set_status("Starting...");
    r = pv_cmd_u16(PVA_C_PLAY_INDEX, (unsigned short)e);
    if (r != PVA_OK)
        error_status("Play", r);
}

/* ------------------------------------------------------------ status display */
unsigned short shown_track = 0xFFFF, shown_elapsed = 0xFFFF, shown_total = 0xFFFF;
unsigned char shown_state = 0xFF, shown_prog = 0xFF, shown_mode = 0xFF, shown_vol = 0xFF;

/* copy 'src' into a control text and redraw it, only when it changed */
static void put_text(char *dst, unsigned short size, char *src, unsigned char ctl)
{
    if (!strncmp(dst, src, size - 1))
        return;
    strncpy(dst, src, size - 1);
    dst[size - 1] = 0;
    redraw(ctl);
}

static char *net_reason(unsigned char e)
{
    switch (e) {
    case PVA_NERR_NOWIFI:  return "WiFi not connected";
    case PVA_NERR_DNS:     return "host not found";
    case PVA_NERR_CONNECT: return "connection refused";
    case PVA_NERR_HTTP:    return "server error";
    case PVA_NERR_FORMAT:  return "not MP3 (AAC/Ogg/HLS)";
    case PVA_NERR_TIMEOUT: return "no answer";
    case PVA_NERR_CLOSED:  return "closed by the server";
    case PVA_NERR_URL:     return "bad address";
    }
    return "network error";
}

static unsigned char shown_err;
/* The engine counts a display generation: it changes only when something
   PicoPlay shows changed (not the VU levels or the uptime; the buffer level
   and the rate come in coarse steps). So a tick reads one byte, and only when
   it moved the whole block. The texts are rebuilt only when their own inputs
   changed: every sprintf and every redraw costs a Z80 a lot. */
static unsigned char shown_gen, force_update = 1, quiet_ticks;
static unsigned short key_fmt[4], key_st[6];

static unsigned char changed(unsigned short *key, unsigned short *now, unsigned char n)
{
    unsigned char i, c = 0;
    for (i = 0; i < n; ++i)
        if (key[i] != now[i]) {
            key[i] = now[i];
            c = 1;
        }
    return c;
}

static void update_display(void)
{
    char t[84], t2[12];
    unsigned short el, tot, kf[4], ks[6];
    unsigned char state, prog, flags, stream, bufp, g;
    unsigned short tid;

    g = pv_peek(W(PVA_R_STATUS + PVA_ST_DISP_GEN));
    if (!force_update && g == shown_gen && ++quiet_ticks < 25)
        return;                                 /* nothing new (a full look every 5 s anyway) */
    quiet_ticks = 0;
    if (!read_status())
        return;
    force_update = 0;
    shown_gen = (unsigned char)st[PVA_ST_DISP_GEN];
    state = (unsigned char)st[PVA_ST_STATE];
    flags = (unsigned char)st[PVA_ST_FLAGS];
    stream = (flags & PVA_F_STREAM) != 0;
    tid = ST16(PVA_ST_TRACK_ID);
    el = ST16(PVA_ST_ELAPSED);
    tot = ST16(PVA_ST_TOTAL);
    bufp = (unsigned char)st[PVA_ST_DISP_BUF];

    /* title, second line, format */
    if (state == PVA_STATE_STOPPED && st[PVA_ST_TITLE] == 0) {
        put_text(txt_title, TXT_TITLE_SIZE, "No track", C_TITLE);
        put_text(txt_artist, TXT_ARTIST_SIZE, "", C_ARTIST);
        put_text(txt_fmt, TXT_FMT_SIZE, "", C_FMT);
        key_fmt[0] = 0xFFFF;
    } else {
        put_text(txt_title, TXT_TITLE_SIZE, st + PVA_ST_TITLE, C_TITLE);
        t[0] = 0;
        if (st[PVA_ST_ARTIST]) {
            strcpy(t, st + PVA_ST_ARTIST);
            if (st[PVA_ST_ALBUM]) {
                strcat(t, " - ");
                strcat(t, st + PVA_ST_ALBUM);
            }
        } else if (stream && strcmp(st + PVA_ST_ALBUM, st + PVA_ST_TITLE))
            strcpy(t, st + PVA_ST_ALBUM);           /* the station under the stream title */
        put_text(txt_artist, TXT_ARTIST_SIZE, t, C_ARTIST);
        kf[0] = (unsigned short)(flags & (PVA_F_STREAM | PVA_F_BUFFERING)) | ((unsigned short)(unsigned char)st[PVA_ST_FORMAT] << 8);
        kf[1] = ST16(PVA_ST_BITRATE);
        kf[2] = ST16(PVA_ST_RATE) | ((unsigned short)(unsigned char)st[PVA_ST_CHANNELS] << 14);
        kf[3] = (flags & PVA_F_BUFFERING) ? bufp : 0;
        if (changed(key_fmt, kf, 4)) {
            if (stream && (flags & PVA_F_BUFFERING))
                sprintf(t, "Buffering %u%%", bufp);
            else if (stream)
                sprintf(t, "%uk %u.%ukHz", ST16(PVA_ST_BITRATE), ST16(PVA_ST_RATE) / 100,
                        (ST16(PVA_ST_RATE) / 10) % 10);
            else
                sprintf(t, "%s %uk %u.%ukHz%s", st[PVA_ST_FORMAT] == PVA_DE_WAV ? "WAV" : "MP3",
                        ST16(PVA_ST_BITRATE), ST16(PVA_ST_RATE) / 100, (ST16(PVA_ST_RATE) / 10) % 10,
                        st[PVA_ST_CHANNELS] == 1 ? " mono" : "");
            put_text(txt_fmt, TXT_FMT_SIZE, t, C_FMT);
        }
    }

    /* play button, status bar */
    if (state != shown_state) {
        strcpy(txt_play, state == PVA_STATE_PLAYING ? "Pause" : "Play");
        redraw(C_PLAY);
    }
    ks[0] = state | ((unsigned short)(unsigned char)st[PVA_ST_ERROR] << 8);
    ks[1] = ST16(PVA_ST_PL_POS);
    ks[2] = ST16(PVA_ST_PL_COUNT);
    ks[3] = stream ? ((unsigned short)(unsigned char)st[PVA_ST_NET_STATE] | ((unsigned short)(unsigned char)st[PVA_ST_NET_ERR] << 8)) : 0;
    ks[4] = stream ? ST16(PVA_ST_DISP_RATE) : 0;
    ks[5] = (stream ? ST16(PVA_ST_UNDERRUNS) : 0) ^ ST16(PVA_ST_HTTP);
    if (changed(key_st, ks, 6) || shown_state == 0xFF) {
        t[0] = 0;
        if (state == PVA_STATE_PLAYING) {
            sprintf(t, "Playing %u of %u", ST16(PVA_ST_PL_POS) + 1, ST16(PVA_ST_PL_COUNT));
            if (stream) {
                unsigned char ns = (unsigned char)st[PVA_ST_NET_STATE];
                unsigned short rate = ST16(PVA_ST_DISP_RATE);
                unsigned short need = (unsigned short)(ST16(PVA_ST_BITRATE) * 10U / 8U);   /* 0.1 KB/s */
                if (ns == PVA_NET_LOOKUP || ns == PVA_NET_CONNECT || ns == PVA_NET_REQUEST)
                    strcat(t, ns == PVA_NET_CONNECT ? " - connecting" : " - opening");
                else if (ns == PVA_NET_RETRY)
                    strcat(t, " - reconnecting");
                else if (ST16(PVA_ST_UNDERRUNS) && rate < need - need / 20U)
                    /* the link is slower than the stream (a far server): say so */
                    sprintf(t + strlen(t), " - too slow: %u.%u of %u.%u KB/s", rate / 10, rate % 10, need / 10, need % 10);
                else if (rate)
                    sprintf(t + strlen(t), " - %u.%u KB/s", rate / 10, rate % 10);
            }
        } else if (state == PVA_STATE_PAUSED)
            strcpy(t, "Paused");
        else if ((unsigned char)st[PVA_ST_ERROR] == PVA_E_NET) {
            sprintf(t, "Stream stopped: %s", net_reason((unsigned char)st[PVA_ST_NET_ERR]));
            if ((unsigned char)st[PVA_ST_NET_ERR] == PVA_NERR_HTTP)
                sprintf(t + strlen(t), " %u", ST16(PVA_ST_HTTP));
        } else if (shown_state != 0xFF && (shown_state != state || shown_err == PVA_E_NET))
            strcpy(t, "Stopped");
        shown_err = (unsigned char)st[PVA_ST_ERROR];
        if (t[0] && strcmp(t, txt_status))
            set_status(t);
    }

    /* time and progress (a stream shows its buffer fill) */
    if (el != shown_elapsed || tot != shown_total || tid != shown_track || stream) {
        if (state == PVA_STATE_STOPPED && st[PVA_ST_TITLE] == 0)
            strcpy(t, "--:-- / --:--");
        else {
            fmt_time(t, el);
            if (tot) {
                fmt_time(t2, tot);
                strcat(t, " / ");
                strcat(t, t2);
            }
        }
        put_text(txt_time, TXT_TIME_SIZE, t, C_TIME);
        if (stream)
            prog = (unsigned char)(((unsigned short)bufp * 255U) / 100U);
        else
            prog = tot ? (unsigned char)(((unsigned long)el * 255UL) / tot) : 0;
        if (prog != shown_prog) {
            ctl_prog.param = ((unsigned short)prog << 8) | PROG_COLORS;
            redraw(C_PROG);
            shown_prog = prog;
        }
    }
    if ((unsigned char)st[PVA_ST_MODE] != shown_mode) {
        shown_mode = (unsigned char)st[PVA_ST_MODE];
        chk_shuffle = (shown_mode & PVA_MODE_SHUFFLE) ? 1 : 0;
        chk_repeat = (shown_mode & PVA_MODE_REPEAT_ALL) ? 1 : 0;
        redraw(C_SHUF);
        redraw(C_REP);
    }
    if ((unsigned char)st[PVA_ST_VOLUME] != shown_vol) {
        shown_vol = (unsigned char)st[PVA_ST_VOLUME];
        cd_volume.value = shown_vol;
        redraw(C_VOL);
    }
    shown_track = tid;
    shown_state = state;
    shown_elapsed = el;
    shown_total = tot;
}

/* called 5 times per second */
/* A status redraw asked for right after Win_Open, before the desktop has
   drawn the window, is lost; repeat it on the first timer ticks. */
unsigned char status_redraws = 2;

static void engine_stopped(void);
/* The heartbeat stopped: say what the engine left in the window */
static void engine_stopped(void)
{
    char t[96], *d;
    unsigned char f = pv_peek(W(PVA_R_FAULT)), w = pv_peek(W(PVA_R_WHERE)), i;
    if (f) {
        strcpy(t, f == 1 ? "Engine crashed, PC " : "Engine stopped: ");
        d = t + strlen(t);
        if (f == 1) {
            for (i = 4; i--; ) {
                unsigned char b = pv_peek(W(PVA_R_FAULT_PC) + i);
                *d++ = "0123456789ABCDEF"[b >> 4];
                *d++ = "0123456789ABCDEF"[b & 15];
            }
            *d = 0;
        } else {
            for (i = 0; i < 40; ++i) {
                char c = (char)pv_peek(W(PVA_R_FAULT_TEXT) + i);
                if (!c || c == 10 || c == 13)
                    break;
                *d++ = c;
            }
            *d = 0;
        }
    } else {
        strcpy(t, "Engine stuck in ");
        strcat(t, w == PVA_W_LOOP ? "its loop" : w == PVA_W_COMMAND ? "a command" : w == PVA_W_STREAM ? "the stream" :
                  w == PVA_W_RADIO ? "the station list" : w == PVA_W_DECODE ? "decoding" : w == PVA_W_STATUS ? "the status" :
                  w == PVA_W_CARD ? "the microSD card" : "?");
        strcat(t, ", command ");
        d = t + strlen(t);
        i = pv_peek(W(PVA_R_LAST_CMD));
        d[0] = "0123456789ABCDEF"[i >> 4];
        d[1] = "0123456789ABCDEF"[i & 15];
        d[2] = 'h';
        d[3] = 0;
    }
    set_status(t);
}

static void tick(void)
{
    unsigned char hb;
    flush_redraws();
    if (status_redraws) {
        --status_redraws;
        redraw_status();
    }
    if (engine_ok == 0)
        return;
    hb = pv_peek(W(PVA_R_HEARTBEAT));
    if (hb != last_hb) {
        last_hb = hb;
        hb_time = Sys_Counter16();
        if (engine_ok == 2) {
            engine_ok = 1;
            set_status("Engine answering again");
        }
    } else if ((unsigned short)(Sys_Counter16() - hb_time) > 200) {
        if (engine_ok == 1)
            engine_stopped();
        engine_ok = 2;
        return;
    }
    if (dir_loading)
        check_dir_loading();
    if (eq_dirty && !--eq_dirty)
        eq_save();
    update_display();
}

/* ------------------------------------------------------------ text window */
static void show_text(char *title, char *text)
{
    unsigned char n = 0, c = 0;
    char *p = text;
    while (*p && n < TEXT_LINES) {
        if (*p == 13) {
            ++p;
            continue;
        }
        if (*p == 10 || c >= TEXT_LEN) {
            tline[n][c] = 0;
            ++n;
            c = 0;
            if (*p == 10)
                ++p;
            continue;
        }
        tline[n][c++] = *p++;
    }
    if (c && n < TEXT_LINES) {
        tline[n][c] = 0;
        ++n;
    }
    for (c = 0; c < n; ++c) {
        trows[c].flags = c;
        trows[c].value = tline[c];
    }
    cd_tlist.lines = n;
    cd_tlist.scroll = 0;
    strcpy(txt_twin, title);
    if (text_id >= 0) {
        Win_Redraw(text_id, -1, 0);
        Win_Redraw_Title(text_id);
        Win_Focus(text_id);
    } else
        text_id = Win_Open(_symbank, &win_text);
}

/* ------------------------------------------------------------ favourites */
/* RADIOFAV.M3U in the root of the card. PicoPlay writes it through SymbOS (so
   the file system stays SymbOS's alone); the engine only reads it for the
   Favourites folder. */
#define FAV_SIZE 4096
char favbuf[FAV_SIZE + 1];
char fav_path[20];
char fav_url[256];
char fav_name[64];

static unsigned short fav_load(void)
{
    unsigned char id = File_Open(_symbank, fav_path);
    unsigned short n;
    if (id > 7)
        return 0;
    n = File_Read(id, _symbank, favbuf, FAV_SIZE);
    File_Close(id);
    favbuf[n] = 0;
    return n;
}

static unsigned char fav_save(unsigned short n)
{
    unsigned char id = File_New(_symbank, fav_path, 0);
    unsigned short w;
    if (id > 7)
        return 0;
    w = n ? File_Write(id, _symbank, favbuf, n) : 0;
    File_Close(id);
    return w == n;
}

/* the line in favbuf equal to fav_url: its start, or 0 */
static char *fav_find(void)
{
    char *p = favbuf, *e;
    unsigned short l = strlen(fav_url);
    while (*p) {
        e = p;
        while (*e && *e != 13 && *e != 10)
            ++e;
        if ((unsigned short)(e - p) == l && !strncmp(p, fav_url, l))
            return p;
        while (*e == 13 || *e == 10)
            ++e;
        p = e;
    }
    return 0;
}

/* the station of the marked row (or the stream that plays) into fav_url/fav_name */
static unsigned char fav_info(void)
{
    unsigned short row = cd_list.clicked, idx = 0xFFFF;
    char *n;
    if (row < cd_list.lines && row_type[row] == PVA_DE_URL)
        idx = (unsigned short)row_entry[row];
    if (pv_cmd_u16(PVA_C_ENTRY_INFO, idx) != PVA_OK)
        return 0;
    strncpy(fav_url, xbuf, 255);
    fav_url[255] = 0;
    n = xbuf + strlen(xbuf) + 1;
    strncpy(fav_name, n, 63);
    fav_name[63] = 0;
    return 1;
}

static unsigned char in_favourites(void)
{
    return !strcmp(txt_path, "/Internet radio/Favourites");
}

static void fav_add(void)
{
    unsigned short n;
    char t[80];
    if (!fav_info()) {
        set_status("Favourites: select a station (or play one) first");
        return;
    }
    n = fav_load();
    if (fav_find()) {
        set_status("Already a favourite");
        return;
    }
    if (!n) {
        strcpy(favbuf, "#EXTM3U\r\n");
        n = strlen(favbuf);
    } else if (favbuf[n - 1] != 10 && favbuf[n - 1] != 13) {
        strcpy(favbuf + n, "\r\n");
        n += 2;
    }
    if (n + strlen(fav_name) + strlen(fav_url) + 16 > FAV_SIZE) {
        set_status("Favourites: the file is full (4 KB)");
        return;
    }
    strcpy(favbuf + n, "#EXTINF:-1,");
    strcat(favbuf + n, fav_name);
    strcat(favbuf + n, "\r\n");
    strcat(favbuf + n, fav_url);
    strcat(favbuf + n, "\r\n");
    n += strlen(favbuf + n);
    if (!fav_save(n)) {
        set_status("Favourites: cannot write RADIOFAV.M3U");
        return;
    }
    strcpy(t, "Added to favourites: ");
    strncat(t, fav_name[0] ? fav_name : fav_url, 50);
    set_status(t);
    if (in_favourites())
        open_folder("");
}

static void fav_del(void)
{
    unsigned short n, row = cd_list.clicked;
    char *p, *e, *s;
    if (!in_favourites() || row >= cd_list.lines || row_type[row] != PVA_DE_URL || !fav_info()) {
        set_status("Favourites: select a station in Internet radio/Favourites");
        return;
    }
    n = fav_load();
    p = fav_find();
    if (!p) {
        set_status("Not in RADIOFAV.M3U");
        return;
    }
    /* the address line, and the #EXTINF line just before it */
    e = p;
    while (*e && *e != 13 && *e != 10)
        ++e;
    while (*e == 13 || *e == 10)
        ++e;
    s = p;
    if (s > favbuf) {
        char *q = s - 1;
        while (q > favbuf && (*q == 13 || *q == 10))
            --q;
        while (q > favbuf && q[-1] != 13 && q[-1] != 10)
            --q;
        if (!strncmp(q, "#EXTINF", 7))
            s = q;
    }
    memmove(s, e, n - (unsigned short)(e - favbuf) + 1);
    n -= (unsigned short)(e - s);
    if (!fav_save(n)) {
        set_status("Favourites: cannot write RADIOFAV.M3U");
        return;
    }
    open_folder("");
    if (row >= cd_list.lines && cd_list.lines)
        row = cd_list.lines - 1;
    select_row((short)row);
    set_status("Removed from favourites");
}

/* ------------------------------------------------------------ equalizer */
/* The engine filters the sound (the DAC has no controls); PicoPlay keeps the
   settings in PICOPLAY.CFG next to RADIOFAV.M3U and sends them at start-up. */
signed char eq_gain[EQ_BANDS];
unsigned char balance = 50;             /* 0 left .. 50 centre .. 100 right */

unsigned char eq_preset;                /* 0..7, 8 = custom */
char cfg_path[20];
/* presets: gain + 'M' per band, 5 bands each (string data: SCC handles that safely) */
#define EQ_PRESETS 8
static char *eq_tab = "MMMMMROKPRLPQOLPNLOQPMLNPILQPKUQMMMSOMNR";
static char *eq_preset_name(unsigned char p)
{
    switch (p) {
    case 0: return "Flat";
    case 1: return "Rock";
    case 2: return "Pop";
    case 3: return "Jazz";
    case 4: return "Classic";
    case 5: return "Voice";
    case 6: return "Bass";
    case 7: return "Loudness";
    }
    return "Custom";
}

static Ctrl_Slider *eq_slider(unsigned char i)
{
    switch (i) {
    case 0: return &cd_eq0;
    case 1: return &cd_eq1;
    case 2: return &cd_eq2;
    case 3: return &cd_eq3;
    }
    return &cd_eq4;
}

static void eq_texts(void)
{
    unsigned char i;
    signed char g;
    char *d;
    for (i = 0; i < EQ_BANDS; ++i) {
        g = eq_gain[i];
        eq_slider(i)->value = (unsigned short)(12 - g);
        d = eq_val[i];
        if (g > 0)
            *d++ = '+';
        else if (g < 0) {
            *d++ = '-';
            g = (signed char)-g;
        }
        put_u(d, (unsigned short)g);
    }
    strcpy(txt_preset, "Preset: ");
    strcat(txt_preset, eq_preset_name(eq_preset));
    /* balance: "Centre", "L 40" (left louder) or "R 40" */
    cd_bal.value = balance;
    if (balance == 50)
        strcpy(txt_bal, "Centre");
    else {
        txt_bal[0] = balance < 50 ? 'L' : 'R';
        txt_bal[1] = ' ';
        put_u(txt_bal + 2, balance < 50 ? 50 - balance : balance - 50);
    }
}

/* an older engine does not know the command: say so instead of nothing happening */
static void sound_result(int r, char *what)
{
    char t[72];
    if (r != PVA_E_UNKNOWN)
        return;
    strcpy(t, what);
    strcat(t, " needs a newer engine: flash the new UF2");
    set_status(t);
}

static void eq_send(void)
{
    sound_result(pv_cmd(PVA_C_EQ, (char *)eq_gain, EQ_BANDS), "Equalizer");
    sound_result(pv_cmd_u8(PVA_C_BALANCE, balance), "Balance");
}

static void eq_save(void)
{
    char t[48], *d;
    unsigned char i, id;
    signed char g;
    strcpy(t, "EQ=");
    strcat(t, eq_preset_name(eq_preset));
    d = t + strlen(t);
    for (i = 0; i < EQ_BANDS; ++i) {
        *d++ = ',';
        g = eq_gain[i];
        if (g < 0) {
            *d++ = '-';
            g = (signed char)-g;
        }
        d = put_u(d, (unsigned short)g);
    }
    strcpy(d, "\r\nBAL=");
    d = put_u(d + 6, balance);
    strcpy(d, "\r\n");
    id = File_New(_symbank, cfg_path, 0);
    if (id > 7)
        return;
    File_Write(id, _symbank, t, strlen(t));
    File_Close(id);
}

/* "EQ=<preset>,g,g,g,g,g" from PICOPLAY.CFG */
static void eq_load(void)
{
    char t[64], *p;
    unsigned char id = File_Open(_symbank, cfg_path), i;
    unsigned short n;
    signed char neg, v;
    if (id > 7)
        return;
    n = File_Read(id, _symbank, t, 63);
    File_Close(id);
    t[n] = 0;
    if (strncmp(t, "EQ=", 3))
        return;
    p = strstr(t, "BAL=");
    if (p) {
        n = 0;
        for (p += 4; *p >= '0' && *p <= '9'; ++p)
            n = n * 10 + (*p - '0');
        balance = n > 100 ? 100 : (unsigned char)n;
    }
    p = t + 3;
    eq_preset = EQ_PRESETS;
    for (i = 0; i < EQ_PRESETS; ++i)
        if (!strncmp(p, eq_preset_name(i), strlen(eq_preset_name(i))) && p[strlen(eq_preset_name(i))] == ',')
            eq_preset = i;
    for (i = 0; i < EQ_BANDS; ++i) {
        while (*p && *p != ',')
            ++p;
        if (!*p)
            return;
        ++p;
        neg = 0;
        if (*p == '-') {
            neg = 1;
            ++p;
        }
        v = 0;
        while (*p >= '0' && *p <= '9')
            v = (signed char)(v * 10 + (*p++ - '0'));
        if (v > 12)
            v = 12;
        eq_gain[i] = neg ? (signed char)-v : v;
    }
}

static void eq_open(void)
{
    eq_texts();
    if (eq_id >= 0) {
        Win_Focus(eq_id);
        return;
    }
    eq_id = Win_Open(_symbank, &win_eq);
}

static void eq_close(void)
{
    if (eq_id < 0)
        return;
    Win_Close(eq_id);
    eq_id = -1;
    if (eq_dirty) {
        eq_dirty = 0;
        eq_save();
    }
}

static void eq_set_preset(unsigned char p)
{
    unsigned char i;
    eq_preset = p;
    for (i = 0; i < EQ_BANDS; ++i)
        eq_gain[i] = (signed char)(eq_tab[p * EQ_BANDS + i] - 'M');
    eq_send();
    eq_texts();
    if (eq_id >= 0)
        Win_Redraw(eq_id, -1, 0);
    eq_dirty = 15;                          /* saved 3 s later (see tick) */
}

static void eq_click(unsigned char ctrl)
{
    unsigned char i;
    if (ctrl >= E_P0 && ctrl <= E_P7) {
        eq_set_preset((unsigned char)(ctrl - E_P0));
        return;
    }
    if (ctrl == E_BAL) {
        if (cd_bal.value > 100)
            cd_bal.value = 100;
        /* snap to the centre near it, so "Centre" is easy to find */
        balance = (cd_bal.value > 46 && cd_bal.value < 54) ? 50 : (unsigned char)cd_bal.value;
        sound_result(pv_cmd_u8(PVA_C_BALANCE, balance), "Balance");
        eq_texts();
        eq_dirty = 15;
        Win_Redraw(eq_id, E_BAL, 0);
        Win_Redraw(eq_id, E_BALV, 0);
        return;
    }
    if (ctrl < E_S0 || ctrl > E_S4)
        return;
    i = (unsigned char)(ctrl - E_S0);
    if (eq_slider(i)->value > EQ_RANGE)
        eq_slider(i)->value = EQ_RANGE;
    eq_gain[i] = (signed char)(12 - (signed char)eq_slider(i)->value);
    eq_preset = EQ_PRESETS;
    eq_send();
    eq_texts();
    eq_dirty = 15;
    Win_Redraw(eq_id, (signed char)(E_V0 + i), 0);
    Win_Redraw(eq_id, E_NAME, 0);
}

static void menu_action(unsigned short v)
{
    int r;
    switch (v) {
    case M_REFRESH:
        open_folder("");
        break;
    case M_REMOUNT:
        r = pv_cmd(PVA_C_MOUNT, 0, 0);
        if (r == PVA_OK) {
            set_status("microSD mounted");
            open_folder("/");
        } else
            error_status("Mount", r);
        break;
    case M_DIAG:
        r = pv_cmd(PVA_C_DIAG, 0, 0);
        if (r == PVA_OK)
            show_text("Diagnostics", xbuf);
        else
            error_status("Diagnostics", r);
        break;
    case M_LOG:
        r = pv_cmd(PVA_C_LOG, 0, 0);
        if (r == PVA_OK)
            show_text("Engine log", xbuf);
        else
            error_status("Log", r);
        break;
    case M_ABOUT:
        /* Not MsgBox: it blocks this loop until the box is closed, while the
           wake timer keeps posting messages; on SymbOS 4.0 that stalls the
           desktop (half-drawn box, frozen mouse and keys). */
        show_text("About PicoPlay",
                  "PicoPlay " APP_VERSION " for SymbOS\n"
                  "Music player for the MSX PicoVerse 2350\n"
                  "The cartridge decodes and plays, SymbOS stays free.\n"
                  "\n"
                  "Up/Down select, Left/Right page, Enter open/play\n"
                  "Backspace parent folder\n"
                  "Space play/pause, N next, P previous, S stop\n"
                  "+/- volume, D diagnostics, L engine log\n"
                  "F add to favourites, Del remove (Internet radio)\n"
                  "E equalizer (5 bands; keys 1-8 pick a preset)");
        break;
    case M_FAV_ADD:
        fav_add();
        break;
    case M_EQ:
        eq_open();
        break;
    case M_FAV_DEL:
        fav_del();
        break;
    case M_QUIT:
        app_quit();
    }
}

static void control_click(unsigned char ctrl, unsigned char sub, unsigned short mx)
{
    int r = PVA_OK;
    unsigned short tot, sec;
    unsigned char m;
    switch (ctrl) {
    case C_PLAY:
        if (shown_state == PVA_STATE_STOPPED && cd_list.lines && ST16(PVA_ST_PL_COUNT) == 0) {
            activate_row(cd_list.clicked);
            return;
        }
        r = pv_cmd(PVA_C_PAUSE, 0, 0);
        break;
    case C_STOP: r = pv_cmd(PVA_C_STOP, 0, 0); break;
    case C_NEXT: r = pv_cmd(PVA_C_NEXT, 0, 0); break;
    case C_PREV: r = pv_cmd(PVA_C_PREV, 0, 0); break;
    case C_SHUF:
    case C_REP:
        m = (chk_shuffle ? PVA_MODE_SHUFFLE : 0) | (chk_repeat ? PVA_MODE_REPEAT_ALL : 0);
        r = pv_cmd_u8(PVA_C_MODE, m);
        break;
    case C_VOL:
        r = pv_cmd_u8(PVA_C_VOLUME, (unsigned char)cd_volume.value);
        break;
    case C_PROG:
        tot = ST16(PVA_ST_TOTAL);
        if (tot && (st[PVA_ST_FLAGS] & PVA_F_SEEKABLE) && mx >= PROG_X) {
            sec = (unsigned short)(((unsigned long)(mx - PROG_X) * tot) / PROG_W);
            r = pv_cmd_u16(PVA_C_SEEK, sec);
        }
        break;
    case C_LIST:
        if (sub == DSK_SUB_MDCLICK)
            activate_row(cd_list.clicked);
        return;
    default:
        return;
    }
    if (r != PVA_OK && r != PVA_E_STATE)
        error_status("Command", r);
    tick();
}

static void key_press(unsigned char k)
{
    switch (k) {
    case ' ': control_click(C_PLAY, 0, 0); break;
    case 'n': case 'N': control_click(C_NEXT, 0, 0); break;
    case 'p': case 'P': control_click(C_PREV, 0, 0); break;
    case 's': case 'S': control_click(C_STOP, 0, 0); break;
    case 13: activate_row(cd_list.clicked); break;
    case KEY_UP: select_row((short)cd_list.clicked - 1); break;
    case KEY_DOWN: select_row((short)cd_list.clicked + 1); break;
    case KEY_LEFT: select_row((short)cd_list.clicked - LIST_VISIBLE); break;
    case KEY_RIGHT: select_row((short)cd_list.clicked + LIST_VISIBLE); break;
    case 'd': case 'D': menu_action(M_DIAG); break;
    case 'a': case 'A': menu_action(M_ABOUT); break;
    case 'l': case 'L': menu_action(M_LOG); break;
    case 'f': case 'F': fav_add(); break;
    case 'e': case 'E': eq_open(); break;
    case 127: fav_del(); break;                 /* Del */
    case 8:                                     /* backspace: parent folder */
        if (cd_list.lines && row_type[0] == PVA_DE_PARENT)
            activate_row(0);
        break;
    case '+':
        cd_volume.value = cd_volume.value <= 95 ? cd_volume.value + 5 : 100;
        control_click(C_VOL, 0, 0);
        break;
    case '-':
        cd_volume.value = cd_volume.value >= 5 ? cd_volume.value - 5 : 0;
        control_click(C_VOL, 0, 0);
        break;
    }
}

/* ------------------------------------------------------------ main */
int main(int argc, char *argv[])
{
    unsigned char wid;
    char t[80];
    int r;

    gui_texts_init();
    /* the favourites live on the drive PicoPlay was started from (the card) */
    fav_path[0] = (argc > 0 && argv[0][0] && argv[0][1] == ':') ? argv[0][0] : 'A';
    strcpy(fav_path + 1, ":\\RADIOFAV.M3U");
    cfg_path[0] = fav_path[0];
    strcpy(cfg_path + 1, ":\\PICOPLAY.CFG");
    eq_load();
    win_id = Win_Open(_symbank, &win_main);
    if (win_id < 0)
        return 1;

    engine_ok = detect();
    if (!engine_ok) {
        set_status("PicoVerse Audio Engine not found");
        MsgBox("The PicoVerse Audio Engine was not found.",
               "Flash a LoadROM image built with -p1 (or -p1 -w)",
               "and start SymbOS again.", COLOR_BLACK, BUTTON_OK | TITLE_ERROR, 0, 0, &win_main);
    } else {
        token = pv_peek(W(PVA_R_DONE_TOKEN));
        last_hb = pv_peek(W(PVA_R_HEARTBEAT));
        hb_time = Sys_Counter16();
        r = pv_cmd(PVA_C_PING, 0, 0);
        if (r == PVA_OK) {
            sprintf(t, "%s in slot %u-%u", xbuf, pv_prim, pv_sub);
            set_status(t);
            read_status();
            eq_send();                          /* the saved equalizer */
            open_folder("");
        } else
            if (r < 0) engine_stopped(); else error_status("Engine", r);
    }

    timer_id = Timer_Wake(_sympid, 200, 10);

    while (1) {
        _symmsg[0] = 0;
        Msg_Sleep(_sympid, -1, _symmsg);
        if ((unsigned char)_symmsg[0] == 200) {
            tick();
            continue;
        }
        if ((unsigned char)_symmsg[0] != MSR_DSK_WCLICK)
            continue;
        wid = (unsigned char)_symmsg[1];
        if (eq_id >= 0 && wid == (unsigned char)eq_id) {
            if (_symmsg[2] == DSK_ACT_CLOSE || (_symmsg[2] == DSK_ACT_KEY && (unsigned char)_symmsg[4] == KEY_ESC))
                eq_close();
            else if (_symmsg[2] == DSK_ACT_CONTENT)
                eq_click((unsigned char)_symmsg[8]);
            else if (_symmsg[2] == DSK_ACT_KEY && _symmsg[4] >= '1' && _symmsg[4] <= '8')
                eq_set_preset((unsigned char)(_symmsg[4] - '1'));   /* 1..8: the presets */
            else if (_symmsg[2] == DSK_ACT_KEY)
                key_press((unsigned char)_symmsg[4]);
            continue;
        }
        if (text_id >= 0 && wid == (unsigned char)text_id) {
            if (_symmsg[2] == DSK_ACT_CLOSE || (_symmsg[2] == DSK_ACT_CONTENT && _symmsg[8] == 2) ||
                (_symmsg[2] == DSK_ACT_KEY && (unsigned char)_symmsg[4] == KEY_ESC)) {
                Win_Close(text_id);
                text_id = -1;
            } else if (_symmsg[2] == DSK_ACT_KEY)
                key_press((unsigned char)_symmsg[4]);   /* player keys work here too */
            continue;
        }
        switch (_symmsg[2]) {
        case DSK_ACT_CLOSE:
            app_quit();
        case DSK_ACT_MENU:
            menu_action(*(unsigned short *)&_symmsg[8]);
            break;
        case DSK_ACT_CONTENT:
            control_click((unsigned char)_symmsg[8], (unsigned char)_symmsg[3], *(unsigned short *)&_symmsg[4]);
            break;
        case DSK_ACT_KEY:
            key_press((unsigned char)_symmsg[4]);
            break;
        }
    }
}
