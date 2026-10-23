#!/usr/bin/env bash
# Source script for the README demo GIF.
#
# Render with:
#   asciinema rec --overwrite --cols 70 --rows 22 -c "bash assets/demo.sh" demo.cast
#   agg --font-size 20 --last-frame-duration 4 \
#     --theme 161b22,f0f6fc,484f58,ff7b72,3fb950,d29922,58a6ff,bc8cff,39c5cf,b1bac4,6e7681,ffa198,56d364,e3b341,79c0ff,d2a8ff,56d4dd,f0f6fc \
#     demo.cast assets/demo.gif
#
# Keep every command and output line within 70 characters, and break long
# commands at a word with a `\` continuation. Phones get demo-phone.gif
# instead (demo-phone.sh, 50 columns): at a 390 px phone width this 70-column
# GIF scales to ~7 px text.
#
# Requires `agent-store` on PATH. Runs in a temp directory.
set -euo pipefail

cd "$(mktemp -d)"

PROMPT=$'\033[1;32m$\033[0m '
PS2_PROMPT=$'\033[90m>\033[0m '

# Echoes a command the way interactive bash shows it: each line after a
# newline in the command gets the secondary prompt.
type_cmd() {
  printf '%b' "$PROMPT"
  local cmd="$1"
  local i
  for ((i = 0; i < ${#cmd}; i++)); do
    if [[ ${cmd:i:1} == $'\n' ]]; then
      printf '\n%b' "$PS2_PROMPT"
    else
      printf '%s' "${cmd:i:1}"
    fi
    sleep 0.03
  done
  printf '\n'
  sleep 0.15
}

run() {
  type_cmd "$1"
  eval "$1"
  sleep "${2:-0.8}"
}

# First commands and their output appear instantly: the GIF's opening frame must
# show content, not a blank screen with a typing lead-in (GIFs autoplay in the
# README, and viewers who turn autoplay off only see this frame).
run_instant() {
  printf '%b%s\n' "$PROMPT" "$1"
  eval "$1"
  sleep "${2:-0.8}"
}

run_instant 'touch AGENTS.md CLAUDE.md' 0
run_instant 'agent-store init'
run 'agent-store create decision area=http choice=reqwest \
  reason="no openssl dep"' 0.6
run 'agent-store create finding area=auth severity=high \
  text="tokens never expire"' 0.6
cmd='agent-store create task title="add token expiry" \
  status=pending priority=1'
tid=$(eval "$cmd")
type_cmd "$cmd"
echo "$tid"
sleep 0.9
run 'agent-store find kind=task and status=pending' 1.4
run "agent-store find 'severity=high or priority<2'" 1.6
run "agent-store set $tid status=in-progress" 1.2
run 'agent-store ctx' 3
