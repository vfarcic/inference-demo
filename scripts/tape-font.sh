#!/bin/sh
# scripts/tape-font.sh COLS ROWS  ->  the FontSize that fills the frame.
# COLS is the longest line including the 17-character prompt; ROWS counts
# every command line, every output line, and the trailing prompt. The 0.95
# keeps a margin: sized exactly to content, one extra column wraps a line,
# the wrap adds a row, and the top of the output scrolls away.
echo "$1 $2" | awk '{
  w = 1872*0.95/($1*0.628); h = 1032*0.95/($2*1.195);
  print int(w < h ? w : h)
}'
