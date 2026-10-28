// Runs PVTEST.COM (MSX-DOS) in a Z80 emulator against the real PicoVerse Audio
// Engine (host build). Emulated: BDOS console functions, BIOS RDSLT/WRSLT,
// EXPTBL with the PicoVerse in expanded slot 1 (engine in sub-slot 3), JIFFY
// and HALT at 60 Hz. Engine time follows the Z80 clock (3.58 MHz).
//
// usage: z80_pvtest PVTEST.COM image "args" "keys"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "z80.h"

#include <stdint.h>
#include <stdbool.h>
void pva_init(uint8_t *arena, size_t arena_size);
uint8_t pva_mem_read(uint16_t addr);
void pva_mem_write(uint16_t addr, uint8_t data);
void pva_core1_init(void);
bool pva_core1_poll(void);
int  host_disk_open(const char *path, uint32_t create_sectors);
void host_advance_ms(uint32_t ms);
extern bool host_audio_unlimited;
extern uint32_t host_audio_underruns, host_audio_frames;

static uint8_t mem[65536];
static z80 cpu;
static const char *keys;
static unsigned long next_ms_cyc, next_frame_cyc;
static char out[200000];
static size_t outn;
static unsigned long eng_reads;

#define CYC_MS 3580
static void sync_engine(void)
{
    while (cpu.cyc >= next_ms_cyc) { pva_core1_poll(); host_advance_ms(1); next_ms_cyc += CYC_MS; }
}

static uint8_t rd(void *u, uint16_t a) { (void)u; return mem[a]; }
static void wr(void *u, uint16_t a, uint8_t v) { (void)u; if (a >= 0x100) mem[a] = v; }
static uint8_t pin(z80 *z, uint8_t p) { (void)z; (void)p; return 0xFF; }
static void pout(z80 *z, uint8_t p, uint8_t v) { (void)z; (void)p; (void)v; }

static uint8_t slot_read(uint8_t slot, uint16_t a)
{
    // only slot 1-3 (81h | 3<<2 = 8Dh) has the engine; others: no hardware
    sync_engine();
    eng_reads++;
    if (slot == 0x8D) return pva_mem_read(a);
    return 0xFF;
}
static void slot_write(uint8_t slot, uint16_t a, uint8_t v)
{
    sync_engine();
    if (slot == 0x8D) pva_mem_write(a, v);
}

static void ret(void) { cpu.pc = mem[cpu.sp] | (mem[cpu.sp + 1] << 8); cpu.sp += 2; }
static void putch(char c) { if (outn < sizeof out - 1) out[outn++] = c; putchar(c); }

static int run(unsigned long max_cyc)
{
    while (cpu.cyc < max_cyc)
    {
        sync_engine();
        if (cpu.cyc >= next_frame_cyc)
        {
            next_frame_cyc += 3580000 / 60;
            uint16_t j = mem[0xFC9E] | (mem[0xFC9F] << 8);
            j++;
            mem[0xFC9E] = (uint8_t)j; mem[0xFC9F] = (uint8_t)(j >> 8);
            cpu.halted = false;
        }
        if (cpu.halted) { cpu.cyc += 4; continue; }
        switch (cpu.pc)
        {
            case 0x0000: return 0;                 // program ended (JP 0)
            case 0x0005:                           // BDOS
                switch (cpu.c)
                {
                    case 0x00: return 0;
                    case 0x02: putch((char)cpu.e); break;
                    case 0x09: { uint16_t p = (uint16_t)(cpu.d << 8 | cpu.e); while (mem[p] != '$') putch((char)mem[p++]); break; }
                    case 0x0B: cpu.a = (keys && *keys && cpu.cyc > 3580000UL * 2) ? 0xFF : 0; cpu.l = cpu.a; break;
                    case 0x08: case 0x01:
                        if (keys && *keys)
                        {
                            char k = *keys++;
                            if (k == '~') { /* wait marker: 1 s */ cpu.a = 0; unsigned long t = cpu.cyc + 3580000UL; while (cpu.cyc < t) { cpu.cyc += 1000; sync_engine(); } }
                            cpu.a = (uint8_t)k;
                        }
                        else cpu.a = 27;
                        cpu.l = cpu.a;
                        break;
                    default: printf("[BDOS %02X]\n", cpu.c);
                }
                ret();
                cpu.cyc += 200;
                continue;
            case 0x000C:                           // RDSLT A=slot HL=addr -> A
                cpu.a = slot_read(cpu.a, (uint16_t)(cpu.h << 8 | cpu.l));
                cpu.iff1 = cpu.iff2 = false;
                ret();
                cpu.cyc += 150;
                continue;
            case 0x0014:                           // WRSLT A=slot HL=addr E=value
                slot_write(cpu.a, (uint16_t)(cpu.h << 8 | cpu.l), cpu.e);
                cpu.iff1 = cpu.iff2 = false;
                ret();
                cpu.cyc += 150;
                continue;
        }
        z80_step(&cpu);
    }
    return 1;
}

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb");
    size_t n = fread(&mem[0x100], 1, 0xD000, f);
    fclose(f);
    printf("loaded %zu bytes\n", n);
    if (host_disk_open(argv[2], 0)) { printf("no image\n"); return 2; }
    {
        extern int host_esp_load_audio(const char *mp3_path);
        const char *sp = getenv("PVA_STREAM");          // MP3 the simulated ESP streams
        if (sp && host_esp_load_audio(sp)) { printf("no stream source %s\n", sp); return 2; }
    }
    static uint8_t arena[116 * 1024];
    host_audio_unlimited = false;
    pva_init(arena, sizeof arena);
    pva_core1_init();

    const char *a = argc > 3 ? argv[3] : "";
    keys = argc > 4 ? argv[4] : "";
    size_t al = strlen(a);
    mem[0x80] = (uint8_t)(al ? al + 1 : 0);
    mem[0x81] = ' ';
    memcpy(&mem[0x82], a, al);
    mem[0x82 + al] = 13;
    memset(&mem[0xFCC1], 0, 4);
    mem[0xFCC1 + 1] = 0x80;                        // slot 1 expanded
    mem[0xFCC1 + 3] = 0x80;
    mem[0x0000] = 0xC3;
    z80_init(&cpu);
    cpu.read_byte = rd; cpu.write_byte = wr; cpu.port_in = pin; cpu.port_out = pout;
    cpu.pc = 0x100;
    cpu.sp = 0xF000;
    mem[0xF000] = 0; mem[0xF001] = 0;               // return to 0000h
    next_ms_cyc = CYC_MS;
    next_frame_cyc = 3580000 / 60;
    int r = run(3580000UL * 120);
    printf("\n[%s after %.1f s, %lu engine reads, %u frames, %u underruns]\n", r ? "TIMEOUT" : "exit",
           cpu.cyc / 3580000.0, eng_reads, host_audio_frames, host_audio_underruns);
    return r;
}
