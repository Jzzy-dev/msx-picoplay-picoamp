# PicoAmp in the PicoVerse 2350 Explorer – integration notes

This note is for adding **PicoAmp** (the MSX2 player with spectrum analyser,
internet radio, equalizer, ...) as an entry of the Explorer menu. It describes
what the entry has to set up on the RP2350; everything else is already
written and tested in LoadROM, where the same thing runs as ROM type 23
(`loadrom -pa [-w]`).

## What the entry is

Two parts, both included:

| Part | Where | What |
|------|-------|------|
| `PICOAMP.ROM` | `picoamp/` (built by `build.sh`) | a 16 KB MSX cartridge ROM ("AB" header, INIT at 4010h). Its INIT copies the program to RAM at 8000h and runs it there; it never needs MSX-DOS. Q returns from INIT, so the MSX goes on booting to BASIC (the music plays on). |
| The PicoVerse Audio Engine | `engine/` | runs on core 1: MP3/WAV from the microSD card, internet radio and the Radio Browser directory over the ESP-01, equalizer, spectrum/VU/scope data. The MSX talks to it through a 4 KB register window. |

No Nextor, no mapper, no ESP BIOS on the MSX side, and no files on the card
except the music and `RADIOFAV.M3U`, the favourites, which the engine reads
and writes itself in this mode (see "Favourites" below).

## The cartridge as the MSX sees it

One **expanded** slot (the sub-slot register at FFFFh, read back inverted):

| Sub-slot | Page 1 (4000h-7FFFh) | Other pages |
|----------|----------------------|-------------|
| 0 | `PICOAMP.ROM` (16 KB) | FFh |
| 1, 2 | FFh | FFh |
| 3 | engine window at 4000h-4FFFh (`"PVAUDIO"` at 4000h), FFh above | FFh |

* Every read in the slot is answered (`in_window = true`), also where nothing
  is (FFh): the slot is expanded, nobody else drives the bus in it.
* Writes: FFFFh sets the sub-slot register; page 1 of sub-slot 3 goes to
  `pva_mem_write(addr, data)`; everything else is ignored.
* Reads: FFFFh gives `~subslot_reg`; page 1 of sub-slot 0 the ROM byte;
  page 1 of sub-slot 3 `pva_mem_read(addr)`.
* **Apply all pending writes before answering a read.** The bus loop must
  drain the write FIFO again after it took the read address and before it
  computes the data. A sub-slot change at FFFFh followed at once by a read in
  that page is normal (the BIOS and PICOAMP's ENASLT/RDSLT do it all the
  time); answering that read with the old sub-slot made the MSX run the wrong
  bytes (random resets, "Syntax error", hangs). LoadROM had this bug in its
  Nextor + engine loop until 2026-10-27; it is described in the commit
  "Cartridge bus: apply writes before answering a read".
* No I/O ports are used.

The reference implementation is `loadrom_picoamp()` in
`loadrom.c` of the LoadROM firmware (`firmware/`) (about 90 lines), with
`core1_pva_task()` just above `loadrom_sunrise_mapper_pva_sd()`.

### Boot

As in the Sunrise modes: `sunrise_wait_for_expanded_bootstrap()` first (the
small bootstrap ROM that restarts the MSX, so the BIOS sees the expanded slot
from the start), then `/WAIT` held low while the ROM is copied into SRAM and
the engine is set up, then `msx_pio_bus_init()` and the loop. The BIOS then
finds PICOAMP's "AB" header in sub-slot 0 and calls its INIT; sub-slot 3 has
no header.

## What the engine needs from the firmware

### Code

* All of `engine/` except `pva_hal_pico.c`'s pin choices, which may need
  changing (below): `pva_window.c` (core 0: `pva_mem_read`/`pva_mem_write`,
  in RAM), `pva_engine.c`, `pva_decode.c`, `pva_net.c`, `pva_esp.c`,
  `pva_dir.c`, `pva_eq.c`, `pva_viz.c`, `pva_hal_pico.c`.
