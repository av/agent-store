#!/usr/bin/env bash
# Integration test exercising all 5 new features together in a realistic workflow:
#   1. Upsert (push --upsert)
#   2. Links (push --link, link, unlink, query --linked-to/--linked-from/--link-rel)
#   3. Batch Mutate (update command)
#   4. Tally (tally --by)
#   5. Changelog (log command)
#
# Usage: bash tests/integration_top5.sh

set -euo pipefail

# --- Resolve binary ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AS="${PROJECT_DIR}/target/release/agent-store"

if [[ ! -x "$AS" ]]; then
  echo "FAIL: binary not found at $AS (run: cargo build --release)" >&2
  exit 1
fi

# --- Helpers ---
PASS=0
FAIL=0
TESTS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual:              $haystack"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected NOT to contain: $needle"
    echo "    actual:                  $haystack"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  fi
}

assert_gt() {
  local label="$1" actual="$2" threshold="$3"
  TESTS=$((TESTS + 1))
  if (( actual > threshold )); then
    PASS=$((PASS + 1))
    echo "  PASS: $label ($actual > $threshold)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label ($actual <= $threshold)"
  fi
}

# --- Setup ---
echo "=== SETUP ==="
TMPDIR="$(mktemp -d)"
export AGENT_STORE_PATH="$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

$AS init >/dev/null 2>&1
echo "  Store initialized at $AGENT_STORE_PATH"

# ============================================================
# SECTION 1: Create project structure with upsert and links
# ============================================================
echo ""
echo "=== 1. CREATE PROJECT STRUCTURE (upsert + links) ==="

# Create an epic
EPIC_ID=$(echo "Epic: Build Dashboard v2" | $AS push \
  --label epic --label project-alpha \
  --type epic \
  --attr status=open --attr priority=high \
  --id-only)
assert_contains "epic created" "$EPIC_ID" "-"

# Create 3 tasks linked to the epic
TASK1_ID=$(echo "Task: Design UI mockups" | $AS push \
  --label task --label frontend \
  --type task \
  --attr status=todo --attr assignee=alice \
  --link "child-of:$EPIC_ID" \
  --id-only)
assert_contains "task-1 created with link" "$TASK1_ID" "-"

TASK2_ID=$(echo "Task: Implement API endpoints" | $AS push \
  --label task --label backend \
  --type task \
  --attr status=todo --attr assignee=bob \
  --link "child-of:$EPIC_ID" \
  --id-only)
assert_contains "task-2 created with link" "$TASK2_ID" "-"

TASK3_ID=$(echo "Task: Write integration tests" | $AS push \
  --label task --label testing \
  --type task \
  --attr status=todo --attr assignee=carol \
  --link "child-of:$EPIC_ID" \
  --id-only)
assert_contains "task-3 created with link" "$TASK3_ID" "-"

# Upsert a config entry (create)
UPSERT_OUT=$( echo "postgres://localhost/dashboard" | $AS push \
  --upsert \
  --label config \
  --type config \
  --attr key=db-url \
  --json )
