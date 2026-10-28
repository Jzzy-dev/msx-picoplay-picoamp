# PicoVerse 2350 development rig

A headless test bench for the PicoVerse 2350 player work: **openMSX 19.1** emulating a
**Philips NMS 8245** with the cartridge's slot layout (Nextor Sunrise IDE in sub-slot 1, 1 MB
mapper in 2, the PicoVerse Audio Engine in 3), **SymbOS 4.0** on the IDE disk, and the tools to
build and test PicoPlay and PVTEST. Everything is driven from scripts and checked with
screenshots, so it runs on a server without a screen.

What the emulated cartridge does:

- **Engine:** the real engine code (`pvaudio/pva_*.c`) compiled for the PC, behind the same
  register window as on the RP2350. It plays the disk image's MP3/WAV files in real time and
  writes the audio to `out.wav`.
- **ESP-01:** a simulated ESP (`pvaudio/tests/host_esp.c`) that speaks the UNAPI ESP8266
  protocol with the UART speed and DNS/TLS delays of the real one. It serves test radio stations
  (`radio.test`, `radio2.test:8000`, `https://secure.test`) made from `assets/cbr128_v23.mp3`. It also answers
  as a small Radio Browser API (`all.api`, `de1.api`, `nl1.api.radio-browser.info`) for the
  station directory; its stations point at the test radio stations.

**In this repository** the rig works in the PicoVerse tree that `../assemble.sh` makes: run
it from `upstream/2350/software/devrig` (paths below are relative to that tree).

## Layout

| Folder | What |
| --- | --- |
| `setup.sh` | restore the private bundle, build from source, or relink after engine changes |
| `tools/drive.py` | run openMSX with key presses and screenshots |
| `tools/fatput.py` | put a file into a FAT16 disk image |
| `tools/prof.py` | where the Z80's time goes (from `PCSAMPLE` runs) |
| `templates/` | the openMSX extension, filled in per work folder |
| `patches/` | the openMSX patch that adds the `PicoVerseAudio` device |
| `prefix/`, `openMSX/`, `scc/`, `z80/`, `pva/` | built or restored, not in git |
| `omsx-user/`, `images/`, `inputs/`, `assets/` | private (ROMs, disk image), not in git |

The device itself is `2350/software/symbos/picoplay/emu/PicoVerseAudio.*`, the engine library
build `.../emu/build.sh`.

## Getting it back in a new session

The quick way: keep the private bundle (`picoverse-devrig-private.tar.xz`, about 19 MB) and
attach it to the session.

```sh
cd 2350/software/devrig
sh setup.sh restore /path/to/picoverse-devrig-private.tar.xz
sh setup.sh engine          # only if the engine (pva_*.c) changed since the bundle was made
```

The bundle has the built binaries (Linux x86-64), the NMS 8245 ROMs, Nextor, the SymbOS disk
image, the test audio, and the original NEXTOR.SYS, COMMAND2.COM and SymbOS 4.0 zip.

The slow way, from source (about 20 minutes): `sh setup.sh build`. It builds SDL2 2.30.9,
SDL_ttf 2.22.0, Tcl 8.6.14, openMSX 19.1 with the device, the SymbOS C compiler, sjasmplus and
the Z80 core. The ROMs, the disk image and the test audio then still have to come from the bundle
(or from your own files: the NMS 8245 ROMs go in `omsx-user/share/systemroms/nms8245/`, the Nextor
Sunrise ROM in `omsx-user/share/systemroms/`).

**Private:** the bundle holds copyrighted system ROMs. Keep it out of public repositories.

## Using it

```sh
cd 2350/software/devrig
mkdir -p work && cp images/hd_symbos_base.dsk work/hd.dsk && cd work
../tools/drive.py 90 30 'CD MUSIC\r' '\PVTEST http://radio.test/stream.mp3\r' '@20' ''
```

The machine needs about 60 s of emulated time to reach the Nextor prompt, so the first key comes
at 90 s. Emulation runs unthrottled (a minute of MSX time takes a few seconds). Screenshot `i`
(`shot_i.png`) is taken just before key `i+1`; `drv.err` has openMSX's output.

- **SymbOS:** `'CD SYMBOS\r' 'SYM\r' '' '{C}' '{D6}' '{N}' 'A:\SYMBOS\PICOPLAY.EXE' '@12' '{N}'`
  boots SymbOS, opens Start > Run and starts PicoPlay (the window is up about 10 s later).
  `{B26}` clears the Run box first if it remembers an older path.
- **New programs:** `../tools/fatput.py hd.dsk SYMBOS/PICOPLAY.EXE ../../symbos/picoplay/PICOPLAY.EXE`
  (or any `DIR/NAME.EXT`).
- **Several runs at once:** use one work folder per run; each gets its own extension.
- **CPU load:** the SymbOS CPU meter is not reliable for loads tied to the timer. Sample the Z80
  instead: `PCSAMPLE=300,8000 ../tools/drive.py ...` writes `pcs.txt`, then
  `../tools/prof.py <app>.EXE.map <app>.EXE pcs.txt <load offset> 20` prints idle, system and
  per-function shares. Build the program with `cc -M` for the map; PicoPlay's load offset under
  this SymbOS setup was 11776 (prof.py's matching of the code bytes tells you when it is wrong).
- **Engine trace:** `PVA_TRACE=1` prints the engine status every emulated second into `drv.err`.
- **RAM dump:** `DUMPRAM=1` writes the 1 MB mapper to `ram.bin` at the end, for finding a
  program's variables by a marker string.

## Tests that need no emulator

- Engine: `2350/software/loadrom.pio/pico/loadrom/pvaudio/tests`, `make` and run `host_pva
  <assets>` (assets = `devrig/assets`). Covers files, M3U and internet radio against the
  simulated ESP.
- PicoPlay's logic: `picoplay/test/host_app <app.dsk> [stream.mp3]` (`images/app.dsk`).
- PVTEST in a Z80 emulator: `PVA_STREAM=<mp3> picoplay/test/z80_pvtest PVTEST.COM <image> "<args>" "<keys>"`.
