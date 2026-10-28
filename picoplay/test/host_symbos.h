/* Minimal SymbOS/SCC declarations for compiling PicoPlay's logic on a PC. */
#ifndef HOST_SYMBOS_H
#define HOST_SYMBOS_H
#include <stdint.h>
#include <stdlib.h>
#define _transfer
#define _data
#define COLOR_YELLOW 0
#define COLOR_BLACK 1
#define COLOR_ORANGE 2
#define COLOR_RED 3
#define TEXT_FILL 128
#define ALIGN_LEFT 0
#define ALIGN_RIGHT 1
#define BUTTON_OK 1
#define TITLE_ERROR 8
#define TITLE_INFO 16
#define MSR_DSK_WCLICK 162
#define DSK_ACT_CLOSE 5
#define DSK_ACT_MENU 6
#define DSK_ACT_CONTENT 14
#define DSK_ACT_KEY 16
#define DSK_SUB_MLCLICK 0
#define DSK_SUB_MDCLICK 2
typedef struct { unsigned short flags; char *value; } List_Row;
typedef struct { unsigned short flags; char *value1; char *value2; } List_Row2Col;
typedef struct { unsigned short lines, scroll; void *rowdata; unsigned short status; unsigned char columns, sorting;
                 void *coldata; unsigned short clicked; unsigned char flags, resorted; } List;
typedef struct { unsigned char type, unused; unsigned short value, maxvalue; signed char increment, decrement; } Ctrl_Slider;
typedef struct { uintptr_t param; } Ctrl;
typedef struct { int dummy; } Window;
extern char _symmsg[14];
extern unsigned char _sympid, _symbank;
signed char Win_Open(unsigned char bank, void *addr);
void Win_Redraw(unsigned char winID, signed char what, unsigned char first);
void Win_Redraw_Status(unsigned char winID);
void Win_Redraw_Title(unsigned char winID);
void Win_Focus(unsigned char winID);
void Win_Close(unsigned char winID);
unsigned char MsgBox(char *l1, char *l2, char *l3, unsigned int pen, unsigned char type, char *i4, char *i16, void *modal);
unsigned short Msg_Sleep(char rec, char send, char *msg);
signed char Timer_Wake(unsigned char pid, unsigned char msgid, unsigned short cycles);
void Timer_Delete(unsigned char id);
void Idle(void);
unsigned short Sys_Counter16(void);
unsigned char File_Open(unsigned char bank, char *path);
unsigned char File_New(unsigned char bank, char *path, unsigned char attrib);
unsigned char File_Close(unsigned char id);
unsigned short File_Read(unsigned char id, unsigned char bank, char *addr, unsigned short len);
unsigned short File_Write(unsigned char id, unsigned char bank, char *addr, unsigned short len);
#define exit(x) host_exit(x)
void host_exit(int code);
#define main app_main
#endif
#ifndef ROW_MARKED
#define ROW_MARKED 0x8000
#define KEY_ESC 27
#define KEY_UP 136
#define KEY_DOWN 137
#define KEY_LEFT 138
#define KEY_RIGHT 139
#define KEY_DEL 127
#endif
