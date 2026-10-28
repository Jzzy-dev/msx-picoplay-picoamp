#!/bin/sh
# PicoVerse 2350 development rig: openMSX (Philips NMS 8245 + the cartridge's slot layout with a
# model of the PicoVerse Audio Engine and a simulated ESP-01), SymbOS 4.0, the SymbOS C compiler,
# sjasmplus and the Z80 core for the PVTEST harness.
#
#   setup.sh restore <bundle.tar.xz>   unpack the private bundle (prebuilt, ROMs, disk image)
#   setup.sh build                     build everything from source (about 20 minutes)
#   setup.sh engine                    rebuild the engine library and relink openMSX
#                                      (after changing pva_*.c)
#
# RIG (default: this folder) is where everything goes. The repository is found from this
# script's location. Needs: git, gcc/g++ (C++20), make, python3 with Pillow, xz, the
# freetype2/libpng development headers.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
RIG=${RIG:-$HERE}
REPO=$(cd "$HERE/../../.." && pwd)                      # msx-picoverse checkout
PICOPLAY=$REPO/2350/software/symbos/picoplay
PREFIX=$RIG/prefix
JOBS=${JOBS:-$(nproc)}
mkdir -p "$RIG/src"

clone() {   # clone <url> <tag> <dir>
    [ -d "$3/.git" ] || git clone -q --depth 1 -b "$2" "$1" "$3"
}

engine() {
    mkdir -p "$RIG/pva" && cd "$RIG/pva" && sh "$PICOPLAY/emu/build.sh"
    cd "$RIG/openMSX"
    rm -f derived/x86_64-linux-opt/bin/openmsx
    PATH=$PREFIX/bin:$PATH PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig TCL_CONFIG=$PREFIX/lib \
        make -j"$JOBS" LDFLAGS="$RIG/pva/libpva_host.a" >/dev/null
    echo "openMSX relinked with the current engine"
}

case "$1" in
restore)
    [ -f "$2" ] || { echo "usage: setup.sh restore <bundle.tar.xz>"; exit 1; }
    tar -xJf "$2" -C "$RIG"
    echo "restored into $RIG"
    ;;
build)
    S=$RIG/src
    clone https://github.com/libsdl-org/SDL release-2.30.9 "$S/SDL2"
    clone https://github.com/libsdl-org/SDL_ttf release-2.22.0 "$S/SDL_ttf"
    clone https://github.com/tcltk/tcl core-8-6-14 "$S/tcl"
    clone https://github.com/openMSX/openMSX RELEASE_19_1 "$RIG/openMSX"
    clone https://github.com/danielgaskell/scc main "$RIG/scc"
    clone https://github.com/z00m128/sjasmplus master "$S/sjasmplus"
    clone https://github.com/superzazu/z80 master "$RIG/z80"
    (cd "$S/SDL2" && ./configure -q --prefix="$PREFIX" && make -j"$JOBS" >/dev/null && make install >/dev/null)
    (cd "$S/SDL_ttf" && ./configure -q --prefix="$PREFIX" --with-sdl-prefix="$PREFIX" --disable-freetype-builtin --disable-harfbuzz && make -j"$JOBS" >/dev/null && make install >/dev/null)
    (cd "$S/tcl/unix" && ./configure -q --prefix="$PREFIX" && make -j"$JOBS" >/dev/null && make install >/dev/null)
    (cd "$S/sjasmplus" && git submodule -q update --init --depth 1 && make -j"$JOBS" >/dev/null && cp sjasmplus "$PREFIX/bin/")
    (cd "$RIG/scc/src" && sh ./makelinux.sh >/dev/null)
    # openMSX with the PicoVerseAudio device
    cd "$RIG/openMSX"
    git apply --check "$HERE/patches/openmsx-19.1-picoverse.patch" 2>/dev/null && git apply "$HERE/patches/openmsx-19.1-picoverse.patch"
    mkdir -p src/picoverse
    cp "$PICOPLAY/emu/PicoVerseAudio.cc" "$PICOPLAY/emu/PicoVerseAudio.hh" src/picoverse/
    engine
    mkdir -p "$RIG/omsx-user/share/systemroms" "$RIG/assets"
    echo
    echo "Built. Still needed (not public, see README.md): the NMS 8245 system ROMs in"
    echo "  $RIG/omsx-user/share/systemroms/nms8245/, the Nextor Sunrise ROM in .../systemroms/,"
    echo "  a SymbOS disk image (hd_symbos_base.dsk) and test audio in $RIG/assets/."
    ;;
engine)
    engine
    ;;
*)
    sed -n '2,14p' "$0"
    exit 1
    ;;
esac
