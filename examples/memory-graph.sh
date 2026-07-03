#!/usr/bin/env bash
# memory-graph.sh — build a linked memory graph across agent sessions.
#
# Demonstrates: an investigation where findings `support` a conclusion and a
# fix task `implements` it, traversing the graph from either end with
# `link.in` / `link.out` / `link.out.<rel>=<id>` queries, reading a single
# record's edges with `links`, watching relation counts appear in `ctx`, and
# two defensive-scripting details: self-links are rejected with a clear
# error, and `--json` runtime errors arrive as a `{"error":...}` envelope on
# stderr (stdout stays data-only).
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./memory-graph.sh   (requires agent-store on PATH, or set AGENT_STORE)
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

echo "== Session 1: investigate a flaky test, record findings =="
f1="$("$AGENT_STORE" create finding area=ci \
  note="test_retry flakes only on the 2-core CI runner" --json | jq -r '.record.id')"
f2="$("$AGENT_STORE" create finding area=ci \
  note="failure always follows a tokio timer firing early" --json | jq -r '.record.id')"
f3="$("$AGENT_STORE" create finding area=ci \
  note="sleep-based sync in test helper, not in production code" --json | jq -r '.record.id')"
"$AGENT_STORE" find kind=finding

echo
echo "== Session 1: draw a conclusion and link the evidence to it =="
conclusion="$("$AGENT_STORE" create conclusion area=ci \
  verdict="flake is a race in the test helper; replace sleeps with explicit signals" \
  --json | jq -r '.record.id')"
"$AGENT_STORE" link "$f1" supports "$conclusion"
"$AGENT_STORE" link "$f2" supports "$conclusion"
"$AGENT_STORE" link "$f3" supports "$conclusion"

echo
echo "== Session 1: file the fix and link it to what it implements =="
task="$("$AGENT_STORE" create task status=open \
  title="replace sleep-based sync in test helper with channel signals" \
  --json | jq -r '.record.id')"
"$AGENT_STORE" link "$task" implements "$conclusion"

echo
echo "== A record cannot link to itself (usually a typo'd ID) =="
if "$AGENT_STORE" link "$task" blocks "$task" 2>link-err.txt; then
  echo "unexpected: self-link was accepted" >&2
  exit 1
fi
cat link-err.txt

echo
echo "== (session 1 ends; session 2 starts fresh in the same repo) =="
echo
echo "== Session 2: ctx shows the graph shape (links by relation) =="
"$AGENT_STORE" ctx

echo
echo "== Session 2: everything hanging off the conclusion =="
"$AGENT_STORE" links "$conclusion"

echo
echo "== Session 2: query the graph, not just fields =="
echo "-- conclusions that have supporting evidence:"
"$AGENT_STORE" find 'kind=conclusion and link.in=supports'
echo "-- open work implementing this specific conclusion:"
"$AGENT_STORE" find "kind=task and status=open and link.out.implements=$conclusion"
echo "-- evidence for it (findings pointing at this record):"
"$AGENT_STORE" find "kind=finding and link.out.supports=$conclusion"

echo
echo "== Session 2: one finding turns out to be wrong; retract its support =="
"$AGENT_STORE" set "$f2" retracted=true \
  note="timer fired on schedule; earlier trace was misread"
"$AGENT_STORE" unlink "$f2" supports "$conclusion"
echo "-- remaining evidence:"
"$AGENT_STORE" find "link.out.supports=$conclusion"

echo
echo "== Session 2: JSON errors are a stderr envelope; stdout stays data-only =="
set +e
"$AGENT_STORE" --json get zzzzzz >get-out.txt 2>get-err.txt
code=$?
set -e
echo "exit=$code stdout=$(wc -c <get-out.txt) bytes"
jq -r '.error' get-err.txt

echo
echo "== Session 2: close out the task =="
"$AGENT_STORE" set "$task" status=done
"$AGENT_STORE" get "$task"

# Sanity checks: graph state matches the story above.
test "$("$AGENT_STORE" find "link.out.supports=$conclusion" --json | jq '.records | length')" = 2
test "$("$AGENT_STORE" links "$conclusion" | grep -c '^in ')" = 3
grep -q 'cannot link a record to itself' link-err.txt
echo "memory graph verified"
