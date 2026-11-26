#!/bin/sh
# make_assets.sh [dir]: the test's sounds (ffmpeg); the pictures (art.jpg, logo.jpg, logo.png,
# pic_*.jpg) are not made here. Then: ./host_pva <dir>
set -e
D=${1:-assets}
mkdir -p "$D"
cd "$D"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=20:sample_rate=44100" -ac 2 -c:a libmp3lame -b:a 128k \
       -id3v2_version 3 -metadata title="Sine Cafe Song" -metadata artist="Unit Tester" -metadata album="PicoVerse Tests" cbr128_v23.mp3
ffmpeg -v error -y -f lavfi -i "sine=frequency=660:duration=15:sample_rate=48000" -ac 2 -c:a libmp3lame -q:a 6 \
       -id3v2_version 4 -metadata title="VBR Four" vbr_v24.mp3
ffmpeg -v error -y -f lavfi -i "sine=frequency=330:duration=6:sample_rate=22050" -ac 1 -c:a libmp3lame -b:a 64k -id3v2_version 0 mono22_v1.mp3
python3 -c "
t = b'TAG' + b'Mono V1'.ljust(30, b'\0') + bytes(60) + b'2026' + bytes(30) + b'\xff'
open('mono22_v1.mp3', 'ab').write(t)"                  # an ID3v1 tag only
ffmpeg -v error -y -f lavfi -i "sine=frequency=550:duration=5:sample_rate=44100" -ac 2 -c:a pcm_s16le -fflags +bitexact -map_metadata -1 tone.wav
ffmpeg -v error -y -f lavfi -i "sine=frequency=880:duration=240:sample_rate=44100" -ac 2 -c:a libmp3lame -b:a 192k \
       -id3v2_version 3 -metadata title="Long One" long192.mp3
ls -l
