#!/usr/bin/env bash
# Source script for the README hooks/links demo GIF.
#
# Render with:
#   asciinema rec --overwrite --cols 70 --rows 22 -c "bash assets/demo-hooks.sh" demo-hooks.cast
#   agg --font-size 20 --last-frame-duration 4 \
#     --theme 161b22,f0f6fc,484f58,ff7b72,3fb950,d29922,58a6ff,bc8cff,39c5cf,b1bac4,6e7681,ffa198,56d364,e3b341,79c0ff,d2a8ff,56d4dd,f0f6fc \
#     demo-hooks.cast assets/demo-hooks.gif
#
# Same 70-column limit as demo.sh: keep every line within 70 characters and
# break long commands at a word with a `\` continuation.
#
# Requires `agent-store` on PATH. Runs in a temp directory.
set -euo pipefail

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

# First command appears instantly, before the store setup: the GIF's opening
# frame must show content, not a blank screen with a typing lead-in (GIFs
# autoplay in the README, and viewers who turn autoplay off only see this
# frame).
cmd='agent-store create finding area=auth severity=high \
  text="tokens never expire"'
printf '%b%s\n' "$PROMPT" "${cmd//$'\n'/$'\n'$PS2_PROMPT}"

cd "$(mktemp -d)"
touch AGENTS.md
agent-store init >/dev/null # store already set up; this demo is about links + hooks

fid=$(eval "$cmd")
echo "$fid"
sleep 0.6

cmd='agent-store create task title="add token expiry" status=pending'
tid=$(eval "$cmd")
type_cmd "$cmd"
echo "$tid"
sleep 0.6

run "agent-store link $fid blocks $tid" 1.0
run "agent-store hook add set kind=task -- 'agent-store create event \\
  task=\$AGENT_STORE_ID field=\$AGENT_STORE_FIELD \\
  from=\"\$AGENT_STORE_OLD_VALUE\" to=\"\$AGENT_STORE_NEW_VALUE\"'" 1.0
run "agent-store set $tid status=done" 1.0
sleep 0.6 # let the hook finish
run 'agent-store hook runs' 1.4
run 'agent-store find kind=event' 1.6
run "agent-store links $tid" 3
