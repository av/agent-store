#!/usr/bin/env bash
# import-memory-md.sh — migrate an existing MEMORY.md into agent-store.
#
# Demonstrates: the sunk-cost escape hatch for a MEMORY.md habit. Two passes:
# a one-liner that imports every line as a note (the README version), and a
# structured pass that turns "## Section" headings into a topic field so the
# result is queryable — plus the retrieval payoff (`find`, `ctx`) that a flat
# markdown file can't give you.
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./import-memory-md.sh   (requires agent-store and jq on PATH)
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

echo "== The MEMORY.md an agent has been maintaining =="
cat > MEMORY.md <<'EOF'
# Project memory

## Decisions
- Use reqwest with rustls; native-tls broke musl cross-builds
- JSON output is an envelope: {"records":[...]} for stable jq paths

## Gotchas
- CI runner has 2 cores; timing-sensitive tests flake there
- config parser silently drops unknown keys
EOF
cat MEMORY.md

"$AGENT_STORE" init

echo
echo "== Pass 1: the one-line import (every non-empty line, as-is) =="
grep -v '^\s*$' MEMORY.md \
  | jq -R -c '{kind:"note",fields:{text:.}}' \
  | "$AGENT_STORE" create --stdin
"$AGENT_STORE" find kind=note --count

echo
echo "== Pass 2: structured import ('## Section' becomes a topic field) =="
# Wipe pass 1 and redo it with structure worth querying.
"$AGENT_STORE" find kind=note --json | jq -r '.records[].id' \
  | xargs -r -n1 "$AGENT_STORE" rm
awk '/^## /   { topic = tolower(substr($0, 4)); next }
     /^- /    { print topic "\t" substr($0, 3) }' MEMORY.md \
  | jq -R -c 'split("\t") | {kind:"note",fields:{topic:.[0],text:.[1]}}' \
  | "$AGENT_STORE" create --stdin

echo
echo "== The payoff: recall by topic instead of re-reading the whole file =="
"$AGENT_STORE" find 'kind=note and topic=gotchas'

echo
echo "== And ctx summarizes it for the next session =="
"$AGENT_STORE" ctx

# Sanity checks: structured import produced 4 notes, 2 per topic.
test "$("$AGENT_STORE" find kind=note --count)" = 4
test "$("$AGENT_STORE" find 'kind=note and topic=decisions' --count)" = 2
test "$("$AGENT_STORE" find 'kind=note and topic=gotchas' --count)" = 2
echo "import verified"
