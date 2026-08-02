#!/usr/bin/env bash
# Source script for the README hooks/links demo GIF.
#
# Render with:
#   asciinema rec --overwrite --cols 96 --rows 32 -c "bash assets/demo-hooks.sh" demo-hooks.cast
#   agg --font-size 17 --last-frame-duration 4 \
#     --theme 0d1117,f0f6fc,484f58,ff7b72,3fb950,d29922,58a6ff,bc8cff,39c5cf,b1bac4,6e7681,ffa198,56d364,e3b341,79c0ff,d2a8ff,56d4dd,f0f6fc \
#     demo-hooks.cast assets/demo-hooks.gif
#
# Requires `agent-store` on PATH. Runs in a temp directory.
set -euo pipefail

cd "$(mktemp -d)"
touch AGENTS.md
agent-store init >/dev/null # store already set up; this demo is about links + hooks

PROMPT=$'\033[1;32m$\033[0m '

type_cmd() {
  printf '%b' "$PROMPT"
  local cmd="$1"
  local i
  for ((i = 0; i < ${#cmd}; i++)); do
    printf '%s' "${cmd:i:1}"
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

# First command appears instantly: the GIF's opening frame must show content,
# not a blank screen with a typing lead-in (GIFs autoplay in the README).
fid=$(agent-store create finding area=auth severity=high text="tokens never expire")
printf '%b%s\n' "$PROMPT" 'agent-store create finding area=auth severity=high text="tokens never expire"'
sleep 0.35
echo "$fid"
sleep 0.6

tid=$(agent-store create task title="add token expiry" status=pending)
type_cmd 'agent-store create task title="add token expiry" status=pending'
echo "$tid"
sleep 0.6

run "agent-store link $fid blocks $tid" 1.0
run "agent-store hook add set kind=task -- 'agent-store create event note=\"\$AGENT_STORE_ID: \$AGENT_STORE_FIELD \$AGENT_STORE_OLD_VALUE -> \$AGENT_STORE_NEW_VALUE\"'" 1.0
run "agent-store set $tid status=done" 1.0
sleep 0.6 # let the hook finish
run 'agent-store find kind=event' 1.6
run "agent-store links $tid" 1.4
run 'agent-store ctx' 3
