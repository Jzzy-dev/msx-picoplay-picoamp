#!/bin/sh
# check-heap.sh <build dir>: the heap the firmware leaves (between the end of its static RAM and
# 0x20080000). At start the engine's I2S output takes about 2.3 KB of it (pico-extras' consumer
# pool), more goes to the C library (strtod, tzset); with too little, malloc() panics on core 1
# and the MSX says "The engine does not answer". 3 KB at least.
map="${1:-build}/loadrom.elf.map"
end=$(grep -E '^ +0x[0-9a-f]+ +__end__ = ' "$map" | awk '{print $1}')
[ -n "$end" ] || { echo "no __end__ in $map"; exit 2; }
heap=$(( 0x20080000 - end ))
echo "heap: $heap bytes"
[ "$heap" -ge 3072 ] || { echo "too little heap (3072 at least)"; exit 1; }
