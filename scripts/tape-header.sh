#!/bin/sh
# Emit the standard VHS preamble for an inference-autoscaling terminal clip.
#
#   scripts/tape-header.sh NAME FONTSIZE [LINEHEIGHT] > tapes/NN-name.tape
#   ...then append Type/Sleep/Enter/Sleep quads for each command.
#
# Everything before Show is hidden setup: the shell VHS spawns is not the
# devbox shell, so the prompt, the .env, and the cat alias all have to be
# re-established here. Aliases need `shopt -s expand_aliases` because that
# bash is non-interactive.
#
# LINEHEIGHT defaults to 1.7, which is right for sparse output -- a table, a
# short result -- where rows are few and the vertical space is free anyway.
# Pass 1.0 for a dense manifest, where rows are the binding constraint and
# airy spacing costs font size. Getting this wrong is not just cosmetic: it
# moves every row, so marks measured against one spacing land wrong in the
# other. Measure rows with scripts/tape-rows.sh, never compute them.
#
# FONTSIZE is derived per clip, not fixed for the video:
#   font = min(1872*0.95/(cols*0.628), 1032*0.95/(rows*1.195))
# where cols is the longest line INCLUDING the 17-character prompt, and rows
# counts every command line, every output line, and the trailing prompt.
set -e
NAME=$1; FONT=$2; LH=${3:-1.7}
REPO=/Users/viktorfarcic/code/inference-demo
cat <<TAPE
Output "$REPO/tmp/inference-autoscaling-screen-$NAME-raw.mp4"
Set Shell "bash"
Set FontSize $FONT
Set Width 1920
Set Height 1080
Set Padding 24
Set LineHeight $LH
Set Framerate 24
Set TypingSpeed 10ms
Set Theme { "name": "BlackOverlay", "background": "#000000", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#44475a", "black": "#000000", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#8be9fd", "magenta": "#ff79c6", "cyan": "#8be9fd", "white": "#bfbfbf", "brightBlack": "#4d4d4d", "brightRed": "#ff6e67", "brightGreen": "#5af78e", "brightYellow": "#f4f99d", "brightBlue": "#caa9fa", "brightCyan": "#9aedfe", "brightMagenta": "#ff92d0", "brightWhite": "#ffffff" }

Hide
Type "cd $REPO"
Enter
Type 'export PROMPT_COMMAND="" PS1="\W \\\$ " && source .env && export PROVIDER=google'
Enter
Type 'shopt -s expand_aliases && alias cat="bat --plain --paging never --theme DarkNeon"'
Enter
Type "clear"
Enter
Show
TAPE
