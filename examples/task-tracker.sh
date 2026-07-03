#!/usr/bin/env bash
# task-tracker.sh — full task lifecycle with agent-store.
#
# Demonstrates: creating tasks, querying open work, sorting/limiting/counting,
# updating status, and closing out a task.
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./task-tracker.sh   (requires agent-store on PATH, or set AGENT_STORE)
set -euo pipefail

AGENT_STORE="${AGENT_STORE:-agent-store}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

"$AGENT_STORE" init

echo "== Create a few tasks =="
"$AGENT_STORE" create task title="Fix parser" status=pending priority=1
"$AGENT_STORE" create task title="Write docs" status=pending priority=2
"$AGENT_STORE" create task title="Ship release" status=blocked priority=1

echo
echo "== All open (not done) tasks =="
"$AGENT_STORE" find 'kind=task and status!=done'

echo
echo "== Oldest pending work first, top 5 =="
"$AGENT_STORE" find kind=task status=pending --sort created_at --limit 5

echo
echo "== How many tasks are still open? =="
"$AGENT_STORE" find 'kind=task and status!=done' --count

echo
echo "== Start and finish the parser fix =="
# Grab the ID of the highest-priority pending task via --json + jq.
id="$("$AGENT_STORE" find 'kind=task and status=pending and priority=1' --json \
      | jq -r '.records[0].id')"
"$AGENT_STORE" set "$id" status=in_progress
"$AGENT_STORE" set "$id" status=done note="handled in commit abc123"
"$AGENT_STORE" get "$id"

echo
echo "== Remaining open tasks =="
"$AGENT_STORE" find 'kind=task and status!=done' --count
