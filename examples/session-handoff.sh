#!/usr/bin/env bash
# session-handoff.sh — hand off work between agent sessions using ctx.
#
# Demonstrates: a "session 1" that records progress, findings, and next steps,
# and a "session 2" that reconstructs the working state from `agent-store ctx`
# (a compact Quick Context summary capped at 8192 bytes, ending with the 10
# most recently updated records) plus targeted queries.
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./session-handoff.sh   (requires agent-store on PATH, or set AGENT_STORE)
set -euo pipefail

AGENT_STORE="${AGENT_STORE:-agent-store}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

"$AGENT_STORE" init

echo "== Session 1: do some work and leave breadcrumbs =="
"$AGENT_STORE" create task title="Migrate config loader" status=in_progress
"$AGENT_STORE" create finding severity=high \
  note="config parser silently drops unknown keys"
"$AGENT_STORE" create scratch task=migration step=2 \
  note="old loader lives in src/config.rs; new one half-done in src/config2.rs"
"$AGENT_STORE" create handoff next="finish config2.rs, then delete src/config.rs" \
  blocker="need decision on env-var override precedence"

echo
echo "== (session 1 ends; session 2 starts fresh in the same repo) =="
echo
echo "== Session 2: one command to get oriented =="
"$AGENT_STORE" ctx

echo
echo "== Session 2: pull the explicit handoff notes =="
"$AGENT_STORE" find kind=handoff --sort updated_at --desc --limit 1

echo
echo "== Session 2: resume the in-progress task =="
id="$("$AGENT_STORE" find 'kind=task and status=in_progress' --json \
      | jq -r '.records[0].id')"
"$AGENT_STORE" set "$id" note="resumed by session 2"
"$AGENT_STORE" get "$id"
