#!/bin/sh
# scripts/tape-rows.sh FRAME.png [COL_MODE]
#
# Report the y centre and the arrow tip y of every text row in a rendered
# frame, and with a second argument the x extent of the text. Measure marks
# off this rather than computing them from the font size: VHS adds top margin
# beyond Set Padding, so a computed centre lands roughly half a row high.
#
# Use the "tip" column, not the centre. The sprite points up and to the left
# from its tip, so a tip on the centre of a row puts the arrowhead over the
# glyphs it is meant to indicate and reads as too high. Six pixels below the
# glyph bottom sits the head in the gap under the row, pointing back up at it.
set -e
F=$1
ffmpeg -v error -i "$F" -vf "scale=1:1080:flags=area,format=gray" -f rawvideo - \
  | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$' \
  | awk '{v=$1+0; y=NR-1;
      if(v>2){if(s=="")s=y; e=y}
      else {if(s!=""){printf "row %d: y %d..%d  centre %d  tip %d\n", n++, s, e, (s+e)/2, e+6; s=""}}}
    END{if(s!="")printf "row %d: y %d..%d  centre %d  tip %d\n", n, s, e, (s+e)/2, e+6}'
if [ -n "$2" ]; then
  echo "--- x extent per row ---"
  ffmpeg -v error -i "$F" -vf "scale=1920:1:flags=area,format=gray" -f rawvideo - \
    | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$' \
    | awk '{v=$1+0; x=NR-1; if(v>1){last=x; if(first=="")first=x}} END{printf "text spans x %d..%d\n", first, last}'
fi
