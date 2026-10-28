// MSX PICOVERSE PROJECT
// pva_proto.h - PicoVerse Audio Engine (PVA): MSX-visible register window.
//
// The engine is a memory-mapped device in its own cartridge sub-slot. Every
// MSX access to it is a memory cycle, so the Pico holds the Z80 with /WAIT
// until it has answered: no read can ever be missed, unlike an I/O port.
//
// The window is page 1 of the device's (sub-)slot, 4000h-4FFFh. Reads outside
// the window return FFh, writes outside it are ignored. Multi-byte values are
// little endian.
//
//   4000h  16  ID: "PVAUDIO" 00h, api, fw major, fw minor, 0...      (read)
//   4010h   1  CMD_TOKEN   token of the next command                 (read/write)
//   4011h   1  CMD_CODE    writing it posts the command               (write)
//   4012h   1  DONE_TOKEN  token of the last finished command         (read)
//   4013h   1  RESULT      PVA_OK or PVA_E_xxx of that command        (read)
//   4014h   2  REPLY_LEN   bytes in REPLY                             (read)
//   4016h   1  HEARTBEAT   +1 at least every 10 ms while core 1 runs  (read)
//   4017h   1  BUSY        1 while a command executes                 (read)
//   4020h 224  STATUS      live status block, see PVA_ST_xxx          (read)
//   4100h 512  ARGS        command arguments                          (read/write)
//   4400h 2048 REPLY       command reply                              (read)
//
// Command protocol (the MSX never waits in a loop for the engine):
//   1. wait until DONE_TOKEN == the token of the previous command
//   2. write the arguments to ARGS
//   3. write a new token (previous + 1) to CMD_TOKEN, then the code to CMD_CODE
//   4. later (for example on the next timer tick) check DONE_TOKEN == token,
//      then read RESULT, REPLY_LEN and REPLY.
//
// Status block consistency: STATUS+0 is a sequence byte. The engine makes it
// odd before it updates the block and even afterwards. Read it, copy the
// block, read it again; if it changed or is odd, copy again.
//
// This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
// License". https://creativecommons.org/licenses/by-nc-sa/4.0/

#ifndef PVA_PROTO_H
#define PVA_PROTO_H

#define PVA_API_VERSION     1
#define PVA_FW_MAJOR        0
#define PVA_FW_MINOR        10

#define PVA_WIN_BASE        0x4000u
#define PVA_WIN_SIZE        0x1000u

// window offsets
#define PVA_R_ID            0x000u
#define PVA_R_CMD_TOKEN     0x010u
#define PVA_R_CMD_CODE      0x011u
#define PVA_R_DONE_TOKEN    0x012u
#define PVA_R_RESULT        0x013u
#define PVA_R_REPLY_LEN     0x014u
#define PVA_R_HEARTBEAT     0x016u
#define PVA_R_BUSY          0x017u
// for a stuck or crashed engine (written by core 1 as it goes, read them when
// the heartbeat stops)
#define PVA_R_WHERE         0x018u  // u8  PVA_W_xxx: what core 1 was doing last
#define PVA_R_LAST_CMD      0x019u  // u8  code of the last command it started
#define PVA_R_FAULT         0x01Au  // u8  0, 1 = crash (HardFault), 2 = panic (e.g. out of heap)
#define PVA_R_FAULT_PC      0x01Cu  // u32 program counter of the crash
#define PVA_R_FAULT_TEXT    0xF00u  // char[64] panic message
// visualisation, about 50 updates a second while something plays (see PVA_VIZ_xxx)
#define PVA_R_VIZ           0xC00u
#define PVA_R_STATUS        0x020u
#define PVA_STATUS_SIZE     224u
#define PVA_R_ARGS          0x100u
#define PVA_ARGS_SIZE       512u
#define PVA_R_REPLY         0x400u
#define PVA_REPLY_SIZE      2048u

