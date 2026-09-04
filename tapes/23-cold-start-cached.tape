Output "/Users/viktorfarcic/code/inference-demo/tmp/inference-autoscaling-screen-23-cold-start-cached-raw.mp4"
Set Shell "bash"
Set FontSize 22
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
Type "./dot.nu run openai_load \"
Enter
Type '    "http://silly-model.$INGRESS_HOST/v1/chat/completions" \'
Enter
Type "    --model qwen3-8b \"
Enter
Type "    --cases demo/autoscaling-one-case.json \"
Enter
Type "    --output tmp/cold-start-cached.json"
Sleep 500ms
Enter
Sleep 780s
