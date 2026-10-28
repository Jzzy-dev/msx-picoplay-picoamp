/* PicoPlay - window and control data (SymbOS transfer/data segments) */

/* ------------------------------------------------------------ window data */
_transfer char icon[19] = { 0x02, 0x08, 0x08, 0x00, 0x00, 0x33, 0x00, 0x37, 0x08, 0x37, 0x08,
                            0x34, 0x08, 0x34, 0x08, 0x74, 0x08, 0xF0, 0x00 };

#define TXT_TITLE_SIZE 50
_data char txt_title[TXT_TITLE_SIZE];
#define TXT_ARTIST_SIZE 84
_data char txt_artist[TXT_ARTIST_SIZE];
#define TXT_TIME_SIZE 20
_data char txt_time[TXT_TIME_SIZE];
#define TXT_FMT_SIZE 24
_data char txt_fmt[TXT_FMT_SIZE];
#define TXT_PATH_SIZE 64
_data char txt_path[TXT_PATH_SIZE];
#define TXT_STATUS_SIZE 80
_data char txt_status[TXT_STATUS_SIZE];
_data char txt_play[8];

_transfer Ctrl_Text cd_title  = { txt_title,  (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_artist = { txt_artist, (COLOR_RED << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_time   = { txt_time,   (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_fmt    = { txt_fmt,    (COLOR_RED << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_RIGHT };
_transfer Ctrl_Text cd_path   = { txt_path,   (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_vol    = { "Vol",      (COLOR_BLACK << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_hname  = { "Name",     (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_hsize  = { "Size",     (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_RIGHT };

_transfer char chk_shuffle = 0;
_transfer char chk_repeat = 0;
_transfer Ctrl_Check cd_shuffle = { &chk_shuffle, "Shuffle", (COLOR_BLACK << 2) | COLOR_ORANGE };
_transfer Ctrl_Check cd_repeat  = { &chk_repeat,  "Repeat",  (COLOR_BLACK << 2) | COLOR_ORANGE };
_transfer Ctrl_Slider cd_volume = { SLIDER_H | SLIDER_VALUE, 0, 80, 100, 5, -5 };

/* folder list: one page of up to LIST_PAGE entries, plus "previous"/"more" rows */
#define LIST_PAGE  120
#define LIST_ROWS  (LIST_PAGE + 2)
#define NAME_LEN   40
_data char row_name[LIST_ROWS][NAME_LEN + 1];
_data char row_info[LIST_ROWS][8];
_transfer List_Row2Col rows[LIST_ROWS];
short row_entry[LIST_ROWS];                 /* engine index, -1 = previous page, -2 = next page */
unsigned char row_type[LIST_ROWS];
unsigned short dir_count, page_first;

_transfer List_Column cols[2] = {
    { ALIGN_LEFT | LTYPE_TEXT, 0, 196, "Name" },
    { ALIGN_RIGHT | LTYPE_TEXT, 0, 40, "Size" }
};
_transfer List cd_list = { 0, 0, rows, 0, 2, 0, cols, 0, LIST_SCROLL };

#define PROG_COLORS ((COLOR_ORANGE << 6) | (COLOR_RED << 4) | (COLOR_BLACK << 2) | COLOR_BLACK)

enum {
    C_BG, C_TITLE, C_ARTIST, C_TIME, C_FMT, C_PROG,
    C_PREV, C_PLAY, C_STOP, C_NEXT, C_SHUF, C_REP, C_VOLT, C_VOL,
    C_PATH, C_HNAME, C_HSIZE, C_LIST, C_COUNT
};

#define WIN_W 252
#define WIN_H 166
#define PROG_X 4
#define PROG_W 244

_transfer Ctrl ctl_bg     = { C_BG,     C_AREA,     -1, COLOR_ORANGE, 0, 0, 10000, 10000 };
_transfer Ctrl ctl_title  = { C_TITLE,  C_TEXT,     -1, (unsigned short)&cd_title, 4, 3, 244, 8 };
_transfer Ctrl ctl_artist = { C_ARTIST, C_TEXT,     -1, (unsigned short)&cd_artist, 4, 13, 244, 8 };
_transfer Ctrl ctl_time   = { C_TIME,   C_TEXT,     -1, (unsigned short)&cd_time, 4, 24, 100, 8 };
_transfer Ctrl ctl_fmt    = { C_FMT,    C_TEXT,     -1, (unsigned short)&cd_fmt, 104, 24, 144, 8 };
_transfer Ctrl ctl_prog   = { C_PROG,   C_PROGRESS, -1, PROG_COLORS, PROG_X, 34, PROG_W, 8 };
_transfer Ctrl ctl_prev   = { C_PREV,   C_BUTTON,   -1, (unsigned short)"|<", 4, 46, 24, 12 };
_transfer Ctrl ctl_play   = { C_PLAY,   C_BUTTON,   -1, (unsigned short)txt_play, 30, 46, 36, 12 };
_transfer Ctrl ctl_stop   = { C_STOP,   C_BUTTON,   -1, (unsigned short)"Stop", 68, 46, 30, 12 };
_transfer Ctrl ctl_next   = { C_NEXT,   C_BUTTON,   -1, (unsigned short)">|", 100, 46, 24, 12 };
_transfer Ctrl ctl_shuf   = { C_SHUF,   C_CHECK,    -1, (unsigned short)&cd_shuffle, 130, 44, 50, 8 };
_transfer Ctrl ctl_rep    = { C_REP,    C_CHECK,    -1, (unsigned short)&cd_repeat, 130, 53, 50, 8 };
_transfer Ctrl ctl_volt   = { C_VOLT,   C_TEXT,     -1, (unsigned short)&cd_vol, 184, 48, 16, 8 };
_transfer Ctrl ctl_vol    = { C_VOL,    C_SLIDER,   -1, (unsigned short)&cd_volume, 200, 48, 48, 8 };
_transfer Ctrl ctl_path   = { C_PATH,   C_TEXT,     -1, (unsigned short)&cd_path, 4, 64, 244, 8 };
/* The column titles are plain texts over a list box without titles: in a
   C_LISTFULL a click on a title makes the desktop sort the rows itself, and
   that locked up the desktop (and would mix up '..', the page rows and the
   engine's order). Folders come sorted by name from the engine already. */
_transfer Ctrl ctl_hname  = { C_HNAME,  C_TEXT,     -1, (unsigned short)&cd_hname, 6, 74, 100, 8 };
_transfer Ctrl ctl_hsize  = { C_HSIZE,  C_TEXT,     -1, (unsigned short)&cd_hsize, 196, 74, 40, 8 };
_transfer Ctrl ctl_list   = { C_LIST,   C_LISTBOX,  -1, (unsigned short)&cd_list, 4, 83, 244, 79 };

_transfer Ctrl_Group ctrls = { C_COUNT, 0, &ctl_bg };

/* menu */
#define M_REFRESH 1
#define M_REMOUNT 2
#define M_DIAG    3
#define M_LOG     4
#define M_QUIT    9
#define M_ABOUT   10
#define M_FAV_ADD 11
#define M_FAV_DEL 12
#define M_EQ      13
_transfer Menu menu_file = { 10 };
_transfer Menu_Entry mf1 = { MENU_ACTIVE, "Refresh folder", M_REFRESH };
_transfer Menu_Entry mf2 = { MENU_ACTIVE, "Remount microSD", M_REMOUNT };
_transfer Menu_Entry mf3 = { MENU_SEPARATOR, 0, 0 };
_transfer Menu_Entry mf4 = { MENU_ACTIVE, "Add to favourites (F)", M_FAV_ADD };
_transfer Menu_Entry mf5 = { MENU_ACTIVE, "Remove from favourites (Del)", M_FAV_DEL };
_transfer Menu_Entry mf6 = { MENU_ACTIVE, "Equalizer... (E)", M_EQ };
_transfer Menu_Entry mf7 = { MENU_ACTIVE, "Diagnostics...", M_DIAG };
_transfer Menu_Entry mf8 = { MENU_ACTIVE, "Engine log...", M_LOG };
_transfer Menu_Entry mf9 = { MENU_SEPARATOR, 0, 0 };
_transfer Menu_Entry mf10 = { MENU_ACTIVE, "Quit", M_QUIT };
_transfer Menu menu_help = { 1 };
_transfer Menu_Entry mh1 = { MENU_ACTIVE, "About PicoPlay", M_ABOUT };
_transfer Menu menu_main = { 2 };
_transfer Menu_Entry mm1 = { MENU_ACTIVE | MENU_SUBMENU, "File", (unsigned short)&menu_file };
_transfer Menu_Entry mm2 = { MENU_ACTIVE | MENU_SUBMENU, "Help", (unsigned short)&menu_help };

_transfer Window win_main = {
    WIN_NORMAL,
    WIN_CLOSE | WIN_TITLE | WIN_ICON | WIN_MENU | WIN_STATUS,
    0,
    40, 1,
    WIN_W, WIN_H,
    0, 0,
    WIN_W, WIN_H,
    WIN_W, WIN_H,
    WIN_W, WIN_H,
    icon,
    "PicoPlay",
    txt_status,
    &menu_main,
    &ctrls };

/* text window for diagnostics and the engine log */
#define TEXT_LINES 40
#define TEXT_LEN   60
_data char tline[TEXT_LINES][TEXT_LEN + 1];
_transfer List_Row trows[TEXT_LINES];
_transfer List_Column tcol = { ALIGN_LEFT | LTYPE_TEXT, 0, 300, "" };
_transfer List cd_tlist = { 0, 0, trows, 0, 1, 0, &tcol, 0, LIST_SCROLL };
_transfer Ctrl tctl_bg   = { 0, C_AREA,    -1, COLOR_ORANGE, 0, 0, 10000, 10000 };
_transfer Ctrl tctl_list = { 1, C_LISTBOX, -1, (unsigned short)&cd_tlist, 2, 2, 312, 128 };
_transfer Ctrl tctl_ok   = { 2, C_BUTTON,  -1, (unsigned short)"Close", 134, 134, 48, 12 };
_transfer Ctrl_Group tctrls = { 3, 0, &tctl_bg };
_data char txt_twin[32];
_transfer Window win_text = {
    WIN_NORMAL,
    WIN_CLOSE | WIN_TITLE | WIN_ICON,
    0,
    20, 20,
    316, 150,
    0, 0,
    316, 150,
    316, 150,
    316, 150,
    icon,
    txt_twin,
    0,
    0,
    &tctrls };


/* equalizer window: five vertical sliders (top = +12 dB), presets */
#define EQ_BANDS   5
#define EQ_RANGE   24                       /* slider 0..24 = +12..-12 dB */
_transfer Ctrl_Slider cd_eq0 = { SLIDER_V | SLIDER_VALUE, 0, 12, EQ_RANGE, 1, -1 };
_transfer Ctrl_Slider cd_eq1 = { SLIDER_V | SLIDER_VALUE, 0, 12, EQ_RANGE, 1, -1 };
_transfer Ctrl_Slider cd_eq2 = { SLIDER_V | SLIDER_VALUE, 0, 12, EQ_RANGE, 1, -1 };
_transfer Ctrl_Slider cd_eq3 = { SLIDER_V | SLIDER_VALUE, 0, 12, EQ_RANGE, 1, -1 };
_transfer Ctrl_Slider cd_eq4 = { SLIDER_V | SLIDER_VALUE, 0, 12, EQ_RANGE, 1, -1 };
_data char eq_val[EQ_BANDS][4];
_transfer Ctrl_Text cd_eqv0 = { eq_val[0], (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqv1 = { eq_val[1], (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqv2 = { eq_val[2], (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqv3 = { eq_val[3], (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqv4 = { eq_val[4], (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqf0 = { "60",  (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqf1 = { "250", (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqf2 = { "1k",  (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqf3 = { "4k",  (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_eqf4 = { "12k", (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_data char txt_preset[24];
_transfer Ctrl_Slider cd_bal = { SLIDER_H | SLIDER_VALUE, 0, 50, 100, 5, -5 };
_data char txt_bal[12];
_transfer Ctrl_Text cd_balt = { "Balance", (COLOR_RED << 2) | COLOR_ORANGE, ALIGN_LEFT };
_transfer Ctrl_Text cd_balv = { txt_bal, (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
_transfer Ctrl_Text cd_preset = { txt_preset, (COLOR_BLACK << 2) | COLOR_ORANGE | TEXT_FILL, ALIGN_LEFT };
enum {
    E_BG, E_S0, E_S1, E_S2, E_S3, E_S4, E_V0, E_V1, E_V2, E_V3, E_V4, E_F0, E_F1, E_F2, E_F3, E_F4,
    E_P0, E_P1, E_P2, E_P3, E_P4, E_P5, E_P6, E_P7, E_NAME, E_BALT, E_BAL, E_BALV, E_COUNT
};
#define EQ_X(i) (14 + (i) * 34)
_transfer Ctrl ectl_bg = { E_BG, C_AREA,   -1, COLOR_ORANGE, 0, 0, 10000, 10000 };
_transfer Ctrl ectl_s0 = { E_S0, C_SLIDER, -1, (unsigned short)&cd_eq0, EQ_X(0), 14, 8, 56 };
_transfer Ctrl ectl_s1 = { E_S1, C_SLIDER, -1, (unsigned short)&cd_eq1, EQ_X(1), 14, 8, 56 };
_transfer Ctrl ectl_s2 = { E_S2, C_SLIDER, -1, (unsigned short)&cd_eq2, EQ_X(2), 14, 8, 56 };
_transfer Ctrl ectl_s3 = { E_S3, C_SLIDER, -1, (unsigned short)&cd_eq3, EQ_X(3), 14, 8, 56 };
_transfer Ctrl ectl_s4 = { E_S4, C_SLIDER, -1, (unsigned short)&cd_eq4, EQ_X(4), 14, 8, 56 };
_transfer Ctrl ectl_v0 = { E_V0, C_TEXT, -1, (unsigned short)&cd_eqv0, EQ_X(0) - 6, 4, 22, 8 };
_transfer Ctrl ectl_v1 = { E_V1, C_TEXT, -1, (unsigned short)&cd_eqv1, EQ_X(1) - 6, 4, 22, 8 };
_transfer Ctrl ectl_v2 = { E_V2, C_TEXT, -1, (unsigned short)&cd_eqv2, EQ_X(2) - 6, 4, 22, 8 };
_transfer Ctrl ectl_v3 = { E_V3, C_TEXT, -1, (unsigned short)&cd_eqv3, EQ_X(3) - 6, 4, 22, 8 };
_transfer Ctrl ectl_v4 = { E_V4, C_TEXT, -1, (unsigned short)&cd_eqv4, EQ_X(4) - 6, 4, 22, 8 };
_transfer Ctrl ectl_f0 = { E_F0, C_TEXT, -1, (unsigned short)&cd_eqf0, EQ_X(0) - 2, 72, 22, 8 };
_transfer Ctrl ectl_f1 = { E_F1, C_TEXT, -1, (unsigned short)&cd_eqf1, EQ_X(1) - 4, 72, 22, 8 };
_transfer Ctrl ectl_f2 = { E_F2, C_TEXT, -1, (unsigned short)&cd_eqf2, EQ_X(2) - 2, 72, 22, 8 };
_transfer Ctrl ectl_f3 = { E_F3, C_TEXT, -1, (unsigned short)&cd_eqf3, EQ_X(3) - 2, 72, 22, 8 };
_transfer Ctrl ectl_f4 = { E_F4, C_TEXT, -1, (unsigned short)&cd_eqf4, EQ_X(4) - 4, 72, 22, 8 };
_transfer Ctrl ectl_p0 = { E_P0, C_BUTTON, -1, (unsigned short)"Flat",     4, 84, 44, 12 };
_transfer Ctrl ectl_p1 = { E_P1, C_BUTTON, -1, (unsigned short)"Rock",    50, 84, 44, 12 };
_transfer Ctrl ectl_p2 = { E_P2, C_BUTTON, -1, (unsigned short)"Pop",     96, 84, 44, 12 };
_transfer Ctrl ectl_p3 = { E_P3, C_BUTTON, -1, (unsigned short)"Jazz",   142, 84, 44, 12 };
_transfer Ctrl ectl_p4 = { E_P4, C_BUTTON, -1, (unsigned short)"Classic",  4, 98, 44, 12 };
_transfer Ctrl ectl_p5 = { E_P5, C_BUTTON, -1, (unsigned short)"Voice",   50, 98, 44, 12 };
_transfer Ctrl ectl_p6 = { E_P6, C_BUTTON, -1, (unsigned short)"Bass",    96, 98, 44, 12 };
_transfer Ctrl ectl_p7 = { E_P7, C_BUTTON, -1, (unsigned short)"Loud",   142, 98, 44, 12 };
_transfer Ctrl ectl_nm = { E_NAME, C_TEXT, -1, (unsigned short)&cd_preset, 4, 127, 182, 8 };
_transfer Ctrl ectl_bt = { E_BALT, C_TEXT, -1, (unsigned short)&cd_balt, 4, 114, 36, 8 };
_transfer Ctrl ectl_bl = { E_BAL, C_SLIDER, -1, (unsigned short)&cd_bal, 42, 114, 96, 8 };
_transfer Ctrl ectl_bv = { E_BALV, C_TEXT, -1, (unsigned short)&cd_balv, 142, 114, 44, 8 };
_transfer Ctrl_Group ectrls = { E_COUNT, 0, &ectl_bg };
#define EQ_W 190
#define EQ_H 137
_transfer Window win_eq = {
    WIN_NORMAL,
    WIN_CLOSE | WIN_TITLE | WIN_ICON,
    0,
    60, 30,
    EQ_W, EQ_H,
    0, 0,
    EQ_W, EQ_H,
    EQ_W, EQ_H,
    EQ_W, EQ_H,
    icon,
    "Equalizer",
    0,
    0,
    &ectrls };

/* SCC gives initialized _data char arrays no storage of their own (they all
   land on one address, on top of the next buffer), so the texts are declared
   uninitialized and filled in at startup. */
static void gui_texts_init(void)
{
    strcpy(txt_title, "No track");
    strcpy(txt_artist, "");
    strcpy(txt_time, "--:-- / --:--");
    strcpy(txt_fmt, "");
    strcpy(txt_path, "/");
    strcpy(txt_status, "Looking for the PicoVerse Audio Engine...");
    strcpy(txt_play, "Play");
    strcpy(txt_twin, "Diagnostics");
}