// ---------------------------------------------------------------- commands
#define PVA_C_PING          0x01    // reply: version text
#define PVA_C_MOUNT         0x02    // (re)mount the microSD card
#define PVA_C_LOG           0x03    // reply: engine log text (oldest first)
#define PVA_C_DIAG          0x04    // reply: diagnostics text
#define PVA_C_DIR_OPEN      0x10    // args: path (0-terminated, "/" = root, "" = reopen the
                                    // current folder); reply: u16 count, path (0-terminated)
#define PVA_C_DIR_READ      0x11    // args: u16 first, u8 max; reply: entries (PVA_DE_xxx)
#define PVA_C_DIR_ENTER     0x12    // args: u16 index of a folder or ".." entry; reply as DIR_OPEN
#define PVA_C_ENTRY_INFO    0x13    // args: u16 index of a station (0xFFFF = the stream that plays);
                                    // reply: address (0-terminated), name (0-terminated)
#define PVA_C_DIR_SEARCH    0x14    // args: text (0-terminated, up to 60): Radio Browser stations whose
                                    // name has it (any case), as Internet radio/Search/<text>; answers
                                    // PVA_E_BUSY and opens by itself as DIR_ENTER does (DIR_STATE)
#define PVA_C_FAV_ADD       0x15    // args: u16 entry of the open list (0xFFFF = the stream that plays):
                                    // the station goes into RADIOFAV.M3U; reply: its name. Only where no
                                    // one else writes the card (PicoAmp ROM): else PVA_E_RDONLY
#define PVA_C_FAV_DEL       0x16    // args: u16 entry of Internet radio/Favourites: it leaves the file,
                                    // the folder is read again (PVA_E_RDONLY as FAV_ADD)
#define PVA_C_PLAY_INDEX    0x20    // args: u16 index in the open folder
#define PVA_C_PLAY_PATH     0x21    // args: path
#define PVA_C_PAUSE         0x22    // toggle pause
#define PVA_C_STOP          0x23
#define PVA_C_NEXT          0x24
#define PVA_C_PREV          0x25
#define PVA_C_SEEK          0x26    // args: u16 seconds
#define PVA_C_VOLUME        0x27    // args: u8 0..100
#define PVA_C_MODE          0x28    // args: u8 PVA_MODE_xxx bits
#define PVA_C_EQ            0x2A    // args: 5 x s8 band gains in dB (-12..+12): 60 Hz, 250 Hz,
                                    // 1 kHz, 4 kHz, 12 kHz
#define PVA_C_BALANCE       0x2B    // args: u8 0 (left only) .. 50 (centre) .. 100 (right only)
#define PVA_C_PLAY_URL      0x29    // args: URL (http:// or https://, 0-terminated), then an
                                    // optional station name (0-terminated); MP3 streams

// results
#define PVA_OK              0x00
#define PVA_E_UNKNOWN       0x01    // unknown command
#define PVA_E_ARGS          0x02    // bad arguments
#define PVA_E_NOCARD        0x03    // microSD not mounted
#define PVA_E_NOTFOUND      0x04    // path or file not found
#define PVA_E_FORMAT        0x05    // not a playable file
#define PVA_E_IO            0x06    // read error (see PVA_ST_FRESULT)
#define PVA_E_RANGE         0x07    // index out of range
#define PVA_E_STATE         0x08    // not possible in this state
#define PVA_E_NET           0x09    // network failure (see PVA_ST_NET_ERR)
#define PVA_E_NOWIFI        0x0A    // no ESP WiFi link in this firmware (-w), or no memory for streams
#define PVA_E_EXISTS        0x0C    // FAV_ADD: already a favourite
#define PVA_E_RDONLY        0x0D    // FAV_ADD/DEL: the card is Nextor's to write (MSX-DOS writes the file)
#define PVA_E_FULL          0x0E    // FAV_ADD: RADIOFAV.M3U would pass 4 KB
#define PVA_E_BUSY          0x0B    // DIR_ENTER: the list is being fetched; it opens by itself when
                                    // PVA_ST_DIR_STATE turns READY (then DIR_GEN changes)

