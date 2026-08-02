#!/usr/bin/env bash
# Source script for the README demo GIF.
#
# Render with:
#   asciinema rec --overwrite --cols 96 --rows 32 -c "bash assets/demo.sh" demo.cast
#   agg --font-size 17 --last-frame-duration 4 \
#     --theme 0d1117,f0f6fc,484f58,ff7b72,3fb950,d29922,58a6ff,bc8cff,39c5cf,b1bac4,6e7681,ffa198,56d364,e3b341,79c0ff,d2a8ff,56d4dd,f0f6fc \
#     demo.cast assets/demo.gif
#
# Requires `agent-store` on PATH. Runs in a temp directory.
set -euo pipefail

cd "$(mktemp -d)"
touch AGENTS.md # so init demonstrates the instructions block install

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
run_instant() {
  printf '%b%s\n' "$PROMPT" "$1"
  sleep 0.35
  eval "$1"
  sleep "${2:-0.8}"
}

run_instant 'agent-store init'
run 'agent-store create decision topic=tls choice=rustls reason="no openssl system dep"' 0.6
run 'agent-store create finding area=auth severity=high text="session tokens never expire"' 0.6
tid=$(agent-store create task title="add token expiry" status=pending priority=1)
type_cmd 'agent-store create task title="add token expiry" status=pending priority=1'
echo "$tid"
sleep 0.9
run 'agent-store find kind=task and status=pending' 1.4
run "agent-store find 'severity=high or priority<2'" 1.6
run "agent-store set $tid status=in-progress" 1.2
run 'agent-store ctx' 3
