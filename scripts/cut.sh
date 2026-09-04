#!/bin/sh
# Cut the dead spans out of a rendered terminal clip.
#
#   scripts/cut.sh IN.mp4 OUT.mp4 START-END [START-END ...]
#
# Each argument is a span to KEEP, in seconds. Everything between them is
# dropped with a hard cut, which is invisible as long as both sides of the
# cut are frozen frames -- so choose the boundaries from freezedetect:
#
#   ffmpeg -i IN.mp4 -vf freezedetect=n=0.0005:d=0.7 -map 0:v -f null - 2>&1 \
#     | grep -E 'freeze_(start|end)'
#
# Cut rather than speed-ramp. A ramp that spans both the wait and the hold
# after it flashes the output past before it can be read; a cut removes the
# wait and leaves the hold at normal speed.
set -e
IN=$1; OUT=$2; shift 2
n=0; F=""; C=""
for span in "$@"; do
  s=${span%-*}; e=${span#*-}
  F="$F[0:v]trim=start=$s:end=$e,setpts=PTS-STARTPTS[v$n];"
  C="$C[v$n]"
  n=$((n+1))
done
ffmpeg -y -loglevel error -i "$IN" -filter_complex "$F${C}concat=n=$n:v=1:a=0[out]" \
  -map "[out]" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$OUT"
echo "wrote $OUT ($n segments: $*)"
