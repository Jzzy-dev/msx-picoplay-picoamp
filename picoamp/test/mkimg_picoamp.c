// mkimg_picoamp.c - a card image for the PICOAMP harness: folders with long
// names and a track whose title and artist are longer than their places
//   mkimg_picoamp out.img assets-dir
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "ff.h"

int host_disk_open(const char *path, uint32_t create_sectors);

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("missing %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); *len = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*len + 4096);
    if (fread(b + 4096, 1, *len, f) != *len) exit(2);
    fclose(f);
    return b;
}
static void put(const char *dst, const void *data, size_t len)
{
    FIL f; UINT bw;
    if (f_open(&f, dst, FA_CREATE_ALWAYS | FA_WRITE) || f_write(&f, data, (UINT)len, &bw) || bw != len) { printf("write %s failed\n", dst); exit(2); }
    f_close(&f);
}
static size_t frame(uint8_t *p, const char *id, const char *text)
{
    size_t n = strlen(text) + 1;
    memcpy(p, id, 4);
    p[4] = (uint8_t)(n >> 24); p[5] = (uint8_t)(n >> 16); p[6] = (uint8_t)(n >> 8); p[7] = (uint8_t)n;
    p[8] = p[9] = 0;
    p[10] = 0;                              // ISO-8859-1
    memcpy(p + 11, text, n - 1);
    return 10 + n;
}
// the MP3 at b + 4096 (len bytes) with an ID3v2.3 tag in front
static void put_tagged(const char *dst, uint8_t *b, size_t len, const char *title, const char *artist)
{
    uint8_t tag[1024];
    size_t n = 10;
    if (!memcmp(b + 4096, "ID3", 3))         // the asset's own tag goes
    {
        size_t old = 10 + ((size_t)(b[4096 + 6] & 127) << 21 | (size_t)(b[4096 + 7] & 127) << 14 |
                           (size_t)(b[4096 + 8] & 127) << 7 | (b[4096 + 9] & 127));
        memmove(b + 4096, b + 4096 + old, len - old);
        len -= old;
    }
    n += frame(tag + n, "TIT2", title);
    n += frame(tag + n, "TPE1", artist);
    size_t body = n - 10;
    memcpy(tag, "ID3\x03\x00\x00", 6);
    tag[6] = (uint8_t)((body >> 21) & 127); tag[7] = (uint8_t)((body >> 14) & 127);
    tag[8] = (uint8_t)((body >> 7) & 127); tag[9] = (uint8_t)(body & 127);
    memcpy(b + 4096 - n, tag, n);
    put(dst, b + 4096 - n, len + n);
}

int main(int argc, char **argv)
{
    static FATFS fs;
    static BYTE work[4096];
    char p[512]; size_t len;
    if (argc < 3) { printf("usage: mkimg_picoamp out.img assets\n"); return 2; }
    remove(argv[1]);
    host_disk_open(argv[1], 32 * 2048);
    MKFS_PARM opt = { FM_FAT, 0, 0, 0, 0 };
    if (f_mkfs("0:", &opt, work, sizeof work)) { printf("mkfs failed\n"); return 2; }
    f_mount(&fs, "0:", 1);
    f_mkdir("0:/MUSIC");
    f_mkdir("0:/MUSIC/Albums with names that do not fit on one line of the list");
    f_mkdir("0:/MUSIC/Short");
    snprintf(p, sizeof p, "%s/cbr128_v23.mp3", argv[2]);
    uint8_t *b = slurp(p, &len);
    put_tagged("0:/MUSIC/01 A very long file name for the ticker test of PicoAmp.mp3", b, len,
               "A Title Much Longer Than Twenty-One Characters", "The Artist With A Long Name Too");
    put_tagged("0:/MUSIC/02 Short.mp3", b, len, "Short Title", "Artist");
    put_tagged("0:/MUSIC/Short/Tune.mp3", b, len, "Tune", "Someone");
    free(b);
    f_mount(NULL, "0:", 0);
    printf("made %s\n", argv[1]);
    return 0;
}