* The Helix MP3 decoder (`lib/picomp3lib`), with its allocator pointed at
  the engine (`buffers.c` built with `MPDEC_ALLOCATOR` and
  `audio/mp3_alloc_dispatch.h`, as in LoadROM's `CMakeLists.txt`). Explorer
  has its own MP3 player on the same library; the dispatch header lets both
  allocators live in one firmware.
* FatFs and the SPI SD driver (`no-OS-FatFS-SD-SDIO-SPI-RPi-Pico`), as
  Explorer already uses.
* `PICO_PANIC_FUNCTION=pva_panic` (optional: a panic message then appears
  in the window for the player's diagnostics).

### Entry points

| Call | Core | When |
|------|------|------|
| `pva_init(arena, size)` | 0 | before core 1 starts; `size` ≥ `PVA_ARENA_MIN_SIZE` (96 KB) |
| `pva_set_stack(stack, PVA_CORE1_STACK_SIZE)` | 0 | the core 1 stack (8 KB) for the crash notes |
| `pva_allow_card_writes(true)` | 0 | before core 1 starts: nobody else writes the card in this mode, so the engine may change `RADIOFAV.M3U` (FAV_ADD / FAV_DEL). Leave it off wherever Nextor runs |
| `pva_mem_read(addr)`, `pva_mem_write(addr, data)` | 0 | from the bus loop (both `__not_in_flash`) |
| `pva_command_pending()` | 1 | core 1 waits for the first command before it starts the engine, so a boot never depends on it |
| `pva_core1_init()`, then `pva_core1_poll()` in a loop | 1 | `sleep_us(50)` when it returns false (nothing to do), to leave the buses to core 0 |
| `sunrise_sd_init()` / `sunrise_sd_poll()` | 1 | as in `core1_pva_task()`; the engine itself reads the card through FatFs (`disk_*`) |

### The HAL (`pva_internal.h`)

| Function | LoadROM does | Note for Explorer |
|----------|--------------|-------------------|
| `pva_hal_audio_init/acquire/commit/mute` | `pva_hal_pico.c`: pico-extras `audio_i2s` on **PIO0 SM2** (`PICO_AUDIO_I2S_PIO=0`), data GPIO 29, BCLK 30, LRCLK 31, mute GPIO 32 (high = muted), 5 x 1152-frame buffers from the arena; the sample rate follows the file | Explorer's MP3 path uses PIO1 SM2; pick a PIO/SM that is free in the PicoAmp mode (nothing else runs then) |
| `pva_hal_millis` | `to_ms_since_boot` | |
| `pva_hal_net_present/open/close/read/write` | `loadrom.c`: UART1 on GPIO 38/39 at 859372 baud; the UART RX IRQ on core 0 fills a 4 KB ring the engine reads (`wifi_engine_owned`) | only when the entry has WiFi; with no ESP the engine simply has no internet radio |
| `pva_hal_stream_ram(&size)` | the emu2413 tables' 128 KB (MSX-MUSIC is off in this mode): 96 KB stream ring + spare for the station directory and the visualisation | any 128 KB that is free in this mode; PSRAM would do |
| `pva_hal_install_fault_handler` | writes a crash note into the window | optional |

### Memory in LoadROM's mode

| What | Size |
|------|------|
| ROM copy in SRAM (`rom_sram`) | 16 KB |
| core 1 stack | 8 KB |
| engine arena (the rest of the 256 KB `rom_sram` cache) | ~232 KB here; 96 KB is the minimum |
| stream RAM | 128 KB (emu2413 tables) |

## The MSX side, for reference

* `PICOAMP.ROM` finds the engine by `"PVAUDIO"` at 4000h in every slot and
  sub-slot, so it works wherever the cartridge is.
* It needs an MSX2 (SCREEN 4, the palette, sprites in mode 2) and 64 KB of
  RAM: the program at 8000h-B6xxh, its buffers up to about E400h, the stack
  of the BIOS above.
* Window protocol, status block and visualisation block:
  `engine/pva_proto.h` and `docs/picoplay.md` section 7.

## Testing

* LoadROM: `loadrom -pa -w -o picoamp_wifi.uf2` (the tool embeds
  `PICOAMP.ROM` from `tool/src/picoamp_rom.h`, which `picoamp/build.sh`
  writes).
* openMSX (no RP2350 needed): the PicoVerse Audio device in
  `picoplay/emu/` plus an extension with the ROM in sub-slot 0 and the
  device in sub-slot 3 - `picoplay/emu/PicoVerse_PicoAmp.xml`. Tested
  on the Philips NMS 8245 BIOS: boot into PICOAMP, browse, play, full screen,
  help, search typing, Q back to the BIOS. (openMSX's engine is 0.8, so the
  favourite keys say they need 0.10 there.)
* The Z80 harness `picoamp/test/z80_picoamp.c` runs `PICOAMP.COM` or
  `PICOAMP.ROM` (by the file's extension) against the host engine; for the
  ROM it calls `pva_allow_card_writes(true)` as the firmware does.
  `PICOAMP_TRACE=1` prints every engine command and its result.

## Favourites

The favourites are `RADIOFAV.M3U` in the root of the card, the same file
PicoPlay (SymbOS) and `PICOAMP.COM` (MSX-DOS) write. The engine builds
Internet radio/Favourites from it.

In the ROM version F (add the chosen station, or the one that plays) and D /
DEL (remove the chosen one, in Internet radio/Favourites) are engine commands
(engine 0.10):

| Command | Args | Result |
|---------|------|--------|
| `FAV_ADD` 15h | u16 entry of the open list, FFFFh = the stream that plays | OK (reply: the name), `E_EXISTS` 0Ch, `E_FULL` 0Eh (the file would pass 4 KB), `E_RDONLY` 0Dh |
| `FAV_DEL` 16h | u16 entry of Internet radio/Favourites | OK (the folder is read again), `E_NOTFOUND`, `E_RDONLY` |

* The engine only writes when the firmware called
  `pva_allow_card_writes(true)`; else it answers `E_RDONLY` and the ROM says
  "Favourites: MSX-DOS writes the card here". So Nextor (whose FAT cache
  would not know of the change) and the engine never write the card at the
  same time. Under MSX-DOS, `PICOAMP.COM` keeps writing the file through
  Nextor.
* The file is changed in place (appended to, or the rest moved down over the
  removed lines and the file cut), through the engine's M3U file handle and
  its 512-byte line buffer: no extra memory.
* An older engine answers `E_UNKNOWN`; the ROM then says "Favourites: needs
  engine 0.10 or newer".
* Tests: the "[favourites by the engine]" section of
  `engine/tests/host_pva.c` (add, again, the file's bytes, remove, a file
  of PicoPlay's without a line end at its end, the middle one removed, a full
  file); the Z80 harness runs PICOAMP.ROM with card writes on.
