#!/bin/sh
# Turn a raw VHS recording into the delivered clip in ONE ffmpeg pass.
#
#   scripts/finish.sh IN.mp4 OUT.mp4 \
#       [--keep START-END]... [--pad SECONDS] \
#       [--arrow X,Y,CUE[,ANGLE[,END]]]...
#
# Always compose from the raw recording. Never take a derived clip as input:
# cutting, padding and each arrow are all just filters, and running them as
# separate commands re-encodes the whole clip once per step. Six steps on one
# clip measured SSIM 0.994 against its raw, and the loss lands exactly where
# it is most visible -- ringing on thin terminal glyphs at small font sizes.
# Composed in a single graph there is one encode, whatever the clip needs.
#
#   --keep   a span to keep, in seconds; repeat for each. Everything between
#            spans is dropped with a hard cut, invisible as long as both sides
#            are frozen frames. Pick boundaries from freezedetect:
#              ffmpeg -i IN.mp4 -vf freezedetect=n=0.0005:d=0.7 -map 0:v -f null -
#            Omit entirely to keep the whole recording.
#   --pad    hold the final frame this many extra seconds, for when the
#            narration over a static frame outlasts the recording.
#   --arrow  X,Y is the tip. Y goes about six pixels BELOW the glyph bottom,
#            not on the row centre -- scripts/tape-rows.sh prints it as "tip".
#            ANGLE is the entry direction clockwise from east (default 135,
#            arriving from the lower right). END makes the arrow transient;
#            leave it off and it holds to the end of the clip.
set -e

IN=$1; OUT=$2; shift 2
KEEPS=""; PAD=""; ARROWS=""
while [ $# -gt 0 ]; do
  case $1 in
    --keep)  KEEPS="$KEEPS $2"; shift 2 ;;
    --pad)   PAD=$2; shift 2 ;;
    --arrow) ARROWS="$ARROWS $2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

COLOR='#ffe100'
SLIDE=0.35      # seconds for the slide-in
TRAVEL=100      # pixels the sprite travels on the way in
PULSE_PX=6      # amplitude of the settled pulse
PULSE_RATE=6    # radians per second

FG=""; CUR="0:v"

# --- cut
if [ -n "$KEEPS" ]; then
  n=0; cat=""
  for span in $KEEPS; do
    FG="$FG[0:v]trim=start=${span%-*}:end=${span#*-},setpts=PTS-STARTPTS[k$n];"
    cat="$cat[k$n]"; n=$((n+1))
  done
  FG="$FG${cat}concat=n=$n:v=1:a=0[cut];"; CUR="cut"
fi

# --- pad
if [ -n "$PAD" ]; then
  FG="$FG[$CUR]tpad=stop_mode=clone:stop_duration=$PAD[pad];"; CUR="pad"
fi

# --- arrows, all from one sprite split as many ways as needed
SPRITE=""
if [ -n "$ARROWS" ]; then
  SPRITE=$(dirname "$OUT")/.arrow-sprite.png
  # Tip near the top-left of its own canvas so the body trails down and right.
  magick -size 170x170 xc:none \
    -stroke "$COLOR" -strokewidth 16 -draw "line 142,138 57,56" \
    -fill "$COLOR" -stroke none -draw "polygon 12,12 79,30 31,78" "$SPRITE"

  na=0; for a in $ARROWS; do na=$((na+1)); done
  if [ "$na" -eq 1 ]; then FG="$FG[1:v]null[s0];"
  else
    sp=""; i=0; while [ $i -lt $na ]; do sp="$sp[s$i]"; i=$((i+1)); done
    FG="$FG[1:v]split=$na$sp;"
  fi

  i=0
  for a in $ARROWS; do
    X=$(echo "$a" | cut -d, -f1); Y=$(echo "$a" | cut -d, -f2)
    CUE=$(echo "$a" | cut -d, -f3)
    ANGLE=$(echo "$a" | cut -d, -f4); [ -n "$ANGLE" ] || ANGLE=135
    END=$(echo "$a" | cut -d, -f5)

    BASEX=$(echo "$X - 12" | bc); BASEY=$(echo "$Y - 12" | bc)
    DX=$(echo "scale=4; c($ANGLE * 3.14159265 / 180)" | bc -l)
    DY=$(echo "scale=4; s($ANGLE * 3.14159265 / 180)" | bc -l)
    OFFX=$(echo "scale=2; -1 * $TRAVEL * $DX" | bc -l)
    OFFY=$(echo "scale=2; -1 * $TRAVEL * $DY" | bc -l)
    P="min(1\,max(0\,(t-$CUE)/$SLIDE))"
    W="$PULSE_PX*sin($PULSE_RATE*(t-$CUE))*$P"
    if [ -n "$END" ]; then EN="between(t,$CUE,$END)"; else EN="gte(t,$CUE)"; fi

    nxt="a$i"
    FG="$FG[$CUR][s$i]overlay=x='$BASEX+($OFFX)*(1-$P)+$W':y='$BASEY+($OFFY)*(1-$P)+$W':enable='$EN'[$nxt];"
    CUR="$nxt"; i=$((i+1))
  done
fi

set -- -y -loglevel error -i "$IN"
[ -n "$SPRITE" ] && set -- "$@" -i "$SPRITE"
if [ -n "$FG" ]; then
  set -- "$@" -filter_complex "$(echo "$FG" | sed 's/;$//')" -map "[$CUR]"
else
  set -- "$@" -map 0:v
fi
# -preset slow -crf 16: terminal text is high-contrast thin strokes, exactly
# what a fast preset rings around. These clips are short; spend the bits.
ffmpeg "$@" -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p "$OUT"

[ -n "$SPRITE" ] && rm -f "$SPRITE"
echo "wrote $OUT (one pass:${KEEPS:+ keep$KEEPS}${PAD:+ pad ${PAD}s}${ARROWS:+ arrows$ARROWS})"
