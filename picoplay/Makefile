# PicoPlay (SymbOS) and PVTEST.COM (MSX-DOS)
#   make SCC=<SymbOS C Compiler bin dir> SJASMPLUS=<sjasmplus>        PICOPLAY.EXE, PVTEST.COM
#   make test FATFS=... MP3=... (see test targets)                   PC tests against the engine
SCC       ?= scc/bin
SJASMPLUS ?= sjasmplus
# the engine: in a PicoVerse tree (assemble.sh), else this repository's engine/
ENGINE    ?= $(firstword $(wildcard ../../loadrom.pio/pico/loadrom/pvaudio) ../engine)
LIBPVA    ?= libpva_host.a
FATFS     ?= $(ENGINE)/../lib/no-OS-FatFS-SD-SDIO-SPI-RPi-Pico/src

all: PICOPLAY.EXE PVTEST.COM

PICOPLAY.EXE: pvplay.c pvgui.h pvwin.s $(ENGINE)/pva_proto.h
	$(SCC)/cc -N PicoPlay -I $(ENGINE) pvplay.c pvwin.s -o $@

PVTEST.COM: pvtest.asm
	$(SJASMPLUS) --nologo --msg=war --raw=$@ pvtest.asm

# PC tests: PicoPlay's logic and PVTEST.COM (Z80) against the engine host build.
# Build $(LIBPVA) with emu/build.sh first; Z80DIR = superzazu/z80.
Z80DIR ?= z80
test/host_app: test/host_app.c test/host_symbos.h test/host_gui.h pvplay.c
	$(CC) -O1 -g -w -DPV_HOST_TEST -I. -I$(ENGINE) -I$(ENGINE)/tests/hostinc -I$(FATFS)/include -I$(FATFS)/ff15/source -o $@ test/host_app.c $(LIBPVA) -lm
test/z80_pvtest: test/z80_pvtest.c
	$(CC) -O2 -w -I$(Z80DIR) -o $@ test/z80_pvtest.c $(Z80DIR)/z80.c $(LIBPVA) -lm

clean:
	rm -f PICOPLAY.EXE PVTEST.COM *.o *.rel test/host_app test/z80_pvtest
