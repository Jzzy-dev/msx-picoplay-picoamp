#define TXT_ARTIST_SIZE 84
#define TXT_TIME_SIZE 20
#define TXT_FMT_SIZE 24
#define TXT_TITLE_SIZE 50
#define TXT_PATH_SIZE 64
#define TXT_STATUS_SIZE 80
/* PicoPlay window data for the PC test (same names as pvgui.h, no desktop) */
#define LIST_PAGE  120
#define LIST_ROWS  (LIST_PAGE + 2)
#define NAME_LEN   40
#define PROG_COLORS ((COLOR_ORANGE << 6) | (COLOR_RED << 4) | (COLOR_BLACK << 2) | COLOR_BLACK)
enum { C_BG, C_TITLE, C_ARTIST, C_TIME, C_FMT, C_PROG, C_PREV, C_PLAY, C_STOP, C_NEXT, C_SHUF, C_REP, C_VOLT, C_VOL, C_PATH, C_HNAME, C_HSIZE, C_LIST, C_COUNT };
#define PROG_X 4
#define PROG_W 244
#define M_REFRESH 1
#define M_REMOUNT 2
#define M_DIAG    3
#define M_LOG     4
#define M_QUIT    9
#define M_ABOUT   10
#define M_FAV_ADD 11
#define M_FAV_DEL 12
#define M_EQ      13
#define EQ_BANDS  5
#define EQ_RANGE  24
enum { E_BG, E_S0, E_S1, E_S2, E_S3, E_S4, E_V0, E_V1, E_V2, E_V3, E_V4, E_F0, E_F1, E_F2, E_F3, E_F4,
       E_P0, E_P1, E_P2, E_P3, E_P4, E_P5, E_P6, E_P7, E_NAME, E_BALT, E_BAL, E_BALV, E_COUNT };
Ctrl_Slider cd_bal = { 0, 0, 50, 100, 5, -5 };
char txt_bal[12];
Ctrl_Slider cd_eq0 = { 0, 0, 12, 24, 1, -1 }, cd_eq1 = { 0, 0, 12, 24, 1, -1 }, cd_eq2 = { 0, 0, 12, 24, 1, -1 },
            cd_eq3 = { 0, 0, 12, 24, 1, -1 }, cd_eq4 = { 0, 0, 12, 24, 1, -1 };
char eq_val[EQ_BANDS][4];
char txt_preset[24];
Window win_eq;
#define TEXT_LINES 40
#define TEXT_LEN   60
char txt_title[50] = "No track";
char txt_artist[84] = "";
char txt_time[20] = "--:-- / --:--";
char txt_fmt[24] = "";
char txt_path[64] = "/";
char txt_status[80] = "";
char txt_play[8] = "Play";
char chk_shuffle, chk_repeat;
Ctrl_Slider cd_volume = { 0, 0, 80, 100, 5, -5 };
char row_name[LIST_ROWS][NAME_LEN + 1];
char row_info[LIST_ROWS][8];
List_Row2Col rows[LIST_ROWS];
short row_entry[LIST_ROWS];
unsigned char row_type[LIST_ROWS];
unsigned short dir_count, page_first;
List cd_list;
Ctrl ctl_prog;
Window win_main, win_text;
char tline[TEXT_LINES][TEXT_LEN + 1];
List_Row trows[TEXT_LINES];
List cd_tlist;
char txt_twin[32];
static void gui_texts_init(void) {}
