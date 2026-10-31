#!/bin/sh
# quick checks of RSS.COM / RSS.ROM in z80_rss (prints OK/FAIL lines)
cd "$(dirname "$0")"
export RSS_QUIET=1
ok() { if echo "$2" | grep -q -- "$3"; then echo "OK   $1"; else echo "FAIL $1"; fi; }
rm -f ini/*
o=$(./z80_rss ../RSS.COM fix ini "^" 8 /tmp/r.vram); ok "COM: BBC headlines (RSS 2.0, CDATA)" "$o" "Headlines 1-17/30"
o=$(./z80_rss ../RSS.COM fix ini "......2" 13 /tmp/r.vram); ok "Al Jazeera (https, entities)" "$o" "Al Jazeera story 1 & more 'quoted'"
o=$(./z80_rss ../RSS.COM fix ini "......3" 13 /tmp/r.vram); ok "DW (redirect, RDF)" "$o" "DW story 12"
o=$(./z80_rss ../RSS.COM fix ini "......5" 13 /tmp/r.vram); ok "NOS (Atom)" "$o" "NOS bericht 17"
o=$(./z80_rss ../RSS.COM fix ini "......4........^...^" 24 /tmp/r.vram); ok "Guardian: the article from content:encoded" "$o" "The full article .*1-18/41"
o=$(./z80_rss ../RSS.COM fix ini "^........^...^" 18 /tmp/r.vram); ok "BBC: the article from the page" "$o" "The full article .*1-18/99"
o=$(RSS_NOTLS=1 ./z80_rss ../RSS.COM fix ini "......2" 12 /tmp/r.vram); ok "no TLS: https-only feed" "$o" "it needs https"
o=$(RSS_NOTLS=1 ./z80_rss ../RSS.COM fix ini "......3" 12 /tmp/r.vram); ok "no TLS: http fallback" "$o" "DW story 12"
o=$(./z80_rss ../RSS.COM fix ini ".>^..}}^}^.<}D..J.." 18 /tmp/r.vram); ok "My feeds: remove, move, saved" "$(cat ini/RSS.INI)" "feeds=bbcw,guardw,dw,nos"
o=$(./z80_rss ../RSS.COM fix ini "" 8 /tmp/r.vram); ok "RSS.INI read back" "$o" "My feeds: 4 of 20" 
rm -f ini/*; printf 'proxy=proxy.lan:8088\r\n' > ini/RSS.INI
o=$(RSS_NOTLS=1 ./z80_rss ../RSS.COM fix ini "......2" 12 /tmp/r.vram); ok "no TLS: https by the proxy" "$o" "Al Jazeera story 17"
rm -f ini/*
for u in rom page3 map; do o=$(RSS_UNAPI=$u ./z80_rss ../RSS.ROM fix ini "^" 8 /tmp/r.vram); ok "ROM, UNAPI in $u" "$o" "Headlines 1-17/30"; done
o=$(./z80_rss ../RSS.ROM fix ini "........Q.Y" 14 /tmp/r.vram); ok "ROM: quit" "$o" "exit after"
o=$(RSS_MSX1=1 ./z80_rss ../RSS.COM fix ini "^" 8 /tmp/r.vram); ok "MSX1: 40 columns" "$o" "1-15/22"
o=$(RSS_NONET=1 ./z80_rss ../RSS.COM fix ini "" 4 /tmp/r.vram); ok "no network: My feeds and a word" "$o" "no TCP/IP UNAPI network"
o=$(./z80_rss ../RSS.COM fix ini "^" 8 /tmp/r.vram); ok "time zone from the clock chip" "$o" "08:59  Story number 1"
o=$(RSS_SLOWNET=2 ./z80_rss ../RSS.COM fix ini "" 1 /tmp/r.vram); ok "start screen: credits" "$o" "by JZZY & CLAUDE 2026"
o=$(./z80_rss ../RSS.COM fix ini "" 4 /tmp/r.vram); ok "starts in My feeds, credits there" "$o" "|                  by JZZY & CLAUDE 2026"
