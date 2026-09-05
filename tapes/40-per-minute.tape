Output "/Users/viktorfarcic/code/inference-demo/tmp/inference-autoscaling-screen-40-per-minute-raw.mp4"
Set Shell "bash"
Set FontSize 23
Set Width 1920
Set Height 1080
Set Padding 24
Set LineHeight 1.0
Set Framerate 24
Set TypingSpeed 10ms
Set Theme { "name": "BlackOverlay", "background": "#000000", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#44475a", "black": "#000000", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#8be9fd", "magenta": "#ff79c6", "cyan": "#8be9fd", "white": "#bfbfbf", "brightBlack": "#4d4d4d", "brightRed": "#ff6e67", "brightGreen": "#5af78e", "brightYellow": "#f4f99d", "brightBlue": "#caa9fa", "brightCyan": "#9aedfe", "brightMagenta": "#ff92d0", "brightWhite": "#ffffff" }

Hide
Type "cd /Users/viktorfarcic/code/inference-demo"
Enter
Type 'export PROMPT_COMMAND="" PS1="\W \$ " && source .env && export PROVIDER=google'
Enter
Type 'shopt -s expand_aliases && alias cat="bat --plain --paging never --theme DarkNeon"'
Enter
Type "clear"
Enter
Show
Type "nu -c 'open tmp/sustained.json"
Enter
Type "    | get requests"
Enter
Type "    | insert minute {|r| ($r.send_after_ms / 60000) | math floor}"
Enter
Type "    | group-by minute"
Enter
Type "    | transpose minute rows"
Enter
Type "    | each {|g| {minute: $g.minute, sent: ($g.rows | length), ttft_p50_ms: ($g.rows | get ttft_ms | math median | math round)}}'"
Sleep 500ms
Enter
Sleep 15s
