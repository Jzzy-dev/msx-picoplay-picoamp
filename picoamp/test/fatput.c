// fatput.c - copy files into a card image (FAT, first partition) with FatFs:
//   fatput card.img /DST/NAME local-file [/DST/NAME2 local-file2 ...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "ff.h"

int host_disk_open(const char *path, uint32_t create_sectors);

int main(int argc, char **argv)
{
    static FATFS fs;
    if (argc < 4 || ((argc - 2) % 2 && strcmp(argv[2], "-cat"))) { printf("usage: fatput card.img /DST local ... | -cat /NAME\n"); return 2; }
    if (host_disk_open(argv[1], 0)) { printf("no image %s\n", argv[1]); return 2; }
    if (f_mount(&fs, "0:", 1)) { printf("no FAT\n"); return 2; }
    if (!strcmp(argv[2], "-cat"))               // fatput card.img -cat /NAME: print a file
    {
        FIL f; char b[512]; UINT n; char p[300];
        snprintf(p, sizeof p, "0:%s", argv[3]);
        if (f_open(&f, p, FA_READ)) { printf("no %s\n", p); return 1; }
        while (!f_read(&f, b, sizeof b, &n) && n) fwrite(b, 1, n, stdout);
        f_close(&f);
        return 0;
    }
    for (int i = 2; i + 1 < argc; i += 2)
    {
        FILE *in = fopen(argv[i + 1], "rb");
        if (!in) { printf("missing %s\n", argv[i + 1]); return 2; }
        char dst[300];
        snprintf(dst, sizeof dst, "0:%s", argv[i]);
        // make the folders on the way
        for (char *p = dst + 3; *p; p++)
            if (*p == '/') { *p = 0; f_mkdir(dst); *p = '/'; }
        FIL f; UINT bw;
        if (f_open(&f, dst, FA_CREATE_ALWAYS | FA_WRITE)) { printf("cannot write %s\n", dst); return 2; }
        char buf[8192]; size_t n;
        while ((n = fread(buf, 1, sizeof buf, in)) > 0)
            if (f_write(&f, buf, (UINT)n, &bw) || bw != n) { printf("write failed\n"); return 2; }
        f_close(&f);
        fclose(in);
        printf("%s\n", dst);
    }
    f_mount(NULL, "0:", 0);
    return 0;
}
