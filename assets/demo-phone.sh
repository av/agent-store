#!/usr/bin/env bash
# Source script for the phone-width README demo GIF (demo-phone.gif).
#
# README.md shows it instead of demo.gif on screens up to 600 px wide
# (<picture> with a max-width media query). demo.gif at 70 columns scales to
# ~7 px text on a 390 px phone; this one keeps every line within 48
# characters of a 50-column terminal, so the text stays legible there.
#
# Render with:
#   asciinema rec --overwrite --cols 50 --rows 19 -c "bash assets/demo-phone.sh" demo-phone.cast
#   agg --font-size 24 --last-frame-duration 4 --select event:0.. \
#     --theme 161b22,f0f6fc,484f58,ff7b72,3fb950,d29922,58a6ff,bc8cff,39c5cf,b1bac4,6e7681,ffa198,56d364,e3b341,79c0ff,d2a8ff,56d4dd,f0f6fc \
#     demo-phone.cast assets/demo-phone.gif
#
# Same flow as demo.sh in short form: records, find, set, ctx. Keep record
# fields short: ctx indents its Recent records lines by two spaces.
#
# Requires `agent-store` on PATH. Runs in a temp directory.
set -euo pipefail

cd "$(mktemp -d)"
touch AGENTS.md CLAUDE.md
agent-store init >/dev/null # demo.sh shows init; this one starts with records

PROMPT=$'\033[1;32m$\033[0m '
PS2_PROMPT=$'\033[90m>\033[0m '

# Echoes a command the way interactive bash shows it: each line after a
# newline in the command gets the secondary prompt.
show_cmd() {
  printf '%b%s\n' "$PROMPT" "${1//$'\n'/$'\n'$PS2_PROMPT}"
}

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

# The records and queries appear at once, in a single write that the render
# starts from (agg --select event:0..), so the GIF's opening frame is mostly
# filled (README GIFs autoplay from frame 0, and viewers who turn autoplay off
# only see this frame).
run_instant() {
  show_cmd "$1"
  eval "$1"
}

opening=$(mktemp)
{
  run_instant 'agent-store create decision area=http \
  choice=reqwest'
  run_instant 'agent-store create finding severity=high \
  text="no expiry"'
  cmd='agent-store create task status=pending \
  title="add expiry"'
  tid=$(eval "$cmd")
  show_cmd "$cmd"
  echo "$tid"
  run_instant 'agent-store find kind=task status=pending'
  run_instant "agent-store find 'severity=high or kind=task'"
} >"$opening"
cat "$opening"
sleep 2.5
run "agent-store set $tid status=done" 1.2
run 'agent-store ctx' 3
