# Firmware changes

`loadrom-picoplay-picoamp.patch` holds our changes to Cristiano's LoadROM firmware and tool
(`2350/software/loadrom.pio` of [msx-picoverse-public](https://github.com/cristianoag/msx-picoverse-public)).
The engine itself is in `../engine/` (in the PicoVerse tree: `pico/loadrom/pvaudio/`); generated
files (`loadrom.bin`, `loadrom.exe`, `tool/src/loadrom.h`, `tool/src/picoamp_rom.h`) are left out
and made by the build.

What it changes:

* `pico/loadrom/loadrom.c`:
  * ROM type 22, `loadrom_sunrise_mapper_pva_sd()`: Nextor, the 1 MB mapper and the engine
    window (PicoPlay).
  * ROM type 23, `loadrom_picoamp()`: `PICOAMP.ROM` and the engine, no Nextor (PicoAmp);
    the ROM's 16 KB bank in page 1 is chosen at 6000h (as ASCII16).
  * The UART link to the ESP-01 for the engine (an IRQ ring), and core 1 running the engine.
  * The bus loop applies pending writes before it answers a read.
* `pico/loadrom/CMakeLists.txt`: the engine's sources, the MP3 allocator dispatch
  (`audio/mp3_alloc_dispatch.*`, so the engine and the existing MP3 player share picomp3lib),
  and the SE-ONE emulation (`seone/`).
* `audio/emu2413.*`: `emu2413_spare_ram()` lends the engine the tables' RAM (stream buffers) while MSX-MUSIC is off.
* `storage/sunrise_sd.*`: the Sunrise IDE card task split into `sunrise_sd_init()` / `sunrise_sd_poll()`, so core 1 runs it next to the engine.
* `tool/src/loadrom.c`: the `-p1` and `-pa` options, ROM types 22 and 23, `PICOAMP.ROM` embedded
  (16 to 64 KB).
* The LoadROM tool manual: the new options.

Made against PicoVerse release `msx-picoverse-20261018`; it also applies to commit `d03ab87`
(2026-10-27), which `../assemble.sh` uses. To make it again from a PicoVerse tree that has the
changes (base = the PicoVerse commit it started from):

```sh
git diff --binary <base> -- 2350/software/loadrom.pio docs/msx-picoverse-2350-loadrom-tool-manual.en-us.md \
  ':!2350/software/loadrom.pio/pico/loadrom/pvaudio' ':!*/dist/loadrom.bin' ':!*/dist/loadrom.exe' \
  ':!*/tool/src/loadrom.h' ':!*/tool/src/picoamp_rom.h' > loadrom-picoplay-picoamp.patch
```
