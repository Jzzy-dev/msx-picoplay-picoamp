# PicoPlay: a SymbOS music player for the MSX PicoVerse 2350

LoadROM's `-p1` firmware gives the PicoVerse 2350 its own audio engine, the **PicoVerse Audio Engine**. The cartridge reads MP3, WAV and M3U files from its microSD card, decodes them and plays them through its I2S DAC. **PicoPlay** is the SymbOS program that browses the card and controls playback. **PVTEST.COM** checks the engine from the MSX-DOS / Nextor prompt.

> **Status:** confirmed on a Philips NMS 8245 with the PicoVerse 2350: Nextor boots, PVTEST plays folders, and PicoPlay under SymbOS 4.0 browses, plays, pauses, skips, shuffles, repeats and sets the volume. Internet radio (section 6) is new and tested only against a simulated ESP so far. Also tested in openMSX with a model of the engine, and with PC tests against the real engine code.

## Why this design

Earlier attempts streamed audio through the MSX (MP3MSX-style, with hiccups) or copied the SE-ONE's I/O-port protocol (SE Play). Both depend on the MSX bus keeping up:

- **No audio crosses the MSX bus.** The RP2350 reads the files from the microSD card itself and decodes them on core 1. The MSX only sends short commands and reads a status block, so a busy MSX can't cause hiccups.
- **Memory-mapped, not I/O ports.** The PicoVerse answers I/O reads without /WAIT, so a late answer reads as `FFh`. The engine instead sits in a memory window. Every memory access holds the Z80 with /WAIT until the RP2350 has answered, so no byte can be lost. The SymbOS network daemon reaches the Wi-Fi interface the same way, and that method is confirmed on hardware.
- **The MSX never waits blindly.** Commands are posted and checked later. Every wait gives the CPU back to SymbOS and has a time limit. A missing or stuck cartridge shows a message; it can't freeze SymbOS.
- **Diagnostics built in.** The engine keeps a heartbeat, the microSD mount result, FatFS error codes and a log. PicoPlay and PVTEST show them, so a problem on real hardware can be traced.

## 1. What you need

