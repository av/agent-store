#!/usr/bin/env bash
# jsonl-pipeline.sh — export, transform, and re-import records with jq.
#
# Demonstrates: `find --json` export, jq transforms, and bulk import via
# `create --stdin` (one {"kind":...,"fields":{...}} JSONL object per line —
# the same shape `find --json` emits, so exports round-trip; extra keys like
# id and timestamps are ignored on import). Every line is validated before
# any record is created, so a bad line imports nothing.
#
# Self-contained: runs against throwaway stores in temp directories.
# Usage: ./jsonl-pipeline.sh   (requires agent-store and jq on PATH)
set -euo pipefail

AGENT_STORE="${AGENT_STORE:-agent-store}"
src="$(mktemp -d)"
dst="$(mktemp -d)"
trap 'rm -rf "$src" "$dst"' EXIT

echo "== Populate a source store =="
cd "$src"
"$AGENT_STORE" init
"$AGENT_STORE" create task title="Fix parser" status=done priority=1
"$AGENT_STORE" create task title="Write docs" status=pending priority=2
"$AGENT_STORE" create note text="unrelated note"

echo
echo "== Export all tasks as JSONL =="
"$AGENT_STORE" find kind=task --json | jq -c '.records[]' | tee tasks.jsonl

echo
echo "== Transform: keep only pending tasks, retag them as 'todo' =="
jq -c 'select(.fields.status == "pending") | .kind = "todo"' tasks.jsonl \
  > todos.jsonl
cat todos.jsonl

echo
echo "== Import into a second store =="
cd "$dst"
"$AGENT_STORE" init
"$AGENT_STORE" create --stdin < "$src/todos.jsonl"
"$AGENT_STORE" find kind=todo

echo
echo "== Validation demo: a broken line imports nothing =="
printf '%s\n' '{"kind":"todo","fields":{"title":"ok"}}' 'not json' > bad.jsonl
if "$AGENT_STORE" create --stdin < bad.jsonl; then
  echo "ERROR: import of invalid JSONL unexpectedly succeeded" >&2
  exit 1
else
  echo "import failed as expected; store still has only:"
  "$AGENT_STORE" find kind=todo --count
fi