// directory entry in a DIR_READ reply: u8 type, u32 size, u8 len, name[len]
#define PVA_DE_DIR          1
#define PVA_DE_MP3          2
#define PVA_DE_WAV          3
#define PVA_DE_M3U          4
#define PVA_DE_PARENT       5       // ".." (not in the root)
#define PVA_DE_URL          6       // stream (PVA_ST_FORMAT while a stream plays)
#define PVA_NAME_MAX        63      // longest name in a reply (longer ones are cut)

// play modes
#define PVA_MODE_REPEAT_ALL 0x01
#define PVA_MODE_SHUFFLE    0x02
#define PVA_MODE_REPEAT_ONE 0x04

// ------------------------------------------------------------ status block
#define PVA_ST_SEQ          0       // u8  odd while the engine updates the block
#define PVA_ST_STATE        1       // u8  PVA_STATE_xxx
#define PVA_ST_FLAGS        2       // u8  PVA_F_xxx
#define PVA_ST_VOLUME       3       // u8  0..100
#define PVA_ST_ELAPSED      4       // u16 seconds
#define PVA_ST_TOTAL        6       // u16 seconds, 0 = unknown
#define PVA_ST_BITRATE      8       // u16 kbit/s
#define PVA_ST_RATE         10      // u16 sample rate / 10
#define PVA_ST_CHANNELS     12      // u8
#define PVA_ST_ERROR        13      // u8  last PVA_E_xxx of playback
#define PVA_ST_FRESULT      14      // u8  last FatFS FRESULT that failed
#define PVA_ST_TRACK_ID     15      // u16 +1 for every new track
#define PVA_ST_VU_L         17      // u8  0..15
#define PVA_ST_VU_R         18      // u8  0..15
#define PVA_ST_PL_POS       19      // u16 position in the play list (0-based)
#define PVA_ST_PL_COUNT     21      // u16 tracks in the play list
#define PVA_ST_MODE         23      // u8  PVA_MODE_xxx
#define PVA_ST_UNDERRUNS    24      // u16 audio buffer underruns
#define PVA_ST_MOUNT_FR     26      // u8  FRESULT of the last mount
#define PVA_ST_DIR_GEN      27      // u8  +1 for every DIR_OPEN
#define PVA_ST_UPTIME       28      // u16 seconds since power on
#define PVA_ST_LOG_COUNT    30      // u16 log lines written
#define PVA_ST_TITLE        32      // char[48] title (tag or file name), 0-terminated
#define PVA_ST_ARTIST       80      // char[40]
#define PVA_ST_ALBUM        120     // char[40]
#define PVA_ST_TITLE_LEN    48
#define PVA_ST_ARTIST_LEN   40
#define PVA_ST_ALBUM_LEN    40
#define PVA_ST_FORMAT       160     // u8  PVA_DE_MP3 / PVA_DE_WAV of the track
#define PVA_ST_PL_KIND      161     // u8  0 = folder, 1 = M3U play list, 2 = URL
// streams (all 0 when no stream plays)
#define PVA_ST_NET_STATE    162     // u8  PVA_NET_xxx
#define PVA_ST_BUF_PCT      163     // u8  stream buffer fill, 0..100
#define PVA_ST_NET_RATE     164     // u16 received bytes per second / 100 (0.1 KB/s)
#define PVA_ST_RECONNECTS   166     // u16
#define PVA_ST_NET_ERR      168     // u8  PVA_NERR_xxx of the last failure
#define PVA_ST_HTTP         169     // u16 last HTTP status
#define PVA_ST_BUF_KB       171     // u16 buffer size in KB
// for a player that redraws only what changed
#define PVA_ST_DISP_GEN     173     // u8  +1 whenever something a player shows changed (not VU,
                                    //     uptime or log count; the buffer and rate below are coarse)