- A PicoVerse 2350 with a microSD card: MBR partition table, first primary partition FAT16. This is the same card Nextor and SymbOS use.
- An MSX2 or later. SymbOS 4.0 is installed on the card as in the [SymbOS guide](https://github.com/cristianoag/msx-picoverse-public/blob/main/docs/msx-picoverse-2350-symbos.md).
- `PICOPLAY.EXE` and `PVTEST.COM`, built from `picoplay/`.

## 2. Build and flash

```powershell
.\bin\loadrom.exe -p1 -w -o picoplay_wifi.uf2   # with the ESP-01 Wi-Fi
.\bin\loadrom.exe -p1 -o picoplay.uf2           # without Wi-Fi
```

The image holds Nextor 2.1.4 (Sunrise IDE on the microSD card), the 1 MB PSRAM mapper, the audio engine and, with `-w`, the Wi-Fi interface. The sub-slots are the same as in the `-m1 -w` SymbOS setup, with or without `-w`:

| Sub-slot | Contents |
| --- | --- |
| 0 | ESP8266 BIOS + memio UART (with `-w`, otherwise empty) |
| 1 | Nextor + Sunrise IDE |
| 2 | 1 MB mapper RAM |
| 3 | PicoVerse Audio Engine, window `4000h-4FFFh` |

The SymbOS disk driver stays on slot `P-1`, and the network daemon still finds Wi-Fi in `P-0`.

### PicoAmp ROM (no Nextor)

```powershell
.\bin\loadrom.exe -pa -w -o picoamp_wifi.uf2   # with the ESP-01 Wi-Fi
.\bin\loadrom.exe -pa -o picoamp.uf2           # without Wi-Fi
```

The MSX2 boots straight into PICOAMP: the player is a 32 KB cartridge ROM (two 16 KB banks: the program, its clock page) in sub-slot 0 and the engine is in sub-slot 3 (no Nextor, no mapper, no files needed besides the music). Q returns to the BIOS, which boots on to BASIC while the music keeps playing. F and D add and remove favourites here too: with no Nextor in this mode the engine writes `RADIOFAV.M3U` itself (engine 0.10). Integration notes for the Explorer: `docs/picoamp-explorer.md`.

## 3. Music on the card

Put the music anywhere on the first partition, for example `A:\MUSIC\`, with sub-folders and `.M3U` play lists.

- **Formats:** MP3 (MPEG-1/2/2.5 layer III, CBR and VBR) and PCM WAV (8/16-bit, mono/stereo, 8 to 48 kHz).
- **Tags:** title, artist and album from ID3v2.3, ID3v2.4 or ID3v1. Without a tag, the file name is shown. Accented letters are shown without their accents.
- **Length and seeking:** from the Xing/Info or VBRI header (VBR) or the bitrate (CBR).
- **Names:** long file names work, including non-ASCII ones; folders are opened by position, not by retyping the name. Lists are sorted with folders first. Hidden files, `._` files and other file types are left out.
- **M3U:** relative paths, absolute paths, and Windows paths such as `C:\Music\Song.mp3`. When the full path isn't found, the engine looks for the file name in the play list's folder. `http://` and `https://` lines are internet radio stations (see section 6), named by the `#EXTINF` line above them. Comments and empty lines are skipped.
- **Sizes:** up to 1024 entries per folder (PicoPlay shows them in pages of 120) and 512 tracks per play list.

## 4. PVTEST.COM (MSX-DOS / Nextor)

A quick check of the cartridge, without SymbOS:

```text
PVTEST                     find the engine, show diagnostics and the root folder
PVTEST /MUSIC              list a folder and play its tracks
PVTEST /MUSIC/SONG.MP3     play a file (or an .M3U play list)
PVTEST SONG.MP3            relative to the current folder (CD MUSIC first)
PVTEST A:\MUSIC\SONG.MP3   with a drive letter and backslashes
PVTEST http://host/stream  play an MP3 internet radio stream (needs -p1 -w)
```

For a stream the status line shows the time, the buffer fill (`B95%`), the receive rate in KB/s and the stream title. `Buf` means the buffer is still filling. A stream that fails shows `net error N HTTP H`, and `L` shows the engine log.

While playing: `SPACE` pause, `N` next, `P` previous, `S` stop, `+`/`-` volume, `L` engine log, `ESC` quit. After you quit, the music keeps playing: the cartridge plays it, not the MSX.

### PICOAMP.COM (MSX2, MSX-DOS)

A full-screen player in a Winamp/MUBScope style, with a 24-band spectrum analyser, peak dots, VU meters, an oscilloscope, an equalizer screen with sliders and balance, three full screen pictures (bars, mirror, plasma), a search of the station directory, favourites (the same RADIOFAV.M3U as PicoPlay), a help page, mouse support, 6-pixel text and long names that scroll like a news ticker. It needs an MSX2 and engine 0.8 or newer. `PICOAMP` or `PICOAMP /MUSIC`. Keys: cursor keys to browse, `Enter` play, `BS` parent folder, `SPACE` pause, `S` stop, `N`/`P` next/previous, `+`/`=`/`-` volume, `,`/`.` 10 seconds back/forward, `H` shuffle, `R` repeat, `V` spectrum/oscilloscope, `G` equalizer, `E` preset, `Z` full screen, `F`/`D` add/remove a favourite, `/` or `J` search, `?` help, `ESC` quit. Sources and details: `picoamp/README.md`.

## 5. PicoPlay (SymbOS)

Copy `PICOPLAY.EXE` to the SymbOS drive and start it from SymbOS.

- **Folders:** double-click a folder (`[name]`) to open it, and `[..]` to go up. Folders with more than 120 entries show `>> more entries` / `<< previous entries` rows. *File > Refresh folder* reads the folder again. The engine remembers the last folder, even after PicoPlay is closed.
- **Playing:** double-click a track (or select it and press Enter) to play it. The folder's tracks become the play list. Double-click an `.M3U` file to play it as a list.
- **Controls:** `|<` previous (restarts the track after 3 s), `Play`/`Pause`, `Stop`, `>|` next, *Shuffle*, *Repeat*, the volume slider, and a click on the progress bar to seek.
- **Keys:** `Up`/`Down` select (`Left`/`Right` a page), `Enter` open or play, `Backspace` parent folder, `SPACE` play/pause, `N` next, `P` previous, `S` stop, `+`/`-` volume, `D` diagnostics, `L` engine log.
- **Status:** the window shows title, artist and album, the time, format, bitrate and sample rate. The status bar shows the play list position or the latest problem in plain words.
- **Diagnostics:** *File > Diagnostics* shows the engine version, uptime, heartbeat, microSD mount result, volume type, play list and errors. *File > Engine log* shows the engine's last 32 log lines. *File > Remount microSD* mounts the card again.
- **Music keeps playing** when you close PicoPlay; start it again to take control.

PicoPlay finds the engine by scanning the slots for its signature. It accesses the cartridge with the same slot method as the PicoVerse network daemon: page 1 is switched briefly with interrupts off, in blocks of at most 128 bytes.

### Equalizer

*File > Equalizer...* (or `E`) opens a 5-band equalizer: 60 Hz, 250 Hz, 1 kHz, 4 kHz and 12 kHz, each from -12 to +12 dB, with the presets Flat, Rock, Pop, Jazz, Classic, Voice, Bass and Loudness (buttons, or the keys `1` to `8` in the equalizer window). Below the presets is the **balance** slider: moving it to one side turns the other channel down (the near side stays at full level), and near the middle it snaps to *Centre*. It works on files and streams alike.

- **Where it runs:** the DAC (UDA1334A) has no controls, so the engine filters the decoded sound itself before the volume: a low shelf (60 Hz), three peaking filters and a high shelf (12 kHz), in floating point on the RP2350 (a few percent of a core). With every band at 0 dB the filters are skipped.
- **No clipping:** the largest boost is taken off the whole signal first. Boosting the bass by 8 dB therefore makes everything else 8 dB quieter; turn the volume up to match.
- **Kept:** PicoPlay stores the setting in `PICOPLAY.CFG` next to `RADIOFAV.M3U` (`EQ=Rock,5,2,-2,3,5` and `BAL=50`) and sends it to the engine at start-up.
- **For developers:** command `EQ` (2Ah) takes five signed bytes (dB); status bytes 179-183 show the gains in use. `BALANCE` (2Bh) takes 0 (left only) to 100 (right only), 50 is the centre; status byte 184.

## 6. Internet radio

With a `-p1 -w` image the engine plays MP3 internet radio streams itself. The ESP-01 fetches the stream (WiFi, DNS, TCP and TLS run on the ESP), the engine decodes it, and the MSX only shows what is playing. The ESP must already know your access point (as for the Nextor WiFi tools).

- **Station lists:** put stations in an `.M3U` file on the card and open it in PicoPlay, or use `PVTEST http://...`:

  ```text
  #EXTM3U
  #EXTINF:-1,Radio Paradise
  http://stream.radioparadise.com/mp3-128
  #EXTINF:-1,SomaFM Groove Salad
  https://ice1.somafm.com/groovesalad-128-mp3
  ```

  `N` and `P` (or `>|` and `|<`) switch stations. `examples/RADIO.M3U` has a few to start with.
- **What plays:** MP3 streams over `http://` and `https://` (Icecast, Shoutcast). Redirects and `.pls` / `.m3u` station links are followed. AAC, Ogg and HLS (`.m3u8`) streams are refused with a clear message. Radio Browser (radio-browser.info) lists stations with their codec; pick ones marked MP3.
- **What you see:** the stream title (split into artist and title), the station name, the bitrate, and the buffer fill. The progress bar shows the buffer fill. The status bar shows the receive rate, or `connecting` / `reconnecting`.
- **Buffer:** 96 KB (6 s at 128 kbit/s). Playback starts after 24 KB. When the connection drops or the server stops sending for 10 s, the engine reconnects by itself while the buffer keeps playing. Pause keeps the connection and fills the buffer.
- **The WiFi link:** while a stream plays (and for a moment after Stop), the engine owns the ESP. The SymbOS network daemon and the Nextor WiFi tools cannot use it at the same time. Stop the stream first.
- **Far servers:** the ESP firmware's TCP receive window is about 2 KB, so a stream can arrive at no more than about 2 KB per round trip. Near servers (10-20 ms) easily give the 16 KB/s a 128 kbit/s stream needs. A server 180 ms away gives about 11.7 KB/s: the stream then plays with pauses while the buffer refills, and the status bar says `too slow: 11.7 of 16.0 KB/s`. Choose a closer server or a lower bitrate. The *open* time in Diagnostics is about one round trip.
- **Old connections:** the ESP keeps its connections when the MSX is reset (it has four, and only one can use TLS). When an open fails with "no free connection", the engine closes the leftovers and tries again.
- **HTTPS:** the ESP does TLS 1.2 with SNI, one TLS connection at a time. The certificate is not checked. The handshake takes one or two seconds.
- **Diagnostics:** *File > Diagnostics* shows the host, TLS, HTTP status, receive rate, buffer, reconnects, longest receive gap, underruns, DNS and open times, and ESP errors. These numbers are what to send back when a station does not play well.

### The station directory

With a `-p1 -w` image the card's root folder starts with **[Internet radio]**. It browses [Radio Browser](https://www.radio-browser.info), a free, community-run directory of tens of thousands of stations. The engine fetches each list over the ESP-01 itself, so PicoPlay stays responsive and a playing stream keeps playing.

| Folder | What it lists |
| --- | --- |
| Favourites | your own stations, from `RADIOFAV.M3U` in the root of the card |
| Top stations, Most voted, Trending now | the 60 most clicked, most voted and fastest rising MP3 stations |
| By country | every country with stations, with the number of stations; open one for its 60 most clicked MP3 stations |
| By genre | 50 genres (pop, rock, jazz, classical, house, schlager, news ...), each by Radio Browser tag |
| By decade | 1950s to 2010s and Oldies, by the tags `50s` ... `10s` and `oldies` |

- **Opening a list** takes a moment (Radio Browser sends about 1 KB per station; a list of 60 is about 60 KB, 4 to 6 s). The status bar says `Loading the station list...`; the list opens by itself when it is in. If you go elsewhere meanwhile, the fetch is dropped.
- **More stations:** a list shows 60 stations at a time. When there are more, its last row is **[More stations...]**: it fetches the next 60 and adds them to the list (the first new one is marked). Up to about 150 stations fit in one list.
- **Favourites:** `F` (or *File > Add to favourites*) adds the marked station, or the station that plays when no station is marked. In *Favourites*, `Del` (or *File > Remove from favourites*) removes the marked one. The favourites are an ordinary M3U file, `RADIOFAV.M3U` in the root of the drive PicoPlay was started from (the card), so you can also edit it on a PC or open it from the root folder. PicoPlay writes it through SymbOS; the engine only reads it. It holds up to 4 KB (about 40 stations).
- **Stations** show their bitrate in the size column. Enter or a double-click plays one; the list's stations become the play list, so `N` and `P` step through them. Shuffle works too.
- **Only MP3:** the lists ask for MP3 only and leave out HLS streams, stations whose last check failed and addresses longer than 255 characters.
- **Servers:** `all.api.radio-browser.info` over HTTP, then the mirrors `de1`, `de2`, `fi1`, `nl1` and `at1`. A list is complete when its JSON ends (the servers send big replies without a length and then close; the ESP does not report that close on a read, so the engine also asks the connection state with `TCP_STATE` after 0.4 s without data). A redirect to HTTPS is followed. Countries are fetched once per session and kept.
- **Listener counts:** when a station from the directory starts, the engine tells Radio Browser (`/json/url/<station>`), as its API asks. The requests say `User-Agent: PicoPlay/0.3 (MSX PicoVerse 2350)`.
- **One request at a time:** the ESP answers one request before it reads the next (a TLS handshake can take seconds). When the engine gives up waiting (a station changed during its TLS open), it still waits for that answer and drops it, and closes a connection that opened after all, so no answer is mistaken for another and no connection is left behind.
- **When it fails** the listing stays where it was and the status bar says why, for example `Station list: host not found` (no WiFi or DNS) or `Station list: connection refused`. Diagnostics has a `Radio list:` line, and the engine log shows each server tried.

## 7. Register window (for developers)

The engine is in page 1 of sub-slot 3, `4000h-4FFFh`. The full definition is `engine/pva_proto.h`.

| Address | Size | Contents |
| --- | --- | --- |
| `4000h` | 16 | `"PVAUDIO"`, 0, API version, firmware major, minor |
| `4010h` | 1 | command token (write the new token first) |
| `4011h` | 1 | command code (writing it posts the command) |
| `4012h` | 1 | token of the last finished command |
| `4013h` | 1 | result (`0` = OK) |
| `4014h` | 2 | reply length |
| `4016h` | 1 | heartbeat, +1 at least every 10 ms while the engine runs |
| `4020h` | 224 | status block; byte 0 is odd while it is being updated |
| `4100h` | 512 | command arguments |
| `4400h` | 2048 | command reply |
| `4C00h` | 256 | visualisation (engine 0.8): byte 0 sequence (odd while it changes), 1 band count (24), 2 top level (31), `4C04h` levels, `4C20h` peaks, `4C40h` VU left/right, `4C48h` 64 scope samples (signed), `4C90h` band centres in Hz (u16). About 50 updates a second, 2 dB a step |

Commands: `PING`, `MOUNT`, `LOG`, `DIAG`, `DIR_OPEN path`, `DIR_READ first,count`, `DIR_ENTER index`, `ENTRY_INFO index`, `DIR_SEARCH text`, `FAV_ADD index`, `FAV_DEL index`, `CFG_LOAD`, `CFG_GET key`, `CFG_SET key,value`, `CFG_SAVE`, `CFG_TEXT`, `CLOCK_INFO`, `LOC_IP`, `LOC_SEARCH text`, `LOC_LIST`, `LOC_PICK index`, `PLAY_INDEX index`, `PLAY_PATH path`, `PAUSE`, `STOP`, `NEXT`, `PREV`, `SEEK seconds`, `VOLUME 0-100`, `MODE repeat/shuffle`, `EQ g1..g5`, `BALANCE 0-100`, `PLAY_URL url,0,station,0` (also `PLAY_PATH` with a URL).

For streams the status block has the `STREAM` and `BUFFERING` flags, and from byte 162: network state, buffer fill in %, receive rate in 0.1 KB/s, reconnects, the last network error (`PVA_NERR_xxx`), the last HTTP status and the buffer size in KB. Results `9` (network) and `10` (no WiFi link) are new.

The station directory is a set of virtual folders. `DIR_ENTER` on a folder whose list must be fetched answers `11` (`PVA_E_BUSY`) and leaves the open folder as it was. Status byte 177 (`DIR_STATE`) is then `1` (loading), and later `2` (ready: the new list is the open folder, `DIR_GEN` changed, reopen it with `DIR_OPEN ""`) or `3` (failed, byte 178 has the `PVA_NERR_xxx` reason). `ENTRY_INFO index` (13h) replies with a station's address and name (index FFFFh: the stream that plays), for writing favourites. `DIR_SEARCH text` (14h, engine 0.9) asks for the stations whose name has the text and answers `11` as `DIR_ENTER` does; the list opens as `/Internet radio/Search/<text>`. `FAV_ADD index` (15h, engine 0.10; FFFFh = the stream that plays) and `FAV_DEL index` (16h, in Internet radio/Favourites) change `RADIOFAV.M3U` themselves, but only in the PicoAmp ROM mode, where no Nextor writes the card; elsewhere they answer `0D` (`PVA_E_RDONLY`). Add also answers `0C` (already a favourite) or `0E` (the file would pass 4 KB).

Settings and the clock (engine 0.11): `CFG_LOAD` (17h) reads `PICOAMP.INI` from the root of the card (no file: empty settings) and starts the clock; `CFG_GET "section.key"` (18h) replies the value (`04` when it is not set); `CFG_SET` (19h, args key 0 value 0) changes it in memory, keeping the rest of the text; `CFG_SAVE` (1Ah) writes the file where no one else writes the card (else `0D`, and the MSX writes the `CFG_TEXT` (1Bh) reply itself through MSX-DOS). The clock block at window offset `D00h` (32 bytes, a sequence byte first as the status block) has flags (1 time known, 2 zone known, 4 weather valid, 8 busy, 16 failed), the local second, minute, hour, weekday (0 = Monday), day, month, year (u16), the UTC offset in minutes (s16), the place search's state and count, a generation byte (+1 when the place, zone or weather changed), the WMO weather code, the temperature in 0.1 C (s16) and the zone's abbreviation (CET). The time comes from the Date header of every web reply; the place from ip-api.com (`location.mode=ip`) or a place found by name (`LOC_SEARCH` 32h, Open-Meteo geocoding, then `LOC_LIST` 33h and `LOC_PICK` 34h); the offset with summer time, the temperature and the weather code from Open-Meteo's forecast every 30 minutes. `CLOCK_INFO` (30h) replies the place, the zone and its abbreviation; `LOC_IP` (31h) goes back to the internet connection's place. Stations are entries of type `6` (`URL`) with the bitrate as their size; countries are folders with their station count as size. `PLAY_INDEX` on a station plays it with the list's stations as the play list. `DIR_OPEN "/Internet radio"` opens the directory's home.

If the heartbeat stops, `4018h` says what core 1 was doing (`PVA_W_xxx`) and `4019h` the last command. `401Ah` is `1` after a crash (HardFault, the program counter at `401Ch`) or `2` after a panic (its message at `4F00h`). PicoPlay shows this in the status bar instead of "no heartbeat".

To send a command, write the arguments, then a new token, then the code. On a later check, compare the done token with your token, then read the result and the reply. To read the status block, read byte 0, copy the block, and read byte 0 again; if it changed or is odd, copy again.

## 8. Sources and tests

- Engine: `engine/` (`pva_window.c` runs on core 0; `pva_engine.c`, `pva_decode.c`, `pva_net.c` (streams), `pva_dir.c` (Radio Browser), `pva_esp.c` (the ESP link, shared by the two) and `pva_hal_pico.c` run on core 1; the UART functions are in `loadrom.c`). LoadROM mode: `loadrom_sunrise_mapper_pva_sd()`, ROM type 22.
- Host test: `engine/tests`, `make run`. It builds a FAT16 image and drives the window as PicoPlay does. It covers folders, real-time playback with no underruns while browsing, tags, VBR, mono, WAV, seek, volume, shuffle, repeat, M3U and a removed card. `tests/host_esp.c` simulates the ESP-01 (its UNAPI protocol, UART speed, DNS and TLS delays) with test radio servers, for streams: ICY titles, pause, dropped connections, a stalled and a slow server, redirects, `.pls`, HTTPS, AAC, 404, unknown hosts, no WiFi, and switching stations. It also serves a small Radio Browser API (countries with UTF-8 names, stations with AAC, HLS, broken and over-long entries mixed in, a 150-station list, a mirror that sends `Content-Length`, servers that are down or slow), for the directory: lists, the filters, mirrors, failures, dropping a fetch, click counting, and fetching while a stream plays without underruns.
- PICOAMP: `picoamp/`, with `test/z80_picoamp.c` (a Z80 harness against the engine that also saves the screen).
- PicoPlay and PVTEST: `picoplay/` (SymbOS C Compiler and sjasmplus). `test/host_app.c` runs PicoPlay's logic against the engine. It covers browsing, paging, playing, seeking, the controls, diagnostics, the station directory (loading, opening by itself, bitrates, playing, failures), a stuck engine and a missing engine. `test/z80_pvtest.c` runs PVTEST.COM in a Z80 emulator.
- openMSX: `picoplay/emu/` has an openMSX device that runs the engine behind the window, plus an extension with the cartridge's slot layout, for testing PicoPlay under real SymbOS.

## 9. Next steps

- Internet radio on real hardware: receive rate, gaps and TLS times from Diagnostics.
- Station directory on real hardware: list times from the log.
- Search by name, and sorting a list from the File menu.
- AAC streams, if the RP2350 has the headroom.
