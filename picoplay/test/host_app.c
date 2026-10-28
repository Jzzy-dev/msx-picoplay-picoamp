// PC test of PicoPlay's logic (pvplay.c) against the real PicoVerse Audio
// Engine (host build). The SymbOS desktop is replaced by stubs; the engine is
// in "slot 1-3" behind pv_peek/pv_read/... as on the cartridge. A script feeds
// the main loop timer ticks, clicks, double-clicks, keys and menu choices.
//
// What this does NOT test: drawing, the SymbOS loader, the slot helper (see
// pvwin.s), real multitasking. Those need SymbOS itself.

#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <setjmp.h>
#include <stdbool.h>
#include "host_symbos.h"
extern Window win_text, win_eq;

void pva_init(uint8_t *arena, size_t arena_size);
uint8_t pva_mem_read(uint16_t addr);
void pva_mem_write(uint16_t addr, uint8_t data);
void pva_core1_init(void);
bool pva_core1_poll(void);
int  host_disk_open(const char *path, uint32_t create_sectors);
void host_advance_ms(uint32_t ms);
uint32_t pva_hal_millis(void);
extern bool host_audio_unlimited;
extern uint32_t host_audio_underruns, host_audio_frames;
extern bool host_esp_api_all_down;
static void key_press(unsigned char k);
extern uint32_t host_esp_clicks;

// SymbOS files: "A:\\X" is "0:/X" on the engine's card image (FatFS)
#include "ff.h"
static FIL host_files[8];
static bool host_file_used[8];
static unsigned char host_fopen(char *path, BYTE mode)
{
    char p[300];
    if (path[1] != ':') return 255;
    snprintf(p, sizeof p, "0:%s", path + 2);
    for (char *q = p; *q; q++) if (*q == '\\') *q = '/';
    for (int i = 0; i < 8; i++)
        if (!host_file_used[i])
        {
            if (f_open(&host_files[i], p, mode) != FR_OK) return 255;
            host_file_used[i] = true;
            return (unsigned char)i;
        }
    return 255;
}
unsigned char File_Open(unsigned char bank, char *path) { return host_fopen(path, FA_READ | FA_WRITE); }
unsigned char File_New(unsigned char bank, char *path, unsigned char attrib) { return host_fopen(path, FA_READ | FA_WRITE | FA_CREATE_ALWAYS); }
unsigned char File_Close(unsigned char id) { if (id < 8 && host_file_used[id]) { f_close(&host_files[id]); host_file_used[id] = false; } return 0; }
unsigned short File_Read(unsigned char id, unsigned char bank, char *addr, unsigned short len)
{ UINT br = 0; if (id < 8 && host_file_used[id]) f_read(&host_files[id], addr, len, &br); return (unsigned short)br; }
unsigned short File_Write(unsigned char id, unsigned char bank, char *addr, unsigned short len)
{ UINT bw = 0; if (id < 8 && host_file_used[id]) f_write(&host_files[id], addr, len, &bw); return (unsigned short)bw; }

char _symmsg[14];
unsigned char _sympid = 5, _symbank = 1;
unsigned char pv_prim, pv_sub;

static int engine_present = 1, engine_frozen = 0;
static int stream_phase;
static const char *stream_src;
int host_esp_load_audio(const char *mp3_path);
static unsigned long accesses, msgboxes, redraws[32], idles;
static void eng_ms(unsigned n)
{
    while (n--) { if (!engine_frozen) pva_core1_poll(); host_advance_ms(1); }
}
static int here(void) { return engine_present && pv_prim == 1 && pv_sub == 3; }
static void acc(void) { if (++accesses % 100 == 0) eng_ms(1); }

void pv_setslot(unsigned char p, unsigned char s) { pv_prim = p; pv_sub = s; }
unsigned char pv_peek(unsigned short a) { acc(); return here() ? pva_mem_read(a) : 0xFF; }
void pv_poke(unsigned short a, unsigned char v) { acc(); if (here()) pva_mem_write(a, v); }
void pv_read(unsigned short a, char *d, unsigned short n) { for (unsigned i = 0; i < n; i++) d[i] = (char)pv_peek((unsigned short)(a + i)); }
void pv_write(unsigned short a, char *s, unsigned short n) { for (unsigned i = 0; i < n; i++) pv_poke((unsigned short)(a + i), (unsigned char)s[i]); }
void pv_post(unsigned char t, unsigned char c) { pv_poke(0x4010, t); pv_poke(0x4011, c); }

