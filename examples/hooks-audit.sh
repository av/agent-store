#!/usr/bin/env bash
# hooks-audit.sh — audit-log every mutation with hooks.
#
# Demonstrates: registering hooks on create/set/rm that append to an audit
# log using the AGENT_STORE_* environment variables each hook receives
# (AGENT_STORE_EVENT, AGENT_STORE_ID, AGENT_STORE_KIND always; plus
# AGENT_STORE_KEY / AGENT_STORE_OLD_VALUE / AGENT_STORE_NEW_VALUE on
# single-field set), scoping a hook to a query, and inspecting executions
# with `hook runs`.
#
# Self-contained: runs against a throwaway store in a temp directory.
# Usage: ./hooks-audit.sh   (requires agent-store on PATH, or set AGENT_STORE)
set -euo pipefail

AGENT_STORE="${AGENT_STORE:-agent-store}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

"$AGENT_STORE" init
audit_log="$workdir/audit.log"

echo "== Register audit hooks =="
"$AGENT_STORE" hook add create -- \
  "echo \"\$(date -u +%FT%TZ) CREATE \$AGENT_STORE_KIND \$AGENT_STORE_ID\" >> '$audit_log'"
"$AGENT_STORE" hook add set -- \
  "echo \"\$(date -u +%FT%TZ) SET \$AGENT_STORE_ID \$AGENT_STORE_KEY: \$AGENT_STORE_OLD_VALUE -> \$AGENT_STORE_NEW_VALUE\" >> '$audit_log'"
"$AGENT_STORE" hook add rm -- \
  "echo \"\$(date -u +%FT%TZ) DELETE \$AGENT_STORE_KIND \$AGENT_STORE_ID\" >> '$audit_log'"
# Query-scoped hook: only fires for high-severity findings.
"$AGENT_STORE" hook add create 'kind=finding and severity=high' -- \
  "echo \"\$(date -u +%FT%TZ) ALERT high-severity finding \$AGENT_STORE_ID\" >> '$audit_log'"
"$AGENT_STORE" hook ls

echo
echo "== Perform some mutations =="
id="$("$AGENT_STORE" create task title="Fix parser" status=pending --json | jq -r '.record.id')"
"$AGENT_STORE" create finding severity=high note="unchecked unwrap in hot path"
"$AGENT_STORE" set "$id" status=done
"$AGENT_STORE" rm "$id"

echo
echo "== Audit trail =="
cat "$audit_log"

echo
echo "== Hook execution history =="
"$AGENT_STORE" hook runs

# Sanity check: the trail must contain all four event lines.
grep -q 'CREATE task'  "$audit_log"
grep -q 'ALERT high-severity' "$audit_log"
grep -q 'SET '         "$audit_log"
grep -q 'DELETE task'  "$audit_log"
echo "audit trail verified"
