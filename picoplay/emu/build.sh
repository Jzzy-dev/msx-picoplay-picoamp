#!/bin/sh
# Build libpva_host.a: the PicoVerse Audio Engine host build for the openMSX test device.
set -e
# run from any folder; the library is written there
L=$(cd "$(dirname "$0")/../../../loadrom.pio/pico/loadrom" && pwd)
F=$L/lib/no-OS-FatFS-SD-SDIO-SPI-RPi-Pico/src
M=$L/lib/picomp3lib/src
T=$L/pvaudio/tests
mkdir -p obj
CF="-O2 -g -DPVA_HOST -I$L/pvaudio -I$T/hostinc -I$F/include -I$F/ff15/source -I$M -w"
for f in $L/pvaudio/pva_window.c $L/pvaudio/pva_engine.c $L/pvaudio/pva_decode.c $L/pvaudio/pva_net.c $L/pvaudio/pva_esp.c $L/pvaudio/pva_dir.c $L/pvaudio/pva_eq.c $L/pvaudio/pva_viz.c $L/pvaudio/pva_json.c $L/pvaudio/pva_web.c $L/pvaudio/pva_cfg.c $L/pvaudio/pva_clock.c $L/pvaudio/pva_news.c $L/pvaudio/pva_news_cat.c \
         $T/host_hal.c $T/host_esp.c \
         $F/ff15/source/ff.c $F/ff15/source/ffunicode.c $F/ff15/source/ffsystem.c $(ls $M/*.c | grep -v buffers.c); do
  gcc $CF -c $f -o obj/$(basename $f .c).o
done
gcc $CF -DMPDEC_ALLOCATOR=pva_mp3_alloc -include $L/pvaudio/pva_mp3_alloc.h -c $M/buffers.c -o obj/buffers.o
rm -f libpva_host.a
ar rcs libpva_host.a obj/*.o
echo built libpva_host.a