signed char Win_Open(unsigned char b, void *a) { (void)b; return a == &win_text ? 2 : a == &win_eq ? 3 : 1; }
void Win_Redraw(unsigned char w, signed char what, unsigned char f) { (void)f; if (w == 1 && what >= 0 && what < 32) redraws[what]++; }
void Win_Redraw_Status(unsigned char w) { (void)w; }
void Win_Redraw_Title(unsigned char w) { (void)w; }
void Win_Focus(unsigned char w) { (void)w; }
void Win_Close(unsigned char w) { (void)w; }
unsigned char MsgBox(char *l1, char *l2, char *l3, unsigned int pen, unsigned char type, char *i4, char *i16, void *m)
{
    (void)pen; (void)type; (void)i4; (void)i16; (void)m;
    printf("    [MsgBox] %s / %s / %s\n", l1, l2 ? l2 : "", l3 ? l3 : "");
    msgboxes++;
    return 2;
}
signed char Timer_Wake(unsigned char pid, unsigned char id, unsigned short c) { (void)pid; (void)id; (void)c; return 3; }
void Timer_Delete(unsigned char id) { (void)id; }
void Idle(void) { idles++; eng_ms(20); }
unsigned short Sys_Counter16(void) { return (unsigned short)(pva_hal_millis() / 10u * 1u); }

static jmp_buf done;
void host_exit(int code) { (void)code; longjmp(done, 1); }

#include "../pvplay.c"
#undef main

// ------------------------------------------------------------------ script
static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("  FAIL %d: ", __LINE__); } else printf("  ok: "); printf(__VA_ARGS__); printf("\n"); } while (0)

static int step;
static int find_row(const char *name)
{
    for (int i = 0; i < cd_list.lines; i++) if (!strcmp(row_name[i], name)) return i;
    return -1;
}
static void ev_tick(void) { eng_ms(200); _symmsg[0] = (char)200; }
static void ev_click(unsigned char ctrl, unsigned char sub, unsigned short x)
{
    _symmsg[0] = (char)MSR_DSK_WCLICK; _symmsg[1] = 1; _symmsg[2] = DSK_ACT_CONTENT;
    _symmsg[3] = (char)sub; _symmsg[4] = (char)x; _symmsg[5] = (char)(x >> 8); _symmsg[8] = (char)ctrl;
}
static void ev_dclick_row(const char *name)
{
    int r = find_row(name);
    if (r < 0) { printf("  (row '%s' not found)\n", name); r = 0; }
    cd_list.clicked = (unsigned short)r;
    ev_click(C_LIST, DSK_SUB_MDCLICK, 0);
}
static void ev_menu(unsigned short v)
{
    _symmsg[0] = (char)MSR_DSK_WCLICK; _symmsg[1] = 1; _symmsg[2] = DSK_ACT_MENU;
    _symmsg[8] = (char)v; _symmsg[9] = (char)(v >> 8);
}
static void ev_close(void) { _symmsg[0] = (char)MSR_DSK_WCLICK; _symmsg[1] = 1; _symmsg[2] = DSK_ACT_CLOSE; }

static int ticks_left;
static void dump_rows(int max)
{
    for (int i = 0; i < cd_list.lines && i < max; i++) printf("    %-42s %s\n", row_name[i], row_info[i]);
}

static int scenario;     // 0 = normal, 1 = no engine

