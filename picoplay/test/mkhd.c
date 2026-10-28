// mkhd - build a FAT16 MBR disk image like a Nextor microSD card and copy
// files into it.   mkhd <image> <MB> [<dest path> <host file>]...
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ff.h"
int host_disk_open(const char *path, uint32_t create_sectors);
static void mkdirs(const char *p)
{
    char t[300]; strcpy(t, p);
    for (char *s = t + 3; *s; s++) if (*s == '/') { *s = 0; f_mkdir(t); *s = '/'; }
}
int main(int argc, char **argv)
{
    static FATFS fs; static BYTE work[4096];
    host_disk_open(argv[1], (uint32_t)atoi(argv[2]) * 2048);
    MKFS_PARM opt = { FM_FAT, 0, 0, 0, 0 };
    if (f_mkfs("0:", &opt, work, sizeof work)) { printf("mkfs failed\n"); return 2; }
    f_mount(&fs, "0:", 1);
    for (int i = 3; i + 1 < argc; i += 2)
    {
        char dst[300]; snprintf(dst, sizeof dst, "0:%s", argv[i]);
        mkdirs(dst);
        FILE *f = fopen(argv[i + 1], "rb");
        if (!f) { printf("missing %s\n", argv[i + 1]); return 2; }
        FIL o; UINT bw; char buf[16384]; size_t n;
        if (f_open(&o, dst, FA_CREATE_ALWAYS | FA_WRITE)) { printf("create %s failed\n", dst); return 2; }
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) f_write(&o, buf, (UINT)n, &bw);
        f_close(&o); fclose(f);
    }
    f_mount(NULL, "0:", 0);
    return 0;
}