#define PVA_ST_DISP_BUF     174     // u8  buffer fill in steps of 10 %, with a dead band
#define PVA_ST_DISP_RATE    175     // u16 receive rate (0.1 KB/s), sampled every 5 s
// the internet radio directory (virtual folders under "[Internet radio]")
#define PVA_ST_DIR_STATE    177     // u8  PVA_DIRS_xxx of the last list fetched
#define PVA_ST_DIR_ERR      178     // u8  PVA_NERR_xxx when it failed
#define PVA_ST_EQ           179     // s8[5] equalizer band gains in dB
#define PVA_ST_BALANCE      184     // u8  0..100, 50 = centre
#define PVA_EQ_BANDS        5
#define PVA_EQ_MAX_DB       12

#define PVA_W_LOOP          1       // main loop
#define PVA_W_COMMAND       2
#define PVA_W_STREAM        3       // network stream
#define PVA_W_RADIO         4       // station directory
#define PVA_W_DECODE        5
#define PVA_W_STATUS        6
#define PVA_W_CARD          7       // microSD for Nextor

// PVA_R_VIZ block: offsets
#define PVA_VIZ_SEQ         0x00    // u8  odd while it is updated, +2 per update
#define PVA_VIZ_COUNT       0x01    // u8  bands (PVA_VIZ_BANDS)
#define PVA_VIZ_TOP         0x02    // u8  highest level (PVA_VIZ_MAX)
#define PVA_VIZ_LEVEL       0x04    // u8[24] band levels, 60 Hz .. 16 kHz on a log scale, 2 dB a step
#define PVA_VIZ_PEAK        0x20    // u8[24] peaks (held a moment, then falling)
#define PVA_VIZ_VU          0x40    // u8[2] left, right peak level 0..31 (2 dB a step)
#define PVA_VIZ_SCOPE       0x48    // s8[64] the newest samples (mono, every 4th)
#define PVA_VIZ_FREQ        0x90    // u16[24] centre frequency of each band in Hz (for labels)
#define PVA_VIZ_BANDS       24
#define PVA_VIZ_MAX         31
#define PVA_VIZ_WAVE        64

#define PVA_STATE_STOPPED   0
#define PVA_STATE_PLAYING   1
#define PVA_STATE_PAUSED    2
#define PVA_STATE_LOADING   3

#define PVA_F_MOUNTED       0x01
#define PVA_F_TAGS          0x02    // title/artist come from a tag
#define PVA_F_SEEKABLE      0x04
#define PVA_F_DIR_OPEN      0x08
#define PVA_F_STREAM        0x10    // a stream plays (title = stream title, album = station)
#define PVA_F_BUFFERING     0x20    // the stream is filling its buffer (no audio yet)

#define PVA_NET_IDLE        0
#define PVA_NET_LOOKUP      1       // DNS
#define PVA_NET_CONNECT     2       // TCP / TLS open
#define PVA_NET_REQUEST     3       // HTTP request and headers
#define PVA_NET_STREAM      4       // receiving audio
#define PVA_NET_RETRY       5       // waiting before a reconnect
#define PVA_NET_FAILED      6

#define PVA_NERR_NONE       0
#define PVA_NERR_NOWIFI     1       // no ESP or not connected to an access point
#define PVA_NERR_DNS        2
#define PVA_NERR_CONNECT    3       // TCP/TLS open refused
#define PVA_NERR_HTTP       4       // HTTP status not 200 (see PVA_ST_HTTP)
#define PVA_NERR_FORMAT     5       // not MP3 (AAC, Ogg, HLS ...)
#define PVA_NERR_TIMEOUT    6       // the ESP or the server stopped answering
#define PVA_NERR_CLOSED     7       // the server closed the stream
#define PVA_NERR_URL        8       // bad URL, too many redirects

#define PVA_DIRS_IDLE       0
#define PVA_DIRS_LOADING    1
#define PVA_DIRS_DONE       2
#define PVA_DIRS_FAILED     3

#endif
