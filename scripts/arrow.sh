#!/bin/sh
# Draw an animated pointer onto a rendered terminal clip.
#
# The clip's own output is often the full width of the frame, so a mark that has
# to sit beside the text has nowhere to go. This one comes out of the empty
# space below instead: a sprite that slides in along its own axis toward the
# target, then holds with a slow pulse so it stays alive through a long hold.
#
# Usage:
#   scripts/arrow.sh IN.mp4 OUT.mp4 TIP_X TIP_Y CUE_SECONDS [ANGLE_DEG] [END_SECONDS]
#
# END_SECONDS makes the arrow transient. Leave it off and the arrow stays to the
# end of the clip, which is right when one mark carries the whole shot. Set it
# when the narration walks several things in turn: the viewer should be looking
# at one pointer at a time, not at an accumulating pile of them.
#
# TIP_X,TIP_Y is where the point lands, measured off a rendered frame rather
# than computed from the font size. ANGLE_DEG is the direction the arrow travels
# as it comes in, measured clockwise from east; the default of 135 brings it up
# and to the left from the lower right.
#
# Cue against the *unmarked* clip, or the scene detector finds the mark instead
# of the output:
#   ffmpeg -i IN.mp4 -vf "select='gt(scene,0.02)',showinfo" -f null - 2>&1 \
#     | grep -oE 'pts_time:[0-9.]+'
set -e

IN=$1; OUT=$2; TIPX=$3; TIPY=$4; CUE=$5; ANGLE=${6:-135}; END=${7:-}

COLOR='#ffe100'
SLIDE=0.35      # seconds for the slide-in
TRAVEL=100      # pixels the sprite travels on the way in
PULSE_PX=6      # amplitude of the settled pulse
PULSE_RATE=6    # radians per second

SPRITE=$(dirname "$OUT")/.arrow-sprite.png

# Geometry of the sprite, in its own 170x170 canvas. Tip near the top-left
# corner so the body trails down and to the right of whatever it points at.
magick -size 170x170 xc:none \
  -stroke "$COLOR" -strokewidth 16 -draw "line 142,138 57,56" \
  -fill "$COLOR" -stroke none -draw "polygon 12,12 79,30 31,78" \
  "$SPRITE"

# Settled top-left of the sprite, so its tip sits on the target.
BASEX=$(echo "$TIPX - 12" | bc)
BASEY=$(echo "$TIPY - 12" | bc)

# Unit vector the sprite travels along, from the entry angle.
DX=$(echo "scale=4; c($ANGLE * 3.14159265 / 180)" | bc -l)
DY=$(echo "scale=4; s($ANGLE * 3.14159265 / 180)" | bc -l)
OFFX=$(echo "scale=2; -1 * $TRAVEL * $DX" | bc -l)
OFFY=$(echo "scale=2; -1 * $TRAVEL * $DY" | bc -l)

P="min(1\,max(0\,(t-$CUE)/$SLIDE))"
WOBBLE="$PULSE_PX*sin($PULSE_RATE*(t-$CUE))*$P"

if [ -n "$END" ]; then WINDOW="between(t,$CUE,$END)"; else WINDOW="gte(t,$CUE)"; fi

ffmpeg -y -loglevel error -i "$IN" -i "$SPRITE" -filter_complex \
  "[0][1]overlay=x='$BASEX+($OFFX)*(1-$P)+$WOBBLE':y='$BASEY+($OFFY)*(1-$P)+$WOBBLE':enable='$WINDOW'" \
  -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$OUT"

rm -f "$SPRITE"
echo "wrote $OUT (tip $TIPX,$TIPY, cue ${CUE}s${END:+ to ${END}s}, entry ${ANGLE}deg)"
