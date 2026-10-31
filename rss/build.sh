#!/bin/sh
# RSS.COM and RSS.ROM (sjasmplus on the PATH, or SJASMPLUS=/path/to/sjasmplus)
set -e
cd "$(dirname "$0")/src"
SJ=${SJASMPLUS:-sjasmplus}
python3 gen_cat.py feeds_cat.c cat.inc >/dev/null
$SJ --nologo --msg=war --raw=../RSS.COM rss.asm
$SJ --nologo --msg=war -DROMBUILD --raw=../RSS.ROM rss.asm
