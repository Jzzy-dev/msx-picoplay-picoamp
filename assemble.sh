#!/bin/sh
# Put PicoPlay / PicoAmp into a checkout of the PicoVerse public repository, so the
# firmware, the LoadROM tool and all tests build there with their usual scripts.
#
#   ./assemble.sh [dir]          clone Cristiano's msx-picoverse-public into dir (default
#                                ./upstream) at the tested commit, apply firmware/*.patch and
#                                copy engine/, picoamp/, picoplay/ and devrig/ into it
#   ./assemble.sh --back [dir]   copy those four folders from dir back into this repository
#                                (after working on them in the assembled tree)
#
# UPSTREAM_REV=main ./assemble.sh   uses the newest upstream instead of the tested commit.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/cristianoag/msx-picoverse-public
REV=${UPSTREAM_REV:-d03ab8734a9e5584f1bf83382cfc96c53d9641a9}   # 2026-10-27, "PicoAmp"

# this repository's folder -> its place in the PicoVerse tree
MAP="engine:2350/software/loadrom.pio/pico/loadrom/pvaudio
picoamp:2350/software/msxdos-player
picoplay:2350/software/symbos/picoplay
devrig:2350/software/devrig"

copy() {    # copy <from> <to>: the folder's files, without build output
    mkdir -p "$2"
    (cd "$1" && find . -type f ! -path './obj/*' ! -name '*.o' ! -name '*.a') | while read -r f; do
        mkdir -p "$2/$(dirname "$f")"
        cp -p "$1/$f" "$2/$f"
    done
}

if [ "$1" = "--back" ]; then
    T=$(cd "${2:-$HERE/upstream}" && pwd)
    echo "$MAP" | while IFS=: read -r ours theirs; do
        copy "$T/$theirs" "$HERE/$ours"
        echo "$theirs -> $ours"
    done
    exit 0
fi

T=${1:-$HERE/upstream}
if [ ! -d "$T/.git" ]; then
    git init -q "$T"
    git -C "$T" remote add origin "$URL"
    echo "fetching $URL at $REV (one commit, no history)"
    git -C "$T" fetch -q --depth 1 origin "$REV"
    git -C "$T" checkout -q FETCH_HEAD
    git -C "$T" apply "$HERE"/firmware/*.patch
    echo "applied firmware/$(cd "$HERE/firmware" && ls *.patch)"
fi
T=$(cd "$T" && pwd)
echo "$MAP" | while IFS=: read -r ours theirs; do
    copy "$HERE/$ours" "$T/$theirs"
done
echo "assembled in $T"
echo "  firmware: cd $T/2350/software/loadrom.pio && make   (or cmake/ninja in pico/loadrom)"
echo "  PICOAMP:  sh $T/2350/software/msxdos-player/build.sh"