unsigned short Msg_Sleep(char rec, char send, char *msg)
{
    (void)rec; (void)send; (void)msg;
    if (ticks_left > 0) { ticks_left--; ev_tick(); return 1; }
    if (scenario == 1)
    {
        switch (step++)
        {
            case 0:
                CHECK(engine_ok == 0 && msgboxes == 1, "no engine: message box shown, status '%s'", txt_status);
                ticks_left = 10;
                return 0;
            case 1:
                CHECK(1, "timer ticks without an engine do nothing (no hang)");
                ev_click(C_PLAY, 0, 0);
                return 1;
            case 2:
                CHECK(1, "Play without an engine returns at once");
                ev_close();
                return 1;
        }
        return 0;
    }
    switch (step++)
    {
        case 0:
            printf("[start-up]\n");
            CHECK(engine_ok == 1 && pv_prim == 1 && pv_sub == 3, "engine found in slot %u-%u, status '%s'", pv_prim, pv_sub, txt_status);
            CHECK(!strcmp(txt_path, "/") && cd_list.lines == 2 && !strcmp(row_name[0], "[Internet radio]") && !strcmp(row_name[1], "[MUSIC]"),
                  "root listed: %s, %s", row_name[0], row_name[1]);
            ev_dclick_row("[MUSIC]");
            return 1;
        case 1:
            CHECK(!strcmp(txt_path, "/MUSIC"), "double-click opened '%s'", txt_path);
            dump_rows(10);
            CHECK(find_row("[..]") == 0 && find_row("[Cafe]") == 1 && find_row("[Many]") == 2 && find_row("long.mp3") > 0, "folders first, '..' on top");
            ev_dclick_row("[Many]");
            return 1;
        case 2:
            printf("[paging a folder with 300 tracks]\n");
            CHECK(dir_count == 301 && cd_list.lines == LIST_PAGE + 1 && !strcmp(row_name[LIST_PAGE], ">> more entries"),
                  "first page: %u rows of %u entries, last '%s'", cd_list.lines, dir_count, row_name[cd_list.lines - 1]);
            CHECK(!strcmp(row_name[1], "Track_000.mp3") && !strcmp(row_info[1], "32K"), "'%s' %s", row_name[1], row_info[1]);
            ev_dclick_row(">> more entries");
            return 1;
        case 3:
            CHECK(!strcmp(row_name[0], "<< previous entries") && row_entry[1] == LIST_PAGE && !strcmp(row_name[cd_list.lines - 1], ">> more entries"),
                  "second page starts at entry %d ('%s')", row_entry[1], row_name[1]);
            ev_dclick_row(">> more entries");
            return 1;
        case 4:
            CHECK(row_entry[cd_list.lines - 1] == 300 && strcmp(row_name[cd_list.lines - 1], ">> more entries"),
                  "last page ends with entry 300 '%s'", row_name[cd_list.lines - 1]);
            ev_dclick_row("<< previous entries");
            return 1;
        case 5:
            CHECK(row_entry[1] == LIST_PAGE, "back to the second page");
            ev_menu(M_REFRESH);
            return 1;
        case 6:
            CHECK(cd_list.lines == LIST_PAGE + 1 && row_entry[0] == 0, "Refresh reopens the folder at the top");
            cd_list.clicked = 0;
            ev_dclick_row("[..]");
            return 1;
        case 7:
            ev_dclick_row("[Cafe]");
            return 1;
        case 8:
            printf("[playing]\n");
            CHECK(!strcmp(txt_path, "/MUSIC/Cafe") && find_row("01 Sine.mp3") == 1, "in /MUSIC/Cafe");
            ev_dclick_row("01 Sine.mp3");
            ticks_left = 15;                        // 3 s
            return 1;
        case 9:
            CHECK(!strcmp(txt_title, "Sine Cafe Song") && !strcmp(txt_artist, "Unit Tester - PicoVerse Tests"), "title '%s', artist '%s'", txt_title, txt_artist);
            CHECK(!strcmp(txt_play, "Pause") && !strncmp(txt_status, "Playing 1 of 2", 14), "button '%s', status '%s'", txt_play, txt_status);
            CHECK(!strncmp(txt_time, "00:0", 4) && strstr(txt_time, "/ 00:20"), "time '%s', format '%s'", txt_time, txt_fmt);
            CHECK((ctl_prog.param >> 8) > 0 && (ctl_prog.param >> 8) < 80, "progress bar %lu/255", (unsigned long)(ctl_prog.param >> 8));
            ev_click(C_PROG, DSK_SUB_MLCLICK, PROG_X + PROG_W / 2);
            ticks_left = 2;
            return 1;
        case 10:
            CHECK(!strncmp(txt_time, "00:10", 5) || !strncmp(txt_time, "00:11", 5), "click in the middle of the bar seeks: '%s'", txt_time);
            ev_click(C_PLAY, 0, 0);                 // pause
            ticks_left = 5;
            return 1;
        case 11:
            CHECK(!strcmp(txt_play, "Play") && !strcmp(txt_status, "Paused"), "paused: button '%s'", txt_play);
            _symmsg[0] = (char)MSR_DSK_WCLICK; _symmsg[1] = 1; _symmsg[2] = DSK_ACT_KEY; _symmsg[4] = ' ';
            ticks_left = 2;
            return 1;
        case 12:
            CHECK(!strcmp(txt_play, "Pause"), "space resumes");
            ev_click(C_NEXT, 0, 0);
            ticks_left = 2;
            return 1;
        case 13:
            CHECK(!strcmp(txt_title, "VBR Four") && !strncmp(txt_status, "Playing 2 of 2", 14), "Next: '%s' (%s)", txt_title, txt_fmt);
            cd_volume.value = 30;
            ev_click(C_VOL, 0, 0);
            ticks_left = 1;
            return 1;
        case 14:
            CHECK((unsigned char)st[PVA_ST_VOLUME] == 30, "volume slider -> engine volume %u", (unsigned char)st[PVA_ST_VOLUME]);
            chk_shuffle = 1; chk_repeat = 1;
            ev_click(C_SHUF, 0, 0);
            ticks_left = 1;
            return 1;
        case 15:
            CHECK((unsigned char)st[PVA_ST_MODE] == (PVA_MODE_SHUFFLE | PVA_MODE_REPEAT_ALL), "shuffle + repeat sent, mode %u", (unsigned char)st[PVA_ST_MODE]);
            ev_menu(M_DIAG);
            return 1;
        case 16:
            CHECK(cd_tlist.lines > 5 && !strncmp(tline[0], "PicoVerse Audio Engine", 22), "Diagnostics window: %u lines, '%s'", cd_tlist.lines, tline[0]);
            for (int i = 0; i < cd_tlist.lines; i++) printf("    | %s\n", tline[i]);
            ev_menu(M_LOG);
            return 1;
        case 17:
            if (stream_phase == 0) {
                CHECK(cd_tlist.lines >= 3, "Engine log window: %u lines", cd_tlist.lines);
                if (stream_src) {
                    printf("[internet radio stream]\n");
                    static char u[] = "http://radio.test/stream.mp3\0";
                    CHECK(pv_cmd(PVA_C_PLAY_URL, u, sizeof u) == PVA_OK, "PLAY_URL");
                    stream_phase = 1;
                    ticks_left = 2;
                    step--;                         // come back to this step
                    return 0;
                }
            } else if (stream_phase == 1) {
                CHECK(!strncmp(txt_fmt, "Buffering", 9) || strstr(txt_status, "opening") || strstr(txt_status, "connecting"),
                      "while connecting: '%s' / '%s'", txt_fmt, txt_status);
                stream_phase = 2;
                ticks_left = 25;                    // 5 s
                step--;
                return 0;
            } else if (stream_phase == 2) {
                CHECK(!strcmp(txt_title, "Song A") || !strcmp(txt_title, "Song B"), "stream title '%s'", txt_title);
                CHECK(strstr(txt_artist, " - Test FM") != NULL, "artist - station '%s'", txt_artist);
                CHECK(!strncmp(txt_fmt, "128k 44.1kHz", 12), "format line '%s'", txt_fmt);
                CHECK(strstr(txt_status, "Playing 1 of 1 - ") && strstr(txt_status, "KB/s"), "status '%s'", txt_status);
                CHECK((ctl_prog.param >> 8) > 0 && strncmp(txt_time, "00:0", 4) == 0 && !strchr(txt_time, '/'),
                      "progress bar = buffer %lu/255, time '%s' without a length", (unsigned long)(ctl_prog.param >> 8), txt_time);
                static char bad[] = "http://radio.test/aac\0";
                pv_cmd(PVA_C_PLAY_URL, bad, sizeof bad);
                stream_phase = 3;
                ticks_left = 10;
                step--;
                return 0;
            } else if (stream_phase == 3) {
                CHECK(!strcmp(txt_status, "Stream stopped: not MP3 (AAC/Ogg/HLS)"), "failed stream: '%s'", txt_status);
                printf("[internet radio directory]\n");
                open_folder("/");
                activate_row((unsigned short)find_row("[Internet radio]"));
                dump_rows(8);
                CHECK(!strcmp(txt_path, "/Internet radio") && find_row("[By genre]") > 0 && find_row("[By country]") > 0, "home '%s'", txt_path);
                activate_row((unsigned short)find_row("[By genre]"));
                CHECK(!strcmp(txt_path, "/Internet radio/By genre") && find_row("[Jazz]") > 0, "genres '%s'", txt_path);
                activate_row((unsigned short)find_row("[Jazz]"));
                CHECK(dir_loading && !strcmp(txt_status, "Loading the station list...") && !strcmp(txt_path, "/Internet radio/By genre"),
                      "Jazz: '%s', the genres stay on show", txt_status);
                stream_phase = 4;
                ticks_left = 10;
                step--;
                return 0;
            } else if (stream_phase == 4) {
                dump_rows(8);
                CHECK(!dir_loading && !strcmp(txt_path, "/Internet radio/By genre/Jazz") && !strcmp(txt_status, "3 entries"),
                      "list opened by itself: '%s', '%s'", txt_path, txt_status);
                int r2 = find_row("Radio Two Live"), r3 = find_row("Secure Jazz");
                CHECK(r2 == 1 && !strcmp(row_info[r2], "128k") && r3 > 0 && !strcmp(row_info[r3], "192k"), "stations with bitrates");
                activate_row((unsigned short)r2);
                stream_phase = 5;
                ticks_left = 25;
                step--;
                return 0;
            } else if (stream_phase == 5) {
                CHECK(!strncmp(txt_status, "Playing 1 of 3", 14) && !strcmp(txt_title, "Radio Two Live") && host_esp_clicks == 1,
                      "plays: '%s' / '%s', click counted", txt_status, txt_title);
                activate_row(0);                    // '..': genres
                host_esp_api_all_down = true;
                activate_row((unsigned short)find_row("[Rock]"));
                stream_phase = 6;
                ticks_left = 25;
                step--;
                return 0;
            } else if (stream_phase == 6) {
                CHECK(!dir_loading && !strcmp(txt_status, "Station list: connection refused") && !strcmp(txt_path, "/Internet radio/By genre"),
                      "servers down: '%s', still in '%s'", txt_status, txt_path);
                host_esp_api_all_down = false;
                printf("[favourites and more stations]\n");
                open_folder("/Internet radio");
                activate_row((unsigned short)find_row("[Favourites]"));
                CHECK(!strcmp(txt_path, "/Internet radio/Favourites") && cd_list.lines == 1, "Favourites, empty: %u rows", cd_list.lines);
                activate_row(0);
                activate_row((unsigned short)find_row("[By genre]"));
                activate_row((unsigned short)find_row("[Rock]"));
                stream_phase = 7;
                ticks_left = 15;
                step--;
                return 0;
            } else if (stream_phase == 7) {
                dump_rows(3);
                CHECK(dir_count == 62 && !strcmp(row_name[cd_list.lines - 1], "[More stations...]"), "Rock: 60 stations + '%s'", row_name[cd_list.lines - 1]);
                select_row(5);
                key_press('F');
                CHECK(!strcmp(txt_status, "Added to favourites: Rock Station 004"), "F: '%s'", txt_status);
                key_press('f');
                CHECK(!strcmp(txt_status, "Already a favourite"), "F again: '%s'", txt_status);
                activate_row((unsigned short)(cd_list.lines - 1));
                CHECK(dir_loading, "More stations: loading");
                stream_phase = 8;
                ticks_left = 15;
                step--;
                return 0;
            } else if (stream_phase == 8) {
                CHECK(dir_count == 122 && !strcmp(row_name[cd_list.clicked], "Rock Station 060"),
                      "120 stations, the first new one is marked ('%s', row %u)", row_name[cd_list.clicked], cd_list.clicked);
                key_press('F');
                CHECK(!strcmp(txt_status, "Added to favourites: Rock Station 060"), "F on a new one: '%s'", txt_status);
                open_folder("/Internet radio");
                activate_row((unsigned short)find_row("[Favourites]"));
                dump_rows(4);
                CHECK(cd_list.lines == 3 && !strcmp(row_name[1], "Rock Station 004") && !strcmp(row_name[2], "Rock Station 060"), "2 favourites");
                select_row(1);
                key_press(KEY_DEL);
                CHECK(!strcmp(txt_status, "Removed from favourites") && cd_list.lines == 2 && !strcmp(row_name[1], "Rock Station 060"),
                      "Del: '%s', %u rows", txt_status, cd_list.lines);
                activate_row(1);
                stream_phase = 9;
                ticks_left = 15;
                step--;
                return 0;
            } else if (stream_phase == 9) {
                CHECK(!strcmp(txt_title, "Rock Station 060") && !strncmp(txt_status, "Playing 1 of 1", 14), "plays the favourite: '%s'", txt_status);
                select_row(0);
                key_press('F');                     // no station marked: the one that plays
                CHECK(!strcmp(txt_status, "Already a favourite"), "F with '..' marked uses the stream that plays: '%s'", txt_status);
                stream_phase = 10;
                f_unlink("0:/RADIOFAV.M3U");
                printf("[equalizer]\n");
                key_press('E');
                CHECK(eq_id == 3 && !strcmp(eq_val[0], "0") && !strcmp(txt_preset, "Preset: Flat") && cd_eq0.value == 12,
                      "E opens it: '%s', 60 Hz '%s'", txt_preset, eq_val[0]);
                eq_click(E_P1);                     // Rock
                read_status();
                CHECK((signed char)st[PVA_ST_EQ] == 5 && (signed char)st[PVA_ST_EQ + 2] == -2 && !strcmp(eq_val[2], "-2") &&
                      !strcmp(txt_preset, "Preset: Rock") && cd_eq0.value == 7, "Rock: engine %d %d %d %d %d",
                      (signed char)st[PVA_ST_EQ], (signed char)st[PVA_ST_EQ + 1], (signed char)st[PVA_ST_EQ + 2],
                      (signed char)st[PVA_ST_EQ + 3], (signed char)st[PVA_ST_EQ + 4]);
                cd_eq2.value = 0;                   // 1 kHz slider to the top
                eq_click(E_S2);
                read_status();
                CHECK((signed char)st[PVA_ST_EQ + 2] == 12 && !strcmp(eq_val[2], "+12") && !strcmp(txt_preset, "Preset: Custom"),
                      "slider: 1 kHz %+d, '%s'", (signed char)st[PVA_ST_EQ + 2], txt_preset);
                cd_bal.value = 80;
                eq_click(E_BAL);
                read_status();
                CHECK(st[PVA_ST_BALANCE] == 80 && !strcmp(txt_bal, "R 30"), "balance slider: engine %u, '%s'", st[PVA_ST_BALANCE], txt_bal);
                cd_bal.value = 52;
                eq_click(E_BAL);
                CHECK(balance == 50 && !strcmp(txt_bal, "Centre"), "near the middle snaps to '%s'", txt_bal);
                cd_bal.value = 20;
                eq_click(E_BAL);
                key_press('E');
                eq_close();
                balance = 50;
                memset(eq_gain, 0, sizeof eq_gain);
                eq_preset = 0;
                eq_load();
                CHECK(eq_gain[0] == 5 && eq_gain[2] == 12 && eq_gain[4] == 5 && eq_preset == 8, "PICOPLAY.CFG keeps it (%d %d %d, preset %u)",
                      eq_gain[0], eq_gain[2], eq_gain[4], eq_preset);
                CHECK(balance == 20, "and the balance (%u)", balance);
                balance = 50;
                eq_set_preset(0);
                f_unlink("0:/PICOPLAY.CFG");
            }
            ev_click(C_STOP, 0, 0);
            ticks_left = 2;
            return 1;
        case 18:
            CHECK(!strcmp(txt_title, "No track") && !strcmp(txt_status, "Stopped") && !strcmp(txt_time, "--:-- / --:--"), "stopped: '%s' '%s'", txt_title, txt_status);
            printf("[engine stops answering]\n");
            engine_frozen = 1;
            ticks_left = 15;
            return 0;
        case 19:
            CHECK(engine_ok == 2 && strstr(txt_status, "Engine stuck in"), "status '%s'", txt_status);
            {
                uint32_t t0 = pva_hal_millis();
                engine_ok = 1;                          // try a command anyway
                int r = pv_cmd(PVA_C_PING, 0, 0);
                uint32_t dt = pva_hal_millis() - t0;
                CHECK(r == -1 && dt <= 3200 && idles > 0, "a command to a stuck engine gives up after %u ms, yielding meanwhile", dt);
            }
            engine_frozen = 0;
            ticks_left = 3;
            return 0;
        case 20:
            CHECK(engine_ok == 1 && strstr(txt_status, "again"), "engine back: '%s'", txt_status);
            CHECK(host_audio_underruns == 0, "no audio underruns during the whole run (%u)", host_audio_underruns);
            ev_close();
            return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    host_disk_open(argv[1], 0);
    stream_src = argc > 2 ? argv[2] : NULL;         // MP3 for the simulated ESP (optional)
    if (stream_src) host_esp_load_audio(stream_src);
    static uint8_t arena[116 * 1024];
    host_audio_unlimited = false;
    pva_init(arena, sizeof arena);
    pva_core1_init();

    printf("== PicoPlay with the engine in slot 1-3 ==\n");
    if (!setjmp(done)) app_main(0, 0);
    printf("  app exited\n");

    printf("== PicoPlay without an engine ==\n");
    scenario = 1; step = 0; engine_present = 0; msgboxes = 0; ticks_left = 0;
    win_id = -1; engine_ok = 0;
    if (!setjmp(done)) app_main(0, 0);
    printf("  app exited\n");

    printf("\n%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