assert_contains "upsert creates new entry" "$UPSERT_OUT" '"action":"created"'
CONFIG_ID=$(echo "$UPSERT_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Upsert the same config (update)
UPSERT_OUT2=$( echo "postgres://prod-host/dashboard" | $AS push \
  --upsert \
  --label config \
  --type config \
  --attr key=db-url \
  --json )
assert_contains "upsert updates existing entry" "$UPSERT_OUT2" '"action":"updated"'
CONFIG_ID2=$(echo "$UPSERT_OUT2" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
assert_eq "upsert preserves ID" "$CONFIG_ID" "$CONFIG_ID2"

# Verify upserted data was replaced
PULLED=$($AS pull "$CONFIG_ID")
assert_eq "upsert replaced data" "postgres://prod-host/dashboard" "$PULLED"

# Verify entry count
COUNT=$($AS query --count)
assert_eq "5 entries total (1 epic + 3 tasks + 1 config)" "5" "$COUNT"

# ============================================================
# SECTION 2: Mutate with update command
# ============================================================
echo ""
echo "=== 2. BATCH MUTATE (update command) ==="

# Bulk update: tag all tasks with sprint-1
BULK_OUT=$($AS update --label task --type task --tag sprint-1 --confirm --json)
BULK_UPDATED=$(echo "$BULK_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['updated'])")
assert_eq "bulk update tagged 3 tasks" "3" "$BULK_UPDATED"

# Single update: set status=in-progress on task 1
SINGLE_OUT=$($AS update "$TASK1_ID" --set status=in-progress --json)
assert_contains "single update sets attr" "$SINGLE_OUT" '"attrs_set":1'

# Single update: set status=in-progress on task 2
$AS update "$TASK2_ID" --set status=in-progress >/dev/null

# Single update: set status=done on task 3
$AS update "$TASK3_ID" --set status=done >/dev/null

# Verify mutations: task 1 should have sprint-1 label and in-progress status
T1_JSON=$($AS pull "$TASK1_ID" --json)
assert_contains "task-1 has sprint-1 label" "$T1_JSON" '"sprint-1"'
assert_contains "task-1 is in-progress" "$T1_JSON" '"status":"in-progress"'

# Verify task 3 is done
T3_JSON=$($AS pull "$TASK3_ID" --json)
assert_contains "task-3 is done" "$T3_JSON" '"status":"done"'

# Dry-run preview (should not apply)
DRY_OUT=$($AS update --label task --tag dry-test --dry-run --json)
DRY_COUNT=$(echo "$DRY_OUT" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "dry-run shows 3 matching entries" "3" "$DRY_COUNT"
T1_AFTER_DRY=$($AS pull "$TASK1_ID" --json)
assert_not_contains "dry-run did not apply" "$T1_AFTER_DRY" "dry-test"

# ============================================================
# SECTION 3: Query with links
# ============================================================
echo ""
echo "=== 3. QUERY WITH LINKS ==="

# Find all tasks linked to the epic
LINKED=$($AS query --linked-to "$EPIC_ID" --json)
LINKED_COUNT=$(echo "$LINKED" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "3 entries linked to epic" "3" "$LINKED_COUNT"

# Find epic from a task (reverse traversal)
PARENTS=$($AS query --linked-from "$TASK1_ID" --json)
PARENT_ID=$(echo "$PARENTS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
assert_eq "task-1 links back to epic" "$EPIC_ID" "$PARENT_ID"

# Filter by relationship type
REL_CHILD=$($AS query --linked-to "$EPIC_ID" --link-rel child-of --json)
REL_COUNT=$(echo "$REL_CHILD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "3 child-of links to epic" "3" "$REL_COUNT"

# Filter by non-existent relationship
REL_NONE=$($AS query --linked-to "$EPIC_ID" --link-rel "blocks" --json)
assert_eq "0 blocks links to epic" "[]" "$REL_NONE"

# Create a cross-link between tasks (task2 blocks task3)
$AS link "$TASK2_ID" "$TASK3_ID" blocks >/dev/null
BLOCKERS=$($AS query --linked-to "$TASK3_ID" --link-rel blocks --json)
BLOCKER_ID=$(echo "$BLOCKERS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
assert_eq "task-2 blocks task-3" "$TASK2_ID" "$BLOCKER_ID"

# Pull with links
EPIC_LINKS=$($AS pull "$EPIC_ID" --json --with-links)
LINKS_TO_COUNT=$(echo "$EPIC_LINKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['links_to']))")
assert_eq "epic has 3 incoming links" "3" "$LINKS_TO_COUNT"

# ============================================================
# SECTION 4: Tally for dashboard
# ============================================================
echo ""
echo "=== 4. TALLY (dashboard aggregation) ==="

# Tally by status attribute
STATUS_TALLY=$($AS tally --by "attr:status")
assert_contains "tally shows in-progress" "$STATUS_TALLY" "in-progress"
assert_contains "tally shows done" "$STATUS_TALLY" "done"
assert_contains "tally shows open" "$STATUS_TALLY" "open"

# Tally by label
LABEL_TALLY=$($AS tally --by label)
assert_contains "label tally shows task" "$LABEL_TALLY" "task"
assert_contains "label tally shows epic" "$LABEL_TALLY" "epic"
assert_contains "label tally shows sprint-1" "$LABEL_TALLY" "sprint-1"

# Tally by type
TYPE_TALLY=$($AS tally --by type)
assert_contains "type tally shows task" "$TYPE_TALLY" "task"
assert_contains "type tally shows config" "$TYPE_TALLY" "config"

# Tally with filters (only tasks)
TASK_STATUS=$($AS tally --by "attr:status" --type task)
assert_not_contains "filtered tally excludes epic's open status" "$TASK_STATUS" "open"
assert_contains "filtered tally shows in-progress" "$TASK_STATUS" "in-progress"

# Tally --json output
TALLY_JSON=$($AS tally --by type --json)
assert_contains "tally json has value field" "$TALLY_JSON" '"value"'
assert_contains "tally json has count field" "$TALLY_JSON" '"count"'

# ============================================================
# SECTION 5: Changelog for audit
# ============================================================
echo ""
echo "=== 5. CHANGELOG (audit trail) ==="

# Log all recent activity
LOG_ALL=$($AS log --limit 50)
LOG_LINES=$(echo "$LOG_ALL" | wc -l)
assert_gt "log has entries" "$LOG_LINES" 0

# Log should show tag operations
assert_contains "log shows tag operation" "$LOG_ALL" "tag"
assert_contains "log shows sprint-1 tagging" "$LOG_ALL" "sprint-1"

# Log should show set-attr operations
assert_contains "log shows set-attr operation" "$LOG_ALL" "set-attr"

# Log for a specific entry
TASK1_LOG=$($AS log "$TASK1_ID")
assert_contains "task-1 log shows set-attr" "$TASK1_LOG" "set-attr"
assert_contains "task-1 log shows status change" "$TASK1_LOG" "in-progress"
assert_contains "task-1 log shows tag" "$TASK1_LOG" "sprint-1"

# Log --since (use a past timestamp to get all entries)
SINCE_LOG=$($AS log --since "2020-01-01T00:00:00Z")
assert_gt "log --since returns entries" "$(echo "$SINCE_LOG" | wc -l)" 0

# Log --since with future timestamp (should return nothing)
FUTURE_LOG=$($AS log --since "2099-01-01T00:00:00Z" 2>&1 || true)
FUTURE_LINES=$(echo "$FUTURE_LOG" | grep -c "set-attr\|tag\|untag\|delete" || true)
assert_eq "log --since future returns no entries" "0" "$FUTURE_LINES"

# Log --json for structured output
LOG_JSON=$($AS log --json)
assert_contains "log json has entry_id" "$LOG_JSON" '"entry_id"'
assert_contains "log json has operation" "$LOG_JSON" '"operation"'

# ============================================================
# SECTION 6: Delete with cascade verification
# ============================================================
echo ""
echo "=== 6. DELETE WITH CASCADE ==="

# Count links to epic before delete
BEFORE_LINKS=$($AS query --linked-to "$EPIC_ID" --json)
BEFORE_COUNT=$(echo "$BEFORE_LINKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "3 tasks linked to epic before delete" "3" "$BEFORE_COUNT"

# Delete task 1
DEL_OUT=$($AS delete "$TASK1_ID" --json)
assert_contains "delete reports 1 deleted" "$DEL_OUT" '"deleted":1'

# Verify task 1 is gone
AFTER_COUNT=$($AS query --count)
assert_eq "4 entries after deleting task-1" "4" "$AFTER_COUNT"

# Verify link rows were cascade-removed
AFTER_LINKS=$($AS query --linked-to "$EPIC_ID" --json)
AFTER_LINK_COUNT=$(echo "$AFTER_LINKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "2 tasks linked to epic after delete" "2" "$AFTER_LINK_COUNT"

# Verify the blocks link from task2->task3 still exists
STILL_BLOCKS=$($AS query --linked-to "$TASK3_ID" --link-rel blocks --json)
STILL_COUNT=$(echo "$STILL_BLOCKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_eq "blocks link still exists" "1" "$STILL_COUNT"

# Verify changelog still shows deleted entry's history
DEL_LOG=$($AS log "$TASK1_ID")
assert_contains "changelog preserves deleted entry history" "$DEL_LOG" "delete"
assert_contains "changelog shows pre-delete mutations" "$DEL_LOG" "set-attr"

# ============================================================
# SECTION 7: Cross-feature interactions
# ============================================================
echo ""
echo "=== 7. CROSS-FEATURE INTERACTIONS ==="

# Tally reflects deletion (status counts should change)
STATUS_AFTER=$($AS tally --by "attr:status" --type task)
# task-1 (in-progress) was deleted, so only task-2 (in-progress) and task-3 (done) remain
IN_PROGRESS_LINE=$(echo "$STATUS_AFTER" | grep "in-progress" || true)
if [[ -n "$IN_PROGRESS_LINE" ]]; then
  IN_PROGRESS_COUNT=$(echo "$IN_PROGRESS_LINE" | awk '{print $NF}')
  assert_eq "tally shows 1 in-progress after delete" "1" "$IN_PROGRESS_COUNT"
else
  TESTS=$((TESTS + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: tally should still show in-progress"
fi

# Upsert + update combo: upsert creates, then update mutates
echo "redis://localhost:6379" | $AS push --upsert --label config --type config --attr key=cache-url --id-only >/dev/null
CACHE_ID=$($AS query --label config --attr key=cache-url --json | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
$AS update "$CACHE_ID" --tag production >/dev/null
CACHE_JSON=$($AS pull "$CACHE_ID" --json)
assert_contains "upserted+updated entry has production label" "$CACHE_JSON" '"production"'

# Log shows mutations from update command on upserted entry
CACHE_LOG=$($AS log "$CACHE_ID")
assert_contains "changelog tracks update on upserted entry" "$CACHE_LOG" "tag"

# Unlink command
$AS unlink "$TASK2_ID" "$TASK3_ID" blocks >/dev/null
AFTER_UNLINK=$($AS query --linked-to "$TASK3_ID" --link-rel blocks --json)
assert_eq "unlink removes blocks relationship" "[]" "$AFTER_UNLINK"

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
echo "  RESULTS: $PASS/$TESTS passed, $FAIL failed"
echo "========================================"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
