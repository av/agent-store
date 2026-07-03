#!/usr/bin/env bash
# decision-log.sh — keep a queryable decision log with agent-store.
#
# Demonstrates: recording decisions as structured records, filtering by area,
# listing the latest decisions with timestamps, and linking a decision to the
# task it resolves.
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./decision-log.sh   (requires agent-store on PATH, or set AGENT_STORE)
set -euo pipefail

AGENT_STORE="${AGENT_STORE:-agent-store}"
# Resolve a relative binary path (e.g. target/release/agent-store) to an
# absolute one before we cd into the temp directory.
case "$AGENT_STORE" in
  */*) AGENT_STORE="$(cd "$(dirname "$AGENT_STORE")" && pwd)/${AGENT_STORE##*/}" ;;
esac
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

"$AGENT_STORE" init

echo "== Record decisions as they happen =="
"$AGENT_STORE" create decision area=storage choice=sqlite \
  reason="single-file project-local store, no server"
"$AGENT_STORE" create decision area=api choice="JSON envelope" \
  reason="stable shape for jq pipelines"
"$AGENT_STORE" create decision area=storage choice="WAL mode" \
  reason="concurrent readers during writes"

echo
echo "== All storage decisions =="
"$AGENT_STORE" find 'kind=decision and area=storage'

echo
echo "== The 3 most recent decisions, with timestamps =="
"$AGENT_STORE" find kind=decision --sort created_at --desc --limit 3 --timestamps

echo
echo "== Link a decision to the task it resolves =="
task_id="$("$AGENT_STORE" create task title="Pick a storage engine" status=done --json \
           | jq -r '.record.id')"
dec_id="$("$AGENT_STORE" find 'kind=decision and choice=sqlite' --json \
          | jq -r '.records[0].id')"
"$AGENT_STORE" link "$dec_id" resolves "$task_id"
"$AGENT_STORE" links "$dec_id"
