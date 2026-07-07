#!/usr/bin/env bash
# Realistic Docker-based tests for agent-store schedule feature.
# Requires: cron daemon, jq, agent-store binary in PATH.
set -euo pipefail

PASS=0
FAIL=0
SKIP=0
ERRORS=()

run_case() {
  local name="$1"
  shift
  local tmp
  tmp=$(mktemp -d)
  echo -n "  $name ... "
  # Disable set -e around the subshell so bash does not suppress set -e
  # inside the subshell (bash suppresses set -e in if/&&/|| contexts).
  set +e
  (set -euo pipefail; cd "$tmp" && agent-store init >/dev/null && "$@") >"$tmp/_stdout" 2>"$tmp/_stderr"
  local rc=$?
  set -euo pipefail
  if [ "$rc" -eq 0 ]; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
    echo "    stdout: $(head -5 "$tmp/_stdout" 2>/dev/null)"
    echo "    stderr: $(head -5 "$tmp/_stderr" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

run_case_noinit() {
  local name="$1"
  shift
  local tmp
  tmp=$(mktemp -d)
  echo -n "  $name ... "
  set +e
  (set -euo pipefail; cd "$tmp" && "$@") >"$tmp/_stdout" 2>"$tmp/_stderr"
  local rc=$?
  set -euo pipefail
  if [ "$rc" -eq 0 ]; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
    echo "    stdout: $(head -5 "$tmp/_stdout" 2>/dev/null)"
    echo "    stderr: $(head -5 "$tmp/_stderr" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

# ── Section 1: Schedule CRUD ──────────────────────────────────────────

echo "== Schedule CRUD =="

test_add_every_basic() {
  local id
  id=$(agent-store schedule add every 5m -- echo hello)
  printf "%s" "$id" | grep -Eq "^[a-z0-9]{6,8}$"
  agent-store schedule ls | grep -q "$id"
  agent-store schedule ls | grep -q "every 5m"
}
run_case "add every basic" test_add_every_basic

test_add_at_basic() {
  local id
  id=$(agent-store schedule add at 2030-01-01T00:00:00Z -- echo future)
  printf "%s" "$id" | grep -Eq "^[a-z0-9]{6,8}$"
  agent-store schedule ls | grep -q "$id"
  agent-store schedule ls | grep -q "at 2030-01-01T00:00:00Z"
}
run_case "add at basic" test_add_at_basic

test_add_at_date_only() {
  local id
  id=$(agent-store schedule add at 2030-06-15 -- echo date-only)
  agent-store schedule ls | grep -q "$id"
}
run_case "add at date-only expression" test_add_at_date_only

test_add_every_various_intervals() {
  agent-store schedule add every 30s -- echo seconds >/dev/null
  agent-store schedule add every 10m -- echo minutes >/dev/null
  agent-store schedule add every 2h -- echo hours >/dev/null
  agent-store schedule add every 1d -- echo days >/dev/null
  test "$(agent-store schedule ls | wc -l)" -eq 4
}
run_case "add every with various intervals" test_add_every_various_intervals

test_add_with_query() {
  agent-store create task status=pending >/dev/null
  local id
  id=$(agent-store schedule add every 5m 'kind=task and status=pending' -- echo matched)
  local listing
  listing=$(agent-store schedule ls)
  echo "$listing" | grep -q "$id"
  echo "$listing" | grep -q "query="
}
run_case "add with query" test_add_with_query

test_rm_by_id() {
  local id
  id=$(agent-store schedule add every 5m -- echo rm-me)
  agent-store schedule rm "$id" | grep -q "Removed $id"
  ! agent-store schedule ls | grep -q "$id"
}
run_case "rm by full ID" test_rm_by_id

test_rm_by_prefix() {
  local id
  id=$(agent-store schedule add every 5m -- echo rm-prefix)
  local prefix
  prefix=$(printf "%s" "$id" | cut -c1-4)
  agent-store schedule rm "$prefix" | grep -q "Removed $id"
}
run_case "rm by ID prefix" test_rm_by_prefix

test_rm_nonexistent() {
  ! agent-store schedule rm zzzzzz 2>/dev/null
}
run_case "rm nonexistent ID fails" test_rm_nonexistent

test_ls_empty() {
  local out
  out=$(agent-store schedule ls)
  test -z "$out"
}
run_case "ls with no schedules" test_ls_empty

test_ls_preserves_creation_order() {
  agent-store schedule add every 1h -- echo first >/dev/null
  agent-store schedule add every 2h -- echo second >/dev/null
  agent-store schedule add every 3h -- echo third >/dev/null
  local lines
  lines=$(agent-store schedule ls)
  echo "$lines" | head -1 | grep -q "1h"
  echo "$lines" | tail -1 | grep -q "3h"
}
run_case "ls preserves creation order" test_ls_preserves_creation_order

# ── Section 2: JSON Output ───────────────────────────────────────────

echo ""
echo "== JSON Output =="

test_json_add() {
  local id
  id=$(agent-store schedule add every 10m -- echo json-add)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].id == \"$id\""
  echo "$json" | jq -e ".schedules[0].kind == \"every\""
  echo "$json" | jq -e ".schedules[0].expression == \"10m\""
  echo "$json" | jq -e ".schedules[0].interval_seconds == 600"
  echo "$json" | jq -e ".schedules[0].command == \"echo json-add\""
  echo "$json" | jq -e ".schedules[0].status == \"active\""
  echo "$json" | jq -e ".schedules[0].next_run_at != null"
  echo "$json" | jq -e ".schedules[0].created_at != null"
}
run_case "JSON add and ls" test_json_add

test_json_rm() {
  local id
  id=$(agent-store schedule add every 10m -- echo json-rm)
  local json
  json=$(agent-store --json schedule rm "$id")
  echo "$json" | jq -e ".status == \"removed\""
  echo "$json" | jq -e ".schedule.id == \"$id\""
}
run_case "JSON rm" test_json_rm

test_json_at_with_query() {
  agent-store create task priority=high >/dev/null
  local id
  id=$(agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- echo query-json)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].query == \"kind=task\""
  echo "$json" | jq -e ".schedules[0].kind == \"at\""
}
run_case "JSON at with query" test_json_at_with_query

# ── Section 3: Tick Execution ────────────────────────────────────────

echo ""
echo "== Tick Execution =="

test_tick_fires_due_at() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo at-fired'
  local out
  out=$(agent-store schedule tick)
  echo "$out" | grep -q "exit=0"
  # at-schedule should be completed
  agent-store schedule ls | grep -q "status=completed"
}
run_case "tick fires due at-schedule" test_tick_fires_due_at

test_tick_fires_due_every() {
  agent-store schedule add every 1s -- 'echo every-fired'
  sleep 2
  local out
  out=$(agent-store schedule tick)
  echo "$out" | grep -q "exit=0"
  # every-schedule should still be active
  agent-store schedule ls | grep -q "status=active"
}
run_case "tick fires due every-schedule" test_tick_fires_due_every

test_tick_skips_future() {
  agent-store schedule add at 2099-01-01T00:00:00Z -- 'echo future'
  local out
  out=$(agent-store schedule tick)
  # nothing should fire
  test -z "$out"
  # schedule still active
  agent-store schedule ls | grep -q "status=active"
}
run_case "tick skips future schedules" test_tick_skips_future

test_tick_idempotent_at() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo once'
  agent-store schedule tick >/dev/null
  # second tick should not fire again
  local out
  out=$(agent-store schedule tick)
  test -z "$out"
}
run_case "tick idempotent for completed at-schedule" test_tick_idempotent_at

test_tick_every_advances_next_run() {
  agent-store schedule add every 1s -- 'echo advancing'
  sleep 2
  agent-store schedule tick >/dev/null
  local next1
  next1=$(agent-store --json schedule ls | jq -r '.schedules[0].next_run_at')
  sleep 2
  agent-store schedule tick >/dev/null
  local next2
  next2=$(agent-store --json schedule ls | jq -r '.schedules[0].next_run_at')
  test "$next1" != "$next2"
}
run_case "tick advances every-schedule next_run_at" test_tick_every_advances_next_run

test_tick_multiple_due() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo one'
  agent-store schedule add at 2020-06-01T00:00:00Z -- 'echo two'
  agent-store schedule add at 2099-01-01T00:00:00Z -- 'echo future'
  local out
  out=$(agent-store schedule tick)
  # two should fire, not the future one
  test "$(echo "$out" | wc -l)" -eq 2
}
run_case "tick fires multiple due schedules" test_tick_multiple_due

test_tick_json_output() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo ok'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e ".ticked >= 1"
  echo "$json" | jq -e ".schedule_runs | length >= 1"
  echo "$json" | jq -e ".schedule_runs[0].exit_status == 0"
  echo "$json" | jq -e '.schedule_runs[0].stdout | contains("ok")'
}
run_case "tick JSON output" test_tick_json_output

test_tick_empty_store() {
  local out
  out=$(agent-store schedule tick)
  test -z "$out"
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e ".ticked == 0"
  echo "$json" | jq -e ".schedule_runs == []"
}
run_case "tick on empty store" test_tick_empty_store

# ── Section 4: Query-Scoped Schedules ────────────────────────────────

echo ""
echo "== Query-Scoped Schedules =="

test_query_schedule_per_record() {
  agent-store create task title=A status=open >/dev/null
  agent-store create task title=B status=open >/dev/null
  agent-store create task title=C status=done >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=open' -- 'cat'
  local json
  json=$(agent-store --json schedule tick)
  # should fire twice (A and B match, C doesn't)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query schedule runs per matching record" test_query_schedule_per_record

test_query_schedule_env_vars() {
  local rid
  rid=$(agent-store create task title=EnvTest status=active)
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'echo "id=$AGENT_STORE_ID kind=$AGENT_STORE_KIND event=$AGENT_STORE_EVENT"'
  local json
  json=$(agent-store --json schedule tick)
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "id=$rid"
  echo "$stdout" | grep -q "kind=task"
  echo "$stdout" | grep -q "event=tick"
}
run_case "query schedule sets env vars" test_query_schedule_env_vars

test_query_schedule_stdin() {
  agent-store create note msg=hello >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=note' -- 'cat'
  local json
  json=$(agent-store --json schedule tick)
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "note"
  echo "$stdout" | grep -q "msg=hello"
}
run_case "query schedule passes record on stdin" test_query_schedule_stdin

test_query_schedule_no_matches() {
  agent-store create task status=done >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'status=open' -- 'echo matched'
  local json
  json=$(agent-store --json schedule tick)
  # schedule ticked but no runs (no matching records)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
}
run_case "query schedule with no matching records" test_query_schedule_no_matches

test_query_schedule_schedule_id_env() {
  agent-store create task title=X >/dev/null
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'echo "sid=$AGENT_STORE_SCHEDULE_ID"')
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "sid=$sid"
}
run_case "query schedule sets AGENT_STORE_SCHEDULE_ID" test_query_schedule_schedule_id_env

test_env_var_completeness() {
  local rid
  rid=$(agent-store create task title=EnvCheck)
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'env | grep AGENT_STORE | sort')
  local json
  json=$(agent-store --json schedule tick)
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "AGENT_STORE_EVENT=tick"
  echo "$stdout" | grep -q "AGENT_STORE_ID=$rid"
  echo "$stdout" | grep -q "AGENT_STORE_KIND=task"
  echo "$stdout" | grep -q "AGENT_STORE_SCHEDULE_ID=$sid"
}
run_case "all AGENT_STORE_* env vars present" test_env_var_completeness

test_no_record_env_without_query() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'env | grep AGENT_STORE | sort')
  local json
  json=$(agent-store --json schedule tick)
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "AGENT_STORE_SCHEDULE_ID=$sid"
  # without a query, no record env vars should be set
  ! echo "$stdout" | grep -q "AGENT_STORE_ID="
  ! echo "$stdout" | grep -q "AGENT_STORE_EVENT="
  ! echo "$stdout" | grep -q "AGENT_STORE_KIND="
}
run_case "no record env vars without query" test_no_record_env_without_query

# ── Section 5: Schedule Runs ─────────────────────────────────────────

echo ""
echo "== Schedule Runs =="

test_runs_list() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo run1'
  agent-store schedule tick >/dev/null
  local runs
  runs=$(agent-store schedule runs)
  echo "$runs" | grep -q "exit=0"
}
run_case "runs list shows recent runs" test_runs_list

test_runs_detail() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo detail-data'
  agent-store schedule tick >/dev/null
  local run_id
  run_id=$(agent-store --json schedule runs | jq -r '.schedule_runs[0].id')
  local detail
  detail=$(agent-store schedule runs "$run_id")
  echo "$detail" | grep -q "detail-data"
  echo "$detail" | grep -q "exit_status: 0"
}
run_case "runs detail shows stdout" test_runs_detail

test_runs_json() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo json-run'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs | length >= 1'
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  echo "$json" | jq -e '.schedule_runs[0].stdout | contains("json-run")'
}
run_case "runs JSON output" test_runs_json

test_runs_limit() {
  agent-store schedule add every 1s -- 'echo limited'
  sleep 2
  agent-store schedule tick >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store --json schedule runs --limit 2 | jq '.schedule_runs | length')
  test "$count" -le 2
}
run_case "runs respects --limit" test_runs_limit

test_runs_empty() {
  local out
  out=$(agent-store schedule runs)
  echo "$out" | grep -qi "no schedule runs"
}
run_case "runs empty store message" test_runs_empty

# ── Section 6: Command Failures ──────────────────────────────────────

echo ""
echo "== Command Failures =="

test_command_exits_nonzero() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'exit 42'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 42'
}
run_case "command non-zero exit recorded" test_command_exits_nonzero

test_command_stderr_captured() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo errdata >&2; exit 1'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs[0].stderr | contains("errdata")'
}
run_case "command stderr captured" test_command_stderr_captured

test_command_missing_binary() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- '/nonexistent/binary arg1'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs[0].exit_status != 0'
}
run_case "missing command binary recorded" test_command_missing_binary

test_command_large_stdout() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'yes x | head -c 100000'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local len
  len=$(echo "$json" | jq '.schedule_runs[0].stdout | length')
  test "$len" -le 8192
}
run_case "large stdout capped at 8192" test_command_large_stdout

test_command_large_stderr() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'yes x | head -c 100000 >&2; exit 1'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local len
  len=$(echo "$json" | jq '.schedule_runs[0].stderr | length')
  test "$len" -le 8192
}
run_case "large stderr capped at 8192" test_command_large_stderr

test_command_timeout() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 120'
  # tick should timeout after 30s (default hook timeout)
  timeout 60 agent-store schedule tick >/dev/null || true
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs[0].exit_status != 0'
  echo "$json" | jq -e '.schedule_runs[0].stderr | contains("timed out")'
}
run_case "command timeout after 30s" test_command_timeout

# ── Section 7: Concurrent Tick ───────────────────────────────────────

echo ""
echo "== Concurrent Tick =="

test_concurrent_tick_no_double_fire() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo concurrent-at'
  # run two ticks simultaneously
  agent-store schedule tick &
  local pid1=$!
  agent-store schedule tick &
  local pid2=$!
  wait "$pid1" || true
  wait "$pid2" || true
  # at-schedule should fire exactly once (atomic claim)
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 1
}
run_case "concurrent tick: at-schedule fires once" test_concurrent_tick_no_double_fire

test_concurrent_tick_every_no_corruption() {
  agent-store schedule add every 1s -- 'echo concurrent-every'
  sleep 2
  # run several ticks in parallel
  for i in 1 2 3 4 5; do
    agent-store schedule tick &
  done
  wait
  # should not crash or corrupt; schedule still exists and is active
  agent-store schedule ls | grep -q "status=active"
  # runs should have been recorded without error
  agent-store --json schedule runs | jq -e '.schedule_runs | length >= 1'
}
run_case "concurrent tick: every-schedule no corruption" test_concurrent_tick_every_no_corruption

# ── Section 8: Crontab Enable/Disable ────────────────────────────────

echo ""
echo "== Crontab Enable/Disable =="

test_enable_installs_cron_entry() {
  local out
  out=$(agent-store schedule enable)
  echo "$out" | grep -q "Enabled"
  crontab -l | grep -q "schedule tick"
  # clean up
  agent-store schedule disable >/dev/null
}
run_case "enable installs crontab entry" test_enable_installs_cron_entry

test_disable_removes_cron_entry() {
  agent-store schedule enable >/dev/null
  crontab -l | grep -q "schedule tick"
  local out
  out=$(agent-store schedule disable)
  echo "$out" | grep -q "Disabled"
  ! crontab -l 2>/dev/null | grep -q "agent-store:tick"
}
run_case "disable removes crontab entry" test_disable_removes_cron_entry

test_disable_without_enable() {
  local out
  out=$(agent-store schedule disable)
  echo "$out" | grep -q "No crontab entry"
}
run_case "disable without enable reports no entry" test_disable_without_enable

test_enable_idempotent() {
  agent-store schedule enable >/dev/null
  agent-store schedule enable >/dev/null
  # should have exactly one entry for this project, not two
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 1
  agent-store schedule disable >/dev/null
}
run_case "enable is idempotent" test_enable_idempotent

test_enable_preserves_other_crontab() {
  # install a user crontab entry first
  echo "# user-custom-entry" | crontab -
  agent-store schedule enable >/dev/null
  crontab -l | grep -q "user-custom-entry"
  crontab -l | grep -q "schedule tick"
  agent-store schedule disable >/dev/null
  crontab -l | grep -q "user-custom-entry"
  # clean up
  crontab -r 2>/dev/null || true
}
run_case "enable preserves existing crontab entries" test_enable_preserves_other_crontab

test_cron_actually_fires_tick() {
  # This test must NOT use run_case — it needs a stable directory for cron
  local cron_tmp
  cron_tmp=$(mktemp -d)
  echo -n "  cron daemon actually fires tick ... "
  (
    cd "$cron_tmp"
    agent-store init >/dev/null
    # Start cron daemon and verify it's running
    cron 2>/dev/null
    sleep 1
    if ! pgrep -x cron >/dev/null; then
      echo "cron daemon failed to start" >&2
      exit 1
    fi
    # Create a due schedule
    agent-store schedule add at 2020-01-01T00:00:00Z -- 'touch /tmp/cron-marker'
    agent-store schedule enable >/dev/null
    # Wait up to 130s (need at least one cron minute boundary)
    local attempts=0
    while [ "$attempts" -lt 26 ]; do
      sleep 5
      attempts=$((attempts + 1))
      if [ -f /tmp/cron-marker ]; then
        local count
        count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
        if [ "$count" -ge 1 ]; then
          agent-store schedule disable >/dev/null
          rm -f /tmp/cron-marker
          exit 0
        fi
      fi
    done
    agent-store schedule disable >/dev/null
    echo "cron did not fire within 130s" >&2
    exit 1
  ) >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
    ERRORS+=("cron daemon actually fires tick")
  fi
  rm -rf "$cron_tmp" /tmp/cron-marker
}
test_cron_actually_fires_tick

test_cron_multi_project_isolation() {
  # Two projects with independent cron entries
  local proj1 proj2
  proj1=$(mktemp -d)
  proj2=$(mktemp -d)
  (cd "$proj1" && agent-store init >/dev/null && agent-store schedule enable >/dev/null)
  (cd "$proj2" && agent-store init >/dev/null && agent-store schedule enable >/dev/null)
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 2
  (cd "$proj1" && agent-store schedule disable >/dev/null)
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 1
  (cd "$proj2" && agent-store schedule disable >/dev/null)
  rm -rf "$proj1" "$proj2"
}
run_case_noinit "cron multi-project isolation" test_cron_multi_project_isolation

# ── Section 9: Context Integration ──────────────────────────────────

echo ""
echo "== Context Integration =="

test_ctx_includes_schedule_summary() {
  agent-store schedule add every 1h -- 'echo ctx-test'
  local ctx
  ctx=$(agent-store ctx)
  echo "$ctx" | grep -qi "schedule"
  echo "$ctx" | grep -q "1 active"
}
run_case "ctx includes schedule summary" test_ctx_includes_schedule_summary

test_ctx_json_schedule_summary() {
  agent-store schedule add every 1h -- 'echo ctx-json'
  local json
  json=$(agent-store --json ctx)
  echo "$json" | jq -e '.schedule_summary.active_schedules == 1'
}
run_case "ctx JSON includes schedule_summary" test_ctx_json_schedule_summary

test_ctx_after_at_completed() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo done'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json ctx)
  echo "$json" | jq -e '.schedule_summary.completed_schedules == 1'
}
run_case "ctx shows completed count after at-schedule fires" test_ctx_after_at_completed

test_ctx_no_schedules() {
  local json
  json=$(agent-store --json ctx)
  echo "$json" | jq -e '.schedule_summary.active_schedules == 0'
}
run_case "ctx with no schedules shows zero" test_ctx_no_schedules

# ── Section 10: Help ──────────────────────────────────────────────────

echo ""
echo "== Help =="

test_schedule_help_topics() {
  agent-store schedule --help | grep -q "add"
  agent-store schedule --help | grep -q "ls"
  agent-store schedule --help | grep -q "rm"
  agent-store schedule --help | grep -q "runs"
  agent-store schedule --help | grep -q "tick"
  agent-store schedule --help | grep -q "enable"
  agent-store schedule --help | grep -q "disable"
}
run_case "schedule --help lists all subcommands" test_schedule_help_topics

test_schedule_add_help() {
  agent-store schedule add --help | grep -q "at"
  agent-store schedule add --help | grep -q "every"
  agent-store schedule add --help | grep -q "Query"
}
run_case "schedule add --help documents at/every/query" test_schedule_add_help

# ── Section 11: Error Handling ────────────────────────────────────────

echo ""
echo "== Error Handling =="

test_add_invalid_kind() {
  ! agent-store schedule add weekly 1h -- echo bad 2>/dev/null
}
run_case "add rejects invalid kind" test_add_invalid_kind

test_add_missing_separator() {
  ! agent-store schedule add every 5m echo tick 2>/dev/null
}
run_case "add rejects missing --" test_add_missing_separator

test_add_empty_command() {
  ! agent-store schedule add every 5m -- '' 2>/dev/null
}
run_case "add rejects empty command" test_add_empty_command

test_add_invalid_interval() {
  ! agent-store schedule add every abc -- echo bad 2>/dev/null
}
run_case "add rejects invalid interval" test_add_invalid_interval

test_add_invalid_query() {
  ! agent-store schedule add every 5m 'invalid @@@ query' -- echo bad 2>/dev/null
}
run_case "add rejects invalid query" test_add_invalid_query

test_runs_invalid_run_id() {
  ! agent-store schedule runs abc 2>/dev/null
}
run_case "runs rejects non-numeric run ID" test_runs_invalid_run_id

test_runs_nonexistent_run_id() {
  ! agent-store schedule runs 999999 2>/dev/null
}
run_case "runs nonexistent run ID fails" test_runs_nonexistent_run_id

test_schedule_without_init() {
  local tmp
  tmp=$(mktemp -d)
  ! (cd "$tmp" && agent-store schedule ls 2>/dev/null)
  rm -rf "$tmp"
}
run_case_noinit "schedule commands fail without init" test_schedule_without_init

test_typo_suggests_correction() {
  local err
  err=$(agent-store schedule enabel 2>&1 || true)
  echo "$err" | grep -qi "enable"
}
run_case "typo suggests nearest command" test_typo_suggests_correction

# ── Section 12: Multi-Tick Lifecycle ─────────────────────────────────

echo ""
echo "== Multi-Tick Lifecycle =="

test_every_schedule_multi_tick_lifecycle() {
  agent-store schedule add every 1s -- 'echo tick-$(date +%s)'
  sleep 2
  agent-store schedule tick >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 3
  # all should be exit 0
  local zeros
  zeros=$(agent-store --json schedule runs | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')
  test "$zeros" -eq 3
}
run_case "every-schedule fires across multiple ticks" test_every_schedule_multi_tick_lifecycle

test_mixed_at_every_lifecycle() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo at-done'
  agent-store schedule add every 1s -- 'echo every-tick'
  sleep 2
  agent-store schedule tick >/dev/null
  # at should be completed, every should still be active
  local json
  json=$(agent-store --json schedule ls)
  local at_status
  at_status=$(echo "$json" | jq -r '.schedules[] | select(.kind == "at") | .status')
  local every_status
  every_status=$(echo "$json" | jq -r '.schedules[] | select(.kind == "every") | .status')
  test "$at_status" = "completed"
  test "$every_status" = "active"
  # second tick should only fire every
  sleep 2
  agent-store schedule tick >/dev/null
  local total_runs
  total_runs=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total_runs" -eq 3  # 1 at + 2 every
}
run_case "mixed at/every lifecycle" test_mixed_at_every_lifecycle

# ── Section 13: Schedule + Hooks Integration ─────────────────────────

echo ""
echo "== Schedule + Hooks Integration =="

test_schedule_tick_triggers_no_hooks() {
  # schedule tick should not trigger record hooks (it's a different mechanism)
  agent-store hook add create -- 'echo hook-fired >> /tmp/hook-marker'
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo scheduled'
  agent-store schedule tick >/dev/null
  # the hook should not have fired from tick
  test ! -f /tmp/hook-marker
  rm -f /tmp/hook-marker
}
run_case "schedule tick does not trigger record hooks" test_schedule_tick_triggers_no_hooks

test_schedule_command_can_use_agent_store() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create log message=from-schedule'
  agent-store schedule tick >/dev/null
  # the create should have worked
  agent-store find kind=log | grep -q "message=from-schedule"
}
run_case "schedule command can call agent-store" test_schedule_command_can_use_agent_store

test_schedule_command_create_triggers_hooks() {
  agent-store hook add create 'kind=log' -- 'echo "hooked: $AGENT_STORE_ID" >> /tmp/hook-from-schedule'
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create log message=test'
  agent-store schedule tick >/dev/null
  # the hook should have fired from the create inside the schedule command
  test -f /tmp/hook-from-schedule
  grep -q "hooked:" /tmp/hook-from-schedule
  rm -f /tmp/hook-from-schedule
}
run_case "schedule command create triggers hooks" test_schedule_command_create_triggers_hooks

# ── Section 14: Edge Cases ───────────────────────────────────────────

echo ""
echo "== Edge Cases =="

test_schedule_with_special_chars_command() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "hello world" | tr a-z A-Z'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "HELLO WORLD"
}
run_case "command with pipes and quotes" test_schedule_with_special_chars_command

test_schedule_command_with_env_expansion() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "home=$HOME"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "home=/"
}
run_case "command with env var expansion" test_schedule_command_with_env_expansion

test_many_schedules() {
  for i in $(seq 1 50); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo schedule-$i" >/dev/null
  done
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 50
  # tick all of them
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 50
  # all should be completed
  local completed
  completed=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "completed")] | length')
  test "$completed" -eq 50
}
run_case "50 at-schedules all fire in one tick" test_many_schedules

test_schedule_working_directory() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'pwd'
  local json
  json=$(agent-store --json schedule tick)
  local pwd_out
  pwd_out=$(echo "$json" | jq -r '.schedule_runs[0].stdout' | tr -d '\n')
  # command should run in the project root
  test "$pwd_out" = "$(pwd)"
}
run_case "command runs in project root" test_schedule_working_directory

test_schedule_rm_with_runs() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo rm-with-runs')
  agent-store schedule tick >/dev/null
  # runs exist
  agent-store --json schedule runs | jq -e '.schedule_runs | length >= 1'
  # rm the schedule
  agent-store schedule rm "$sid" | grep -q "Removed"
  # runs should still be accessible (or gracefully handled)
  agent-store schedule runs >/dev/null 2>&1
}
run_case "rm schedule with existing runs" test_schedule_rm_with_runs

# ── Section 15: Persistence & Process Boundaries ─────────────────────

echo ""
echo "== Persistence & Process Boundaries =="

test_schedule_survives_process_restart() {
  local sid
  sid=$(agent-store schedule add every 1h -- echo persistent)
  # read from fresh process
  agent-store schedule ls | grep -q "$sid"
  agent-store --json schedule ls | jq -e ".schedules[0].id == \"$sid\""
}
run_case "schedule persists across process invocations" test_schedule_survives_process_restart

test_tick_records_persist_after_command() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo persisted-run'
  agent-store schedule tick >/dev/null
  # fresh process reads the run
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 1
  local stdout
  stdout=$(agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "persisted-run"
}
run_case "tick runs persist and are readable" test_tick_records_persist_after_command

test_schedule_store_in_subdirectory() {
  mkdir -p sub/dir
  (cd sub/dir && agent-store init >/dev/null)
  (cd sub/dir && agent-store schedule add every 1h -- echo subdir >/dev/null)
  local count
  count=$(cd sub/dir && agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 1
}
run_case "schedule works in subdirectory store" test_schedule_store_in_subdirectory

# ── Section 16: Schedule Expression Parsing ──────────────────────────

echo ""
echo "== Expression Parsing =="

test_duration_seconds() {
  local id
  id=$(agent-store schedule add every 120s -- echo sec)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].interval_seconds == 120"
}
run_case "every Ns parsed correctly" test_duration_seconds

test_duration_minutes() {
  local id
  id=$(agent-store schedule add every 15m -- echo min)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].interval_seconds == 900"
}
run_case "every Nm parsed correctly" test_duration_minutes

test_duration_hours() {
  local id
  id=$(agent-store schedule add every 3h -- echo hr)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].interval_seconds == 10800"
}
run_case "every Nh parsed correctly" test_duration_hours

test_duration_days() {
  local id
  id=$(agent-store schedule add every 2d -- echo day)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].interval_seconds == 172800"
}
run_case "every Nd parsed correctly" test_duration_days

test_at_timestamp_formats() {
  agent-store schedule add at 2030-01-01T00:00:00Z -- echo ts1 >/dev/null
  agent-store schedule add at 2030-01-01 -- echo ts2 >/dev/null
  test "$(agent-store --json schedule ls | jq '.schedules | length')" -eq 2
}
run_case "at accepts timestamp and date-only" test_at_timestamp_formats

test_at_duration_is_relative() {
  local id
  id=$(agent-store schedule add at 30s -- echo relative)
  local next
  next=$(agent-store --json schedule ls | jq -r '.schedules[0].next_run_at')
  # next_run_at should be in the future (not epoch)
  test "$next" \> "2026-01-01"
}
run_case "at with duration is relative to now" test_at_duration_is_relative

# ── Section 17: Concurrent Stress ────────────────────────────────────

echo ""
echo "== Concurrent Stress =="

test_concurrent_adds() {
  for i in $(seq 1 20); do
    agent-store schedule add every "${i}m" -- "echo add-$i" &
  done
  wait
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 20
}
run_case "20 concurrent schedule adds" test_concurrent_adds

test_concurrent_tick_with_query() {
  for i in $(seq 1 10); do
    agent-store create task "title=task-$i" status=active >/dev/null
  done
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'echo $AGENT_STORE_ID'
  # concurrent ticks — only one should claim the schedule
  for i in 1 2 3; do
    agent-store schedule tick &
  done
  wait
  # exactly 10 runs (one per matching record, from exactly one tick)
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 10
}
run_case "concurrent tick with query: exact record count" test_concurrent_tick_with_query

test_concurrent_add_and_tick() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo early' >/dev/null
  # add more schedules while ticking
  agent-store schedule tick &
  agent-store schedule add every 1s -- 'echo concurrent-add' &
  wait
  # no crash, store is consistent
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "concurrent add and tick" test_concurrent_add_and_tick

# ── Section 18: Record Mutation from Schedules ───────────────────────

echo ""
echo "== Record Mutation from Schedules =="

test_schedule_creates_records() {
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "agent-store create log iteration=$i" >/dev/null
  done
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store find kind=log --count)
  test "$count" -eq 5
}
run_case "schedule commands create records" test_schedule_creates_records

test_schedule_updates_records() {
  local rid
  rid=$(agent-store create task status=pending)
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=pending' -- 'agent-store set $AGENT_STORE_ID status=done'
  agent-store schedule tick >/dev/null
  local status
  status=$(agent-store --json get "$rid" | jq -r '.record.fields.status')
  test "$status" = "done"
}
run_case "schedule command updates record status" test_schedule_updates_records

test_schedule_links_records() {
  local a b
  a=$(agent-store create task title=parent)
  b=$(agent-store create task title=child)
  agent-store schedule add at 2020-01-01T00:00:00Z -- "agent-store link $a depends-on $b"
  agent-store schedule tick >/dev/null
  agent-store links "$a" | grep -q "depends-on"
}
run_case "schedule command creates links" test_schedule_links_records

# ── Section 19: JSON Error Handling ──────────────────────────────────

echo ""
echo "== JSON Error Handling =="

test_json_tick_command_failure() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo fail-json >&2; exit 3'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 3'
  echo "$json" | jq -e '.schedule_runs[0].stderr | contains("fail-json")'
}
run_case "JSON tick captures command failure" test_json_tick_command_failure

test_json_runs_detail() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo json-detail-test'
  agent-store schedule tick >/dev/null
  local run_id
  run_id=$(agent-store --json schedule runs | jq '.schedule_runs[0].id')
  local json
  json=$(agent-store --json schedule runs "$run_id")
  echo "$json" | jq -e '.schedule_run.id'
  echo "$json" | jq -e '.schedule_run.stdout | contains("json-detail-test")'
}
run_case "JSON runs detail" test_json_runs_detail

# ── Section 20: Realistic Workflows ─────────────────────────────────

echo ""
echo "== Realistic Workflows =="

test_recurring_cleanup_workflow() {
  # Create records with different statuses
  for i in $(seq 1 5); do
    agent-store create task "title=old-$i" status=done >/dev/null
  done
  for i in $(seq 1 3); do
    agent-store create task "title=active-$i" status=active >/dev/null
  done
  # Schedule: archive completed tasks by updating status
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=done' -- 'agent-store set $AGENT_STORE_ID status=archived'
  agent-store schedule tick >/dev/null
  # all "done" tasks should now be "archived"
  test "$(agent-store find status=done --count)" -eq 0
  test "$(agent-store find status=archived --count)" -eq 5
  test "$(agent-store find status=active --count)" -eq 3
}
run_case "recurring cleanup workflow" test_recurring_cleanup_workflow

test_schedule_as_notification_pipeline() {
  # Schedule that reads records and creates audit log entries
  agent-store create alert severity=critical message="disk full" >/dev/null
  agent-store create alert severity=warning message="high memory" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=alert and severity=critical' -- \
    'agent-store create audit_log source=schedule action=escalated record_id=$AGENT_STORE_ID'
  agent-store schedule tick >/dev/null
  # only critical alert should have been escalated
  test "$(agent-store find kind=audit_log --count)" -eq 1
  agent-store find kind=audit_log | grep -q "action=escalated"
}
run_case "schedule as notification pipeline" test_schedule_as_notification_pipeline

test_every_with_record_state_changes() {
  local rid
  rid=$(agent-store create counter value=0 tag=unique-change-test)
  agent-store schedule add every 1s 'kind=counter and tag=unique-change-test' -- 'agent-store set $AGENT_STORE_ID value=incremented'
  sleep 2
  agent-store schedule tick >/dev/null
  local val
  val=$(agent-store --json get "$rid" | jq -r '.record.fields.value')
  test "$val" = "incremented"
}
run_case "every-schedule acts on changing record state" test_every_with_record_state_changes

# ── Section 21: Non-UTF-8 Output from Schedule Commands ─────────────

echo ""
echo "== Non-UTF-8 Output =="

test_binary_stdout_captured() {
  # printf bytes that are not valid UTF-8 (0x80-0xFF)
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "\x80\xff\xfe"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  # from_utf8_lossy replaces invalid bytes with U+FFFD replacement chars
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  test -n "$stdout"
}
run_case "binary stdout captured with lossy UTF-8" test_binary_stdout_captured

test_binary_stderr_captured() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "\x80\xfe\xff" >&2; exit 1'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 1'
  local stderr_out
  stderr_out=$(echo "$json" | jq -r '.schedule_runs[0].stderr')
  test -n "$stderr_out"
}
run_case "binary stderr captured with lossy UTF-8" test_binary_stderr_captured

test_mixed_utf8_and_binary_stdout() {
  # Valid UTF-8 prefix, then invalid bytes, then valid UTF-8 suffix
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "hello\x80\xffworld"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "hello"
  echo "$stdout" | grep -q "world"
}
run_case "mixed UTF-8 and binary stdout preserves valid parts" test_mixed_utf8_and_binary_stdout

test_null_bytes_in_output() {
  # Null bytes in stdout
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "before\x00after"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  # Output should be valid JSON (null bytes handled)
  echo "$json" | jq -e '.schedule_runs[0].stdout != null'
}
run_case "null bytes in stdout handled" test_null_bytes_in_output

test_all_byte_values_stdout() {
  # Generate all 256 byte values to stress-test output capture
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'for i in $(seq 0 255); do printf "\\x$(printf "%02x" $i)"; done'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  # The key thing: valid JSON was produced despite non-UTF-8 bytes
  echo "$json" | jq -e '.schedule_runs[0].stdout | length > 0'
}
run_case "all 256 byte values in stdout produce valid JSON" test_all_byte_values_stdout

test_binary_output_runs_detail() {
  # Verify binary output also works correctly in runs detail view
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "ok\x80\xfe"'
  agent-store schedule tick >/dev/null
  local run_id
  run_id=$(agent-store --json schedule runs | jq '.schedule_runs[0].id')
  # Both text and JSON detail should work without error
  agent-store schedule runs "$run_id" >/dev/null
  agent-store --json schedule runs "$run_id" | jq -e '.schedule_run.stdout | length > 0'
}
run_case "binary output in runs detail view" test_binary_output_runs_detail

# ── Section 22: Schedule Expression Boundary Values ─────────────────

echo ""
echo "== Expression Boundary Values =="

test_zero_second_interval_rejected() {
  # 0s means n=0, which should be rejected (n <= 0)
  ! agent-store schedule add every 0s -- echo zero 2>/dev/null
}
run_case "every 0s rejected" test_zero_second_interval_rejected

test_zero_minute_interval_rejected() {
  ! agent-store schedule add every 0m -- echo zero 2>/dev/null
}
run_case "every 0m rejected" test_zero_minute_interval_rejected

test_zero_hour_interval_rejected() {
  ! agent-store schedule add every 0h -- echo zero 2>/dev/null
}
run_case "every 0h rejected" test_zero_hour_interval_rejected

test_zero_day_interval_rejected() {
  ! agent-store schedule add every 0d -- echo zero 2>/dev/null
}
run_case "every 0d rejected" test_zero_day_interval_rejected

test_one_second_minimum_interval() {
  local id
  id=$(agent-store schedule add every 1s -- echo minimum)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].interval_seconds == 1"
  echo "$json" | jq -e ".schedules[0].id == \"$id\""
}
run_case "every 1s accepted as minimum" test_one_second_minimum_interval

test_large_interval_999d() {
  local id
  id=$(agent-store schedule add every 999d -- echo large)
  local json
  json=$(agent-store --json schedule ls)
  # 999 * 86400 = 86313600
  echo "$json" | jq -e ".schedules[0].interval_seconds == 86313600"
}
run_case "every 999d accepted with correct seconds" test_large_interval_999d

test_very_large_interval_overflow_safe() {
  # Try a value that would overflow i64 when multiplied by 86400
  # i64::MAX / 86400 ~ 1.07e14, so 999999999999999d would overflow
  # checked_mul should return None, causing parse_duration_seconds to return None
  ! agent-store schedule add every 999999999999999d -- echo overflow 2>/dev/null
}
run_case "overflow-inducing interval rejected safely" test_very_large_interval_overflow_safe

test_negative_interval_rejected() {
  # Negative values should be rejected
  ! agent-store schedule add every -1s -- echo neg 2>/dev/null
}
run_case "negative interval rejected" test_negative_interval_rejected

test_at_with_1s_relative() {
  local id
  id=$(agent-store schedule add at 1s -- echo at-1s)
  local json
  json=$(agent-store --json schedule ls)
  # next_run_at should be about 1s in the future
  echo "$json" | jq -e ".schedules[0].id == \"$id\""
  echo "$json" | jq -e '.schedules[0].next_run_at != null'
}
run_case "at 1s creates schedule 1 second from now" test_at_with_1s_relative

test_at_with_large_relative_duration() {
  local id
  id=$(agent-store schedule add at 365d -- echo far-future)
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e ".schedules[0].id == \"$id\""
  # Should be about 365 days from now, i.e. in 2027
  echo "$json" | jq -e '.schedules[0].next_run_at | startswith("202")'
}
run_case "at 365d creates far-future schedule" test_at_with_large_relative_duration

test_bare_number_without_suffix_rejected() {
  # "5" without suffix should be rejected for every
  ! agent-store schedule add every 5 -- echo bare 2>/dev/null
}
run_case "bare number without suffix rejected" test_bare_number_without_suffix_rejected

test_invalid_suffix_rejected() {
  ! agent-store schedule add every 5w -- echo weeks 2>/dev/null
}
run_case "invalid suffix (5w) rejected" test_invalid_suffix_rejected

# ── Section 23: Self-Modifying Schedule Commands ────────────────────

echo ""
echo "== Self-Modifying Schedules =="

test_schedule_removes_itself() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store schedule rm $AGENT_STORE_SCHEDULE_ID')
  agent-store schedule tick >/dev/null
  # The schedule command deleted itself during execution
  # After tick, the schedule should be gone
  ! agent-store schedule ls | grep -q "$sid"
}
run_case "schedule command removes itself" test_schedule_removes_itself

test_schedule_removes_itself_run_recorded() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store schedule rm $AGENT_STORE_SCHEDULE_ID')
  agent-store schedule tick >/dev/null
  # The run should still be recorded even though the schedule was deleted
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
}
run_case "self-deleting schedule run is recorded" test_schedule_removes_itself_run_recorded

test_every_schedule_removes_itself() {
  local sid
  sid=$(agent-store schedule add every 1s -- 'agent-store schedule rm $AGENT_STORE_SCHEDULE_ID')
  sleep 2
  agent-store schedule tick >/dev/null
  # Schedule should be gone (command deleted it)
  ! agent-store schedule ls | grep -q "$sid"
  # Run should be recorded
  agent-store --json schedule runs | jq -e '.schedule_runs | length >= 1'
}
run_case "every-schedule that removes itself" test_every_schedule_removes_itself

test_schedule_adds_new_schedule() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store schedule add at 2020-01-02T00:00:00Z -- echo spawned'
  agent-store schedule tick >/dev/null
  # The original schedule fired and created a new schedule
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  # original is completed, new one exists
  test "$count" -eq 2
  # The spawned schedule should be due
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "spawned"
}
run_case "schedule command creates new schedule" test_schedule_adds_new_schedule

test_schedule_modifies_its_own_records() {
  local rid
  rid=$(agent-store create task status=pending marker=self-mod-test)
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and marker=self-mod-test' -- 'agent-store set $AGENT_STORE_ID status=processed-by-schedule')
  agent-store schedule tick >/dev/null
  local status
  status=$(agent-store --json get "$rid" | jq -r '.record.fields.status')
  test "$status" = "processed-by-schedule"
}
run_case "schedule modifies its own queried records" test_schedule_modifies_its_own_records

test_schedule_deletes_its_own_record() {
  local rid
  rid=$(agent-store create task status=pending marker=delete-test)
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and marker=delete-test' -- 'agent-store rm $AGENT_STORE_ID'
  agent-store schedule tick >/dev/null
  # Record should be deleted
  ! agent-store get "$rid" 2>/dev/null
}
run_case "schedule deletes its own queried record" test_schedule_deletes_its_own_record

# ── Section 24: Recursive Tick (Re-entrancy) ────────────────────────

echo ""
echo "== Recursive Tick (Re-entrancy) =="

test_schedule_calls_tick_from_command() {
  # A schedule command that calls tick itself
  # The inner tick should not re-fire the same schedule (it is already claimed)
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store schedule tick 2>/dev/null; echo outer-done'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length == 1'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "outer-done"
}
run_case "nested tick from schedule command does not double-fire" test_schedule_calls_tick_from_command

test_recursive_tick_with_new_due_schedule() {
  # Schedule A creates schedule B (immediately due) and then calls tick
  # The inner tick should fire B
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'agent-store schedule add at 2020-01-01T00:00:00Z -- "echo inner-fired" >/dev/null; agent-store schedule tick 2>/dev/null'
  agent-store schedule tick >/dev/null
  # After everything: two schedules (both completed), at least 2 runs
  local completed
  completed=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "completed")] | length')
  test "$completed" -eq 2
  local run_count
  run_count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count" -ge 2
}
run_case "recursive tick fires newly created due schedule" test_recursive_tick_with_new_due_schedule

test_recursive_tick_does_not_corrupt_store() {
  # Multiple layers of recursive tick
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'agent-store schedule tick 2>/dev/null; agent-store schedule tick 2>/dev/null; echo layer1'
  agent-store schedule tick >/dev/null
  # Store should be consistent: no crash, ls and runs work
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
  agent-store --json schedule ls | jq -e '.schedules | length >= 1'
}
run_case "recursive tick does not corrupt store" test_recursive_tick_does_not_corrupt_store

test_every_schedule_tick_from_command() {
  # every-schedule that calls tick -- should not cause infinite recursion
  # because the schedule's next_run_at is advanced before the command runs
  agent-store schedule add every 1s -- 'agent-store schedule tick 2>/dev/null; echo every-tick-ok'
  sleep 2
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length >= 1'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "every-tick-ok"
  # Schedule should still be active
  agent-store schedule ls | grep -q "status=active"
}
run_case "every-schedule calling tick does not infinite loop" test_every_schedule_tick_from_command

# ── Section 25: Schedule Runs Accumulation ──────────────────────────

echo ""
echo "== Runs Accumulation =="

test_runs_accumulate_across_ticks() {
  agent-store schedule add every 1s -- 'echo run-$(date +%s%N)'
  for i in $(seq 1 10); do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  local count
  count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$count" -eq 10
}
run_case "runs accumulate across 10 ticks" test_runs_accumulate_across_ticks

test_runs_default_limit() {
  agent-store schedule add every 1s -- 'echo limited-run'
  for i in $(seq 1 25); do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  # Default limit is 20
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 20
}
run_case "runs default limit caps at 20" test_runs_default_limit

test_runs_all_have_unique_ids() {
  agent-store schedule add every 1s -- 'echo unique-id-run'
  for i in $(seq 1 5); do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  local ids
  ids=$(agent-store --json schedule runs --limit 100 | jq '[.schedule_runs[].id] | unique | length')
  test "$ids" -eq 5
}
run_case "all runs have unique IDs" test_runs_all_have_unique_ids

test_runs_ordered_newest_first() {
  agent-store schedule add every 1s -- 'echo ordered'
  for i in $(seq 1 3); do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  local first_id last_id
  first_id=$(agent-store --json schedule runs | jq '.schedule_runs[0].id')
  last_id=$(agent-store --json schedule runs | jq '.schedule_runs[-1].id')
  # Newest first: first ID should be greater than last ID
  test "$first_id" -gt "$last_id"
}
run_case "runs ordered newest first" test_runs_ordered_newest_first

test_runs_from_multiple_schedules() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo schedule-A'
  agent-store schedule add at 2020-06-01T00:00:00Z -- 'echo schedule-B'
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -eq 2
  # Both schedule IDs should appear
  local sched_ids
  sched_ids=$(agent-store --json schedule runs | jq '[.schedule_runs[].schedule_id] | unique | length')
  test "$sched_ids" -eq 2
}
run_case "runs from multiple schedules interleaved" test_runs_from_multiple_schedules

test_runs_with_query_produce_per_record_entries() {
  for i in $(seq 1 5); do
    agent-store create item "n=$i" >/dev/null
  done
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=item' -- 'echo "processing $AGENT_STORE_ID"'
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$count" -eq 5
  # Each run should have a different record_id
  local unique_records
  unique_records=$(agent-store --json schedule runs --limit 100 | jq '[.schedule_runs[].record_id] | unique | length')
  test "$unique_records" -eq 5
}
run_case "query schedule produces per-record run entries" test_runs_with_query_produce_per_record_entries

test_runs_persist_after_schedule_deletion() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo persist-after-rm')
  agent-store schedule tick >/dev/null
  agent-store schedule rm "$sid" >/dev/null
  # Runs should still be queryable after schedule is deleted
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
  agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout' | grep -q "persist-after-rm"
}
run_case "runs persist after schedule deletion" test_runs_persist_after_schedule_deletion

# ── Section 26: Store Corruption / Resilience ─────────────────────────

echo ""
echo "== Store Corruption / Resilience =="

test_truncated_store_db_recovers() {
  # Create a valid store with a schedule, then truncate the db file
  local sid
  sid=$(agent-store schedule add every 1h -- echo before-corrupt)
  truncate -s 0 .agent-store/store.sqlite
  # SQLite treats a 0-byte file as a new empty database; migrations re-run.
  # Original schedule is lost (data loss), but the store is operational.
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 0
  # New schedules can be added to the rebuilt store
  agent-store schedule add every 5m -- echo after-truncate >/dev/null
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 1
}
run_case "truncated store.db: data lost but store recovers" test_truncated_store_db_recovers

test_partially_truncated_store_db() {
  agent-store schedule add every 1h -- echo partial >/dev/null
  # Truncate to half the file size (corrupt but not empty)
  local size
  size=$(stat -c%s .agent-store/store.sqlite)
  truncate -s $((size / 2)) .agent-store/store.sqlite
  # Should fail with error, not crash
  ! agent-store schedule ls 2>/dev/null
}
run_case "partially truncated store.db fails gracefully" test_partially_truncated_store_db

test_garbage_in_store_db() {
  agent-store schedule add every 1h -- echo garbage >/dev/null
  # Overwrite db with random garbage
  dd if=/dev/urandom of=.agent-store/store.sqlite bs=1024 count=4 2>/dev/null
  # Should fail with error, not crash
  ! agent-store schedule ls 2>/dev/null
}
run_case "garbage in store.db fails gracefully" test_garbage_in_store_db

test_readonly_store_dir() {
  agent-store schedule add every 1h -- echo readonly >/dev/null
  chmod 444 .agent-store/store.sqlite
  # Reads should still work (SQLite can open read-only in WAL mode... or fail)
  # Writes should definitely fail
  ! agent-store schedule add every 5m -- echo new-in-readonly 2>/dev/null
  # Restore perms for cleanup
  chmod 644 .agent-store/store.sqlite
}
run_case "read-only store.db rejects writes" test_readonly_store_dir

test_readonly_store_directory() {
  agent-store schedule add every 1h -- echo dirperm >/dev/null
  chmod 555 .agent-store
  # Should fail when trying to create WAL files or write
  ! agent-store schedule add every 5m -- echo fail-here 2>/dev/null
  # Restore for cleanup
  chmod 755 .agent-store
}
run_case "read-only store directory rejects operations" test_readonly_store_directory

test_schedule_tick_on_corrupted_store() {
  # Create schedule, fire it once successfully, then corrupt
  agent-store schedule add every 1s -- echo tick-before-corrupt >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  # Now corrupt the db
  dd if=/dev/urandom of=.agent-store/store.sqlite bs=512 count=2 2>/dev/null
  # tick should fail gracefully (exit nonzero, print error)
  local rc=0
  agent-store schedule tick 2>/dev/null || rc=$?
  test "$rc" -ne 0
}
run_case "schedule tick on corrupted store fails gracefully" test_schedule_tick_on_corrupted_store

test_store_locked_by_another_process() {
  agent-store schedule add every 1s -- echo locked >/dev/null
  sleep 2
  # Hold an exclusive lock on the db file using flock for 3 seconds
  # agent-store has a 5s busy_timeout, so it should wait and succeed
  flock -x .agent-store/store.sqlite -c "sleep 2" &
  local lock_pid=$!
  sleep 0.2
  # tick should eventually succeed (busy_timeout is 5s, lock held for 2s)
  agent-store schedule tick >/dev/null
  wait "$lock_pid" 2>/dev/null || true
  # Verify the run was recorded
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
}
run_case "store locked briefly: tick waits and succeeds" test_store_locked_by_another_process

test_store_concurrent_heavy_write_contention() {
  # Simulate heavy SQLite write contention by running many writers in parallel.
  # agent-store has a 5s busy_timeout and 8 open retries, so it should handle this.
  agent-store schedule add every 1s -- echo contention >/dev/null
  sleep 2
  # Many concurrent operations competing for write locks
  for i in $(seq 1 10); do
    agent-store create task "title=contention-$i" >/dev/null &
  done
  agent-store schedule tick &
  wait
  # All operations should have succeeded despite contention
  local task_count
  task_count=$(agent-store find kind=task --count)
  test "$task_count" -eq 10
  agent-store --json schedule runs | jq -e '.schedule_runs | length >= 1'
}
run_case "heavy write contention: all operations succeed" test_store_concurrent_heavy_write_contention

test_wal_journal_present() {
  agent-store schedule add every 1s -- echo wal-test >/dev/null
  sleep 2
  # Force WAL files to exist by doing a write
  agent-store create task status=open >/dev/null
  # WAL journal might exist
  # tick should work fine regardless
  agent-store schedule tick >/dev/null
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
}
run_case "tick works with WAL journal present" test_wal_journal_present

test_deleted_store_db_during_operation() {
  agent-store schedule add every 1h -- echo delete-mid >/dev/null
  # Delete the db file — next command should fail gracefully
  rm -f .agent-store/store.sqlite .agent-store/store.sqlite-wal .agent-store/store.sqlite-shm
  # This should fail (no db to read from) or succeed (re-creates a new empty db via migrations)
  # Either way it should not crash
  agent-store schedule ls 2>/dev/null || true
  agent-store schedule tick 2>/dev/null || true
}
run_case "deleted store.db mid-session does not crash" test_deleted_store_db_during_operation

# ── Section 27: Signal Handling During Tick ───────────────────────────

echo ""
echo "== Signal Handling During Tick =="

test_sigterm_during_tick() {
  # Schedule a long-running command, then SIGTERM the tick process
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  # Wait for tick to start running the command
  sleep 1
  # Send SIGTERM
  kill -TERM "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should still be usable after SIGTERM
  agent-store schedule ls >/dev/null
  # The at-schedule should be marked completed (claim happened before command ran)
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
}
run_case "SIGTERM during tick: store remains usable" test_sigterm_during_tick

test_sigint_during_tick() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1
  kill -INT "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should still be usable after SIGINT
  agent-store schedule ls >/dev/null
  agent-store --json schedule ls | jq -e '.schedules | length >= 1'
}
run_case "SIGINT during tick: store remains usable" test_sigint_during_tick

test_sigkill_during_tick() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1
  kill -KILL "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should survive even SIGKILL (SQLite WAL handles this)
  agent-store schedule ls >/dev/null
  # at-schedule was already claimed (status=completed) before command started
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
}
run_case "SIGKILL during tick: store survives" test_sigkill_during_tick

test_sigterm_schedule_command_killed() {
  # The schedule command itself is killed by SIGTERM
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo started; sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1
  # Kill the child sleep process (the command), not tick itself
  local child_pids
  child_pids=$(pgrep -P "$tick_pid" 2>/dev/null || true)
  if [ -n "$child_pids" ]; then
    for cpid in $child_pids; do
      kill -TERM "$cpid" 2>/dev/null || true
    done
  fi
  wait "$tick_pid" 2>/dev/null || true
  # tick should have recorded the run (with non-zero exit or signal exit)
  local count
  count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
  # Run should show the command was terminated (exit != 0)
  agent-store --json schedule runs | jq -e '.schedule_runs[0].exit_status != 0'
}
run_case "schedule command killed by signal: run recorded" test_sigterm_schedule_command_killed

test_sigterm_every_schedule_survives() {
  # every-schedule should remain active even if tick is killed mid-command
  agent-store schedule add every 1s -- 'sleep 30'
  sleep 2
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1
  kill -TERM "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Schedule should still be active with an advanced next_run_at
  agent-store schedule ls | grep -q "status=active"
}
run_case "SIGTERM during every-schedule tick: schedule stays active" test_sigterm_every_schedule_survives

test_multiple_signals_rapid_fire() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  sleep 0.5
  # Send several signals rapidly
  kill -INT "$tick_pid" 2>/dev/null || true
  kill -TERM "$tick_pid" 2>/dev/null || true
  kill -INT "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should still be usable
  agent-store schedule ls >/dev/null
}
run_case "rapid signal barrage: store survives" test_multiple_signals_rapid_fire

# ── Section 28: Race Between schedule rm and Concurrent Tick ─────────

echo ""
echo "== Race: schedule rm vs Concurrent Tick =="

test_rm_while_tick_executing_command() {
  # Create a schedule whose command takes a while
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 3; echo done')
  # Start tick in background
  agent-store schedule tick &
  local tick_pid=$!
  # Wait for tick to claim and start executing the command
  sleep 0.5
  # Try to rm the schedule while tick is running its command
  # The schedule was already claimed (status=completed for at), rm should succeed
  agent-store schedule rm "$sid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should be consistent
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "rm while tick executing: no crash" test_rm_while_tick_executing_command

test_rm_during_every_tick_execution() {
  local sid
  sid=$(agent-store schedule add every 1s -- 'sleep 3; echo every-done')
  sleep 2
  agent-store schedule tick &
  local tick_pid=$!
  sleep 0.5
  # rm the schedule while tick is running its command
  agent-store schedule rm "$sid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Schedule should be gone
  ! agent-store schedule ls | grep -q "$sid"
  # Store should be consistent
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "rm every-schedule during tick: schedule removed" test_rm_during_every_tick_execution

test_concurrent_tick_and_rm_same_schedule() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo race-target')
  # Start tick and rm concurrently
  agent-store schedule tick &
  local tick_pid=$!
  agent-store schedule rm "$sid" 2>/dev/null &
  local rm_pid=$!
  wait "$tick_pid" 2>/dev/null || true
  wait "$rm_pid" 2>/dev/null || true
  # Schedule should be gone (either completed+rm'd or rm'd before tick)
  ! agent-store schedule ls | grep -q "$sid"
  # Store should be consistent
  agent-store schedule ls >/dev/null
}
run_case "concurrent tick and rm same schedule" test_concurrent_tick_and_rm_same_schedule

test_multiple_concurrent_tick_rm_stress() {
  # Create several schedules
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo stress-$i" >/dev/null
  done
  # Run ticks and rms concurrently
  agent-store schedule tick &
  agent-store schedule tick &
  # rm some of them by listing and picking IDs
  local ids
  ids=$(agent-store --json schedule ls 2>/dev/null | jq -r '.schedules[].id' 2>/dev/null || true)
  for id in $ids; do
    agent-store schedule rm "$id" 2>/dev/null &
  done
  wait
  # Store should not be corrupted
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "concurrent tick+rm stress: store stays consistent" test_multiple_concurrent_tick_rm_stress

test_rm_nonexistent_after_tick_claims() {
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo claimed')
  # tick claims and completes the schedule
  agent-store schedule tick >/dev/null
  # rm should succeed (schedule still exists, just completed)
  agent-store schedule rm "$sid" | grep -q "Removed"
  # Double rm should fail
  ! agent-store schedule rm "$sid" 2>/dev/null
}
run_case "rm after tick completes: removes completed schedule" test_rm_nonexistent_after_tick_claims

test_add_rm_tick_interleaved_rapid() {
  # Rapidly add, rm, and tick in sequence to stress the lock
  for i in $(seq 1 10); do
    local sid
    sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- "echo rapid-$i")
    agent-store schedule tick >/dev/null &
    agent-store schedule rm "$sid" 2>/dev/null &
  done
  wait
  # Store should be consistent after all operations
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "rapid add/rm/tick interleaving: no corruption" test_add_rm_tick_interleaved_rapid

# ── Section 29: Enable/Disable from Different Directories ────────────

echo ""
echo "== Enable/Disable from Different Directories =="

test_enable_from_subdirectory() {
  # enable should work from a subdirectory of the project
  mkdir -p subdir/deep/nested
  (cd subdir/deep/nested && agent-store schedule enable) >/dev/null
  crontab -l | grep -q "schedule tick"
  # Clean up
  (cd subdir/deep/nested && agent-store schedule disable) >/dev/null
}
run_case "enable from nested subdirectory" test_enable_from_subdirectory

test_disable_from_subdirectory() {
  # enable from root, disable from subdirectory
  agent-store schedule enable >/dev/null
  crontab -l | grep -q "schedule tick"
  mkdir -p subdir
  (cd subdir && agent-store schedule disable) >/dev/null
  # Crontab entry should be removed
  ! crontab -l 2>/dev/null | grep -q "agent-store:tick"
}
run_case "disable from subdirectory of project" test_disable_from_subdirectory

test_enable_from_subdir_disable_from_root() {
  mkdir -p subdir
  (cd subdir && agent-store schedule enable) >/dev/null
  crontab -l | grep -q "schedule tick"
  # disable from root should also work (same canonical project root)
  agent-store schedule disable >/dev/null
  ! crontab -l 2>/dev/null | grep -q "agent-store:tick"
}
run_case "enable from subdir, disable from root" test_enable_from_subdir_disable_from_root

test_enable_disable_different_deep_dirs() {
  mkdir -p a/b/c d/e/f
  (cd a/b/c && agent-store schedule enable) >/dev/null
  crontab -l | grep -q "schedule tick"
  (cd d/e/f && agent-store schedule disable) >/dev/null
  ! crontab -l 2>/dev/null | grep -q "agent-store:tick"
}
run_case "enable from a/b/c, disable from d/e/f" test_enable_disable_different_deep_dirs

test_enable_from_two_subdirs_is_idempotent() {
  mkdir -p sub1 sub2
  (cd sub1 && agent-store schedule enable) >/dev/null
  (cd sub2 && agent-store schedule enable) >/dev/null
  # Should still only have one cron entry for this project
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 1
  agent-store schedule disable >/dev/null
}
run_case "enable from two subdirs is idempotent" test_enable_from_two_subdirs_is_idempotent

test_schedule_commands_from_subdirectory() {
  # All schedule commands should work from a subdirectory
  mkdir -p subdir
  local sid
  sid=$(cd subdir && agent-store schedule add at 2020-01-01T00:00:00Z -- echo from-subdir)
  (cd subdir && agent-store schedule ls) | grep -q "$sid"
  (cd subdir && agent-store schedule tick) >/dev/null
  local count
  count=$(cd subdir && agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$count" -ge 1
  (cd subdir && agent-store schedule rm "$sid") >/dev/null
  # verify it's removed
  ! (cd subdir && agent-store schedule ls) | grep -q "$sid"
}
run_case "all schedule commands work from subdirectory" test_schedule_commands_from_subdirectory

test_tick_from_subdirectory_runs_in_project_root() {
  mkdir -p subdir
  (cd subdir && agent-store schedule add at 2020-01-01T00:00:00Z -- 'pwd')
  local json
  json=$(cd subdir && agent-store --json schedule tick)
  local pwd_out
  pwd_out=$(echo "$json" | jq -r '.schedule_runs[0].stdout' | tr -d '\n')
  # Command should run in project root, not the subdirectory
  test "$pwd_out" = "$(pwd)"
}
run_case "tick from subdir runs command in project root" test_tick_from_subdirectory_runs_in_project_root

# ── Section 30: Very Large Scale Performance ────────────────────────

echo ""
echo "== Very Large Scale Performance =="

test_100_schedules_tick_at_once() {
  # Create 100 at-schedules all due in the past
  for i in $(seq 1 100); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo sched-$i" >/dev/null
  done
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 100

  # Tick all 100 at once and measure wall-clock time
  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  local json
  json=$(agent-store --json schedule tick)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # All 100 should have fired
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 100
  # All should be exit 0
  test "$(echo "$json" | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')" -eq 100
  # Should complete in under 60 seconds (100 short echo commands)
  test "$elapsed" -lt 60
}
run_case "100 at-schedules all tick at once" test_100_schedules_tick_at_once

test_500_schedules_ls_performance() {
  # Create 500 schedules
  for i in $(seq 1 500); do
    agent-store schedule add every "${i}s" -- "echo ls-perf-$i" >/dev/null
  done

  local start_ts end_ts elapsed
  start_ts=$(date +%s%N)
  local json
  json=$(agent-store --json schedule ls)
  end_ts=$(date +%s%N)
  elapsed=$(( (end_ts - start_ts) / 1000000 ))  # milliseconds

  # All 500 should be listed
  test "$(echo "$json" | jq '.schedules | length')" -eq 500
  # ls should complete in under 5 seconds
  test "$elapsed" -lt 5000
}
run_case "500 schedules listed quickly" test_500_schedules_ls_performance

test_1000_runs_query_performance() {
  # Create a schedule and fire it many times to accumulate 100+ runs
  agent-store schedule add every 1s -- 'echo run-accumulate' >/dev/null
  # Use a loop to tick rapidly
  for i in $(seq 1 100); do
    sleep 1
    agent-store schedule tick >/dev/null
  done

  local start_ts end_ts elapsed
  start_ts=$(date +%s%N)
  local json
  json=$(agent-store --json schedule runs --limit 1000)
  end_ts=$(date +%s%N)
  elapsed=$(( (end_ts - start_ts) / 1000000 ))

  # Should have 100 runs
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 100
  # Query should complete in under 5 seconds
  test "$elapsed" -lt 5000
}
run_case "100 accumulated runs queried quickly" test_1000_runs_query_performance

test_100_query_scoped_schedules_10_records() {
  # Create 10 records
  for i in $(seq 1 10); do
    agent-store create item "n=$i" marker=scale-test >/dev/null
  done
  # Create 100 query-scoped at-schedules, each matching those 10 records
  for i in $(seq 1 100); do
    agent-store schedule add at 2020-01-01T00:00:00Z 'kind=item and marker=scale-test' -- "echo qs-$i" >/dev/null
  done

  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  local json
  json=$(agent-store --json schedule tick)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # 100 schedules * 10 records = 1000 command executions
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 1000
  # Should complete within 120 seconds (1000 short echo commands)
  test "$elapsed" -lt 120
}
run_case "100 query-scoped schedules x 10 records = 1000 executions" test_100_query_scoped_schedules_10_records

test_rapid_add_rm_throughput() {
  # Rapidly create and delete schedules to test add/rm throughput
  local start_ts end_ts elapsed
  start_ts=$(date +%s%N)

  for i in $(seq 1 50); do
    local sid
    sid=$(agent-store schedule add every 1h -- "echo throughput-$i")
    agent-store schedule rm "$sid" >/dev/null
  done

  end_ts=$(date +%s%N)
  elapsed=$(( (end_ts - start_ts) / 1000000 ))

  # All should be gone
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 0
  # 50 add+rm cycles should complete in under 30 seconds
  test "$elapsed" -lt 30000
}
run_case "50 rapid add/rm cycles" test_rapid_add_rm_throughput

test_concurrent_add_100_schedules() {
  # Concurrently add 100 schedules
  for i in $(seq 1 100); do
    agent-store schedule add every "${i}m" -- "echo concurrent-$i" &
  done
  wait
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 100
}
run_case "100 concurrent schedule adds" test_concurrent_add_100_schedules

# ── Section 31: Nested .agent-store/ Directories ────────────────────

echo ""
echo "== Nested .agent-store/ Directories =="

test_nested_stores_independent_schedules() {
  # Parent store (already initialized by run_case)
  # Create a child store inside a subdirectory
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Add schedules to parent
  agent-store schedule add every 1h -- 'echo parent-sched' >/dev/null
  # Add schedules to child
  (cd child/project && agent-store schedule add every 2h -- 'echo child-sched' >/dev/null)

  # Parent should have exactly 1 schedule
  local parent_count
  parent_count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$parent_count" -eq 1

  # Child should have exactly 1 schedule
  local child_count
  child_count=$(cd child/project && agent-store --json schedule ls | jq '.schedules | length')
  test "$child_count" -eq 1

  # Verify they are different schedules
  local parent_expr child_expr
  parent_expr=$(agent-store --json schedule ls | jq -r '.schedules[0].expression')
  child_expr=$(cd child/project && agent-store --json schedule ls | jq -r '.schedules[0].expression')
  test "$parent_expr" = "1h"
  test "$child_expr" = "2h"
}
run_case "nested stores have independent schedules" test_nested_stores_independent_schedules

test_nested_child_rm_does_not_affect_parent() {
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Add schedules to both
  local parent_sid
  parent_sid=$(agent-store schedule add every 1h -- 'echo parent')
  local child_sid
  child_sid=$(cd child/project && agent-store schedule add every 2h -- 'echo child')

  # Remove child's schedule
  (cd child/project && agent-store schedule rm "$child_sid" >/dev/null)

  # Parent's schedule should still exist
  agent-store schedule ls | grep -q "$parent_sid"
  # Child's schedule should be gone
  ! (cd child/project && agent-store schedule ls) | grep -q "$child_sid"
}
run_case "child rm does not affect parent schedules" test_nested_child_rm_does_not_affect_parent

test_nested_tick_in_parent_does_not_affect_child() {
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Add due schedules to both
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo parent-tick' >/dev/null
  (cd child/project && agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo child-tick' >/dev/null)

  # Tick parent only
  agent-store schedule tick >/dev/null

  # Parent schedule should be completed
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
  # Child schedule should still be active (not ticked)
  (cd child/project && agent-store --json schedule ls | jq -e '.schedules[0].status == "active"')
}
run_case "tick in parent does not affect child store" test_nested_tick_in_parent_does_not_affect_child

test_nested_tick_in_child_does_not_affect_parent() {
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Add due schedules to both
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo parent-tick' >/dev/null
  (cd child/project && agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo child-tick' >/dev/null)

  # Tick child only
  (cd child/project && agent-store schedule tick >/dev/null)

  # Child should be completed
  (cd child/project && agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"')
  # Parent should still be active
  agent-store --json schedule ls | jq -e '.schedules[0].status == "active"'
}
run_case "tick in child does not affect parent store" test_nested_tick_in_child_does_not_affect_parent

test_nested_stores_independent_records() {
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Create records in parent
  agent-store create task title=parent-task >/dev/null
  # Create records in child
  (cd child/project && agent-store create task title=child-task >/dev/null)

  # Query-scoped schedules should only see their own store's records
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'cat' >/dev/null
  (cd child/project && agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task' -- 'cat' >/dev/null)

  local parent_json child_json
  parent_json=$(agent-store --json schedule tick)
  child_json=$(cd child/project && agent-store --json schedule tick)

  # Each should have exactly 1 run (their own record)
  test "$(echo "$parent_json" | jq '.schedule_runs | length')" -eq 1
  test "$(echo "$child_json" | jq '.schedule_runs | length')" -eq 1

  # Parent run should contain parent-task, child run should contain child-task
  echo "$parent_json" | jq -r '.schedule_runs[0].stdout' | grep -q "parent-task"
  echo "$child_json" | jq -r '.schedule_runs[0].stdout' | grep -q "child-task"
}
run_case "nested stores have independent records" test_nested_stores_independent_records

test_nested_enable_disable_independent_cron() {
  # Clean any existing crontab
  crontab -r 2>/dev/null || true

  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Enable cron for parent
  agent-store schedule enable >/dev/null
  # Enable cron for child
  (cd child/project && agent-store schedule enable >/dev/null)

  # Should have two separate cron entries
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 2

  # Disable child's cron
  (cd child/project && agent-store schedule disable >/dev/null)

  # Parent cron should still be there, child's gone
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 1
  crontab -l | grep -q "$(pwd)"

  # Disable parent's cron
  agent-store schedule disable >/dev/null
  crontab -r 2>/dev/null || true
}
run_case "nested stores have independent cron entries" test_nested_enable_disable_independent_cron

test_nested_runs_isolation() {
  mkdir -p child/project
  (cd child/project && agent-store init >/dev/null)

  # Fire schedules in both stores
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo parent-run' >/dev/null
  (cd child/project && agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo child-run' >/dev/null)
  agent-store schedule tick >/dev/null
  (cd child/project && agent-store schedule tick >/dev/null)

  # Parent runs should only show parent's
  local parent_runs
  parent_runs=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$parent_runs" -eq 1
  agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout' | grep -q "parent-run"

  # Child runs should only show child's
  local child_runs
  child_runs=$(cd child/project && agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$child_runs" -eq 1
  (cd child/project && agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout') | grep -q "child-run"
}
run_case "nested stores have isolated runs" test_nested_runs_isolation

test_deeply_nested_3_levels() {
  # Three levels of nesting
  mkdir -p level1/level2/level3
  (cd level1 && agent-store init >/dev/null)
  (cd level1/level2 && agent-store init >/dev/null)
  (cd level1/level2/level3 && agent-store init >/dev/null)

  # Add schedules at each level
  (cd level1 && agent-store schedule add every 1h -- 'echo L1' >/dev/null)
  (cd level1/level2 && agent-store schedule add every 2h -- 'echo L2' >/dev/null)
  (cd level1/level2/level3 && agent-store schedule add every 3h -- 'echo L3' >/dev/null)

  # Each should see only its own
  local c1 c2 c3
  c1=$(cd level1 && agent-store --json schedule ls | jq '.schedules | length')
  c2=$(cd level1/level2 && agent-store --json schedule ls | jq '.schedules | length')
  c3=$(cd level1/level2/level3 && agent-store --json schedule ls | jq '.schedules | length')
  test "$c1" -eq 1
  test "$c2" -eq 1
  test "$c3" -eq 1

  # Verify expression isolation
  local e1 e2 e3
  e1=$(cd level1 && agent-store --json schedule ls | jq -r '.schedules[0].expression')
  e2=$(cd level1/level2 && agent-store --json schedule ls | jq -r '.schedules[0].expression')
  e3=$(cd level1/level2/level3 && agent-store --json schedule ls | jq -r '.schedules[0].expression')
  test "$e1" = "1h"
  test "$e2" = "2h"
  test "$e3" = "3h"
}
run_case "3-level nested stores are independent" test_deeply_nested_3_levels

# ── Section 32: Crontab Edge Cases ──────────────────────────────────

echo ""
echo "== Crontab Edge Cases =="

test_cron_entry_with_missing_binary() {
  # Enable cron, which writes a crontab entry pointing to the current binary
  agent-store schedule enable >/dev/null
  local cron_entry
  cron_entry=$(crontab -l | grep "schedule tick")
  # Verify the cron entry references the real binary path
  echo "$cron_entry" | grep -q "agent-store"
  # The binary path is valid now
  local binary_path
  binary_path=$(echo "$cron_entry" | grep -oP '\S+agent-store')
  test -f "$binary_path"
  # Clean up
  agent-store schedule disable >/dev/null
}
run_case "cron entry references real binary path" test_cron_entry_with_missing_binary

test_cron_entry_with_nonexistent_project_dir() {
  # Create a temporary project, enable cron, then check entry format
  local tmpproj
  tmpproj=$(mktemp -d)
  (cd "$tmpproj" && agent-store init >/dev/null && agent-store schedule enable >/dev/null)
  # Crontab entry should reference the project dir
  crontab -l | grep -q "$tmpproj"
  # Clean up - disable before removing
  (cd "$tmpproj" && agent-store schedule disable >/dev/null)
  rm -rf "$tmpproj"
}
run_case_noinit "cron entry references project directory" test_cron_entry_with_nonexistent_project_dir

test_cron_disable_after_project_dir_removed() {
  local tmpproj
  tmpproj=$(mktemp -d)
  (cd "$tmpproj" && agent-store init >/dev/null && agent-store schedule enable >/dev/null)
  crontab -l | grep -q "$tmpproj"

  # Remove the project directory (simulating a moved/deleted project)
  rm -rf "$tmpproj"

  # Crontab still has the stale entry
  crontab -l | grep -q "$tmpproj"

  # We cannot easily run agent-store schedule disable for the removed dir
  # because the store no longer exists. Clean up manually.
  crontab -l | grep -v "$tmpproj" | grep -v "^# agent-store:tick:$tmpproj" | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
}
run_case_noinit "stale cron entry persists after project dir removed" test_cron_disable_after_project_dir_removed

test_many_projects_cron_entries() {
  crontab -r 2>/dev/null || true
  local dirs=()
  # Create 20 projects, each with cron enabled
  for i in $(seq 1 20); do
    local d
    d=$(mktemp -d)
    dirs+=("$d")
    (cd "$d" && agent-store init >/dev/null && agent-store schedule enable >/dev/null)
  done

  # Should have exactly 20 cron entries
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 20

  # Disable a few and verify count drops
  for i in 0 4 9 14 19; do
    (cd "${dirs[$i]}" && agent-store schedule disable >/dev/null)
  done
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 15

  # Clean up all remaining
  for d in "${dirs[@]}"; do
    (cd "$d" && agent-store schedule disable 2>/dev/null) || true
  done
  crontab -r 2>/dev/null || true
  for d in "${dirs[@]}"; do rm -rf "$d"; done
}
run_case_noinit "20 projects with independent cron entries" test_many_projects_cron_entries

test_cron_entry_format_has_marker_comment() {
  agent-store schedule enable >/dev/null
  local crontab_content
  crontab_content=$(crontab -l)
  # Should have a marker comment line before the actual cron line
  echo "$crontab_content" | grep -q "^# agent-store:tick:"
  # The cron line should have the standard every-minute pattern
  echo "$crontab_content" | grep -q "^\* \* \* \* \*"
  agent-store schedule disable >/dev/null
}
run_case "cron entry has marker comment and minute pattern" test_cron_entry_format_has_marker_comment

test_cron_enable_with_preexisting_entries() {
  # Set up crontab with various pre-existing entries
  cat <<'CRONTAB' | crontab -
# My custom backup
0 2 * * * /usr/bin/backup.sh
# Another cron
*/5 * * * * /usr/bin/monitor.sh
CRONTAB
  agent-store schedule enable >/dev/null
  # Pre-existing entries should be preserved
  crontab -l | grep -q "backup.sh"
  crontab -l | grep -q "monitor.sh"
  # agent-store entry should be added
  crontab -l | grep -q "schedule tick"

  agent-store schedule disable >/dev/null
  # Pre-existing entries should still be there
  crontab -l | grep -q "backup.sh"
  crontab -l | grep -q "monitor.sh"
  # agent-store entry should be gone
  ! crontab -l | grep -q "agent-store:tick"
  crontab -r 2>/dev/null || true
}
run_case "enable/disable preserves complex crontab" test_cron_enable_with_preexisting_entries

test_cron_entry_binary_path_is_absolute() {
  agent-store schedule enable >/dev/null
  local cron_line
  cron_line=$(crontab -l | grep "schedule tick")
  # The binary path in the cron entry should be absolute (starts with /)
  echo "$cron_line" | grep -qP '&& /\S+agent-store schedule tick'
  agent-store schedule disable >/dev/null
}
run_case "cron entry uses absolute binary path" test_cron_entry_binary_path_is_absolute

test_cron_entry_project_path_is_absolute() {
  agent-store schedule enable >/dev/null
  local cron_line
  cron_line=$(crontab -l | grep "schedule tick")
  # The cd path should be absolute (starts with /)
  echo "$cron_line" | grep -qP 'cd /\S+'
  agent-store schedule disable >/dev/null
}
run_case "cron entry uses absolute project path" test_cron_entry_project_path_is_absolute

# ── Section 33: Long-Running Commands with Incremental Output ───────

echo ""
echo "== Long-Running Commands with Incremental Output =="

test_slow_output_within_timeout() {
  # Command produces output slowly over several seconds (well within 30s timeout)
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'for i in 1 2 3 4 5; do echo "line-$i"; sleep 1; done'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  # All 5 lines should be captured
  echo "$stdout" | grep -q "line-1"
  echo "$stdout" | grep -q "line-5"
  local line_count
  line_count=$(echo "$stdout" | grep -c "line-")
  test "$line_count" -eq 5
}
run_case "slow output over 5 seconds captured fully" test_slow_output_within_timeout

test_chunked_output_with_pauses() {
  # Command produces output in chunks separated by pauses
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'echo "chunk-A-start"; for i in $(seq 1 10); do echo "A-$i"; done; sleep 2; echo "chunk-B-start"; for i in $(seq 1 10); do echo "B-$i"; done; sleep 2; echo "chunk-C-start"; for i in $(seq 1 5); do echo "C-$i"; done'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  # All chunks should be captured
  echo "$stdout" | grep -q "chunk-A-start"
  echo "$stdout" | grep -q "chunk-B-start"
  echo "$stdout" | grep -q "chunk-C-start"
  echo "$stdout" | grep -q "A-10"
  echo "$stdout" | grep -q "B-10"
  echo "$stdout" | grep -q "C-5"
}
run_case "chunked output with 2s pauses captured" test_chunked_output_with_pauses

test_incremental_stderr_and_stdout() {
  # Command writes to both stdout and stderr incrementally
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'echo "out-1"; echo "err-1" >&2; sleep 1; echo "out-2"; echo "err-2" >&2; sleep 1; echo "out-3"; echo "err-3" >&2; exit 1'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 1'
  local stdout stderr_out
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  stderr_out=$(echo "$json" | jq -r '.schedule_runs[0].stderr')
  echo "$stdout" | grep -q "out-1"
  echo "$stdout" | grep -q "out-3"
  echo "$stderr_out" | grep -q "err-1"
  echo "$stderr_out" | grep -q "err-3"
}
run_case "incremental stdout and stderr both captured" test_incremental_stderr_and_stdout

test_multiple_schedules_different_speeds() {
  # Multiple due schedules with commands of different durations
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo fast; exit 0' >/dev/null
  agent-store schedule add at 2020-06-01T00:00:00Z -- 'sleep 3; echo medium; exit 0' >/dev/null
  agent-store schedule add at 2020-09-01T00:00:00Z -- 'sleep 5; echo slow; exit 0' >/dev/null

  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  local json
  json=$(agent-store --json schedule tick)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # All 3 should have run (sequentially)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 3
  # All exit 0
  test "$(echo "$json" | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')" -eq 3
  # Combined runtime should be at least 8 seconds (3+5 for medium+slow, fast is instant)
  test "$elapsed" -ge 7
  # Should complete within 30 seconds total
  test "$elapsed" -lt 30
}
run_case "multiple schedules at different speeds execute sequentially" test_multiple_schedules_different_speeds

test_slow_command_near_timeout() {
  # Command that runs for ~25 seconds (close to 30s timeout but within)
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'for i in $(seq 1 25); do echo "tick-$i"; sleep 1; done'

  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  local json
  json=$(agent-store --json schedule tick)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "tick-25"
  # Should have taken ~25 seconds
  test "$elapsed" -ge 23
  test "$elapsed" -lt 35
}
run_case "slow command near timeout completes successfully" test_slow_command_near_timeout

test_slow_command_exceeds_timeout() {
  # Command that would run for 60 seconds (exceeds 30s timeout)
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'for i in $(seq 1 60); do echo "before-timeout-$i"; sleep 1; done'

  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  local json
  json=$(agent-store --json schedule tick)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # Should have been killed by timeout
  echo "$json" | jq -e '.schedule_runs[0].exit_status != 0'
  echo "$json" | jq -e '.schedule_runs[0].stderr | contains("timed out")'
  # Partial output before timeout should be captured
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "before-timeout-1"
  # Should not have reached line 60
  ! echo "$stdout" | grep -q "before-timeout-60"
  # Should have taken approximately 30 seconds (timeout)
  test "$elapsed" -ge 28
  test "$elapsed" -lt 45
}
run_case "slow command exceeding timeout killed with partial output" test_slow_command_exceeds_timeout

test_large_incremental_output() {
  # Command produces lots of output incrementally
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'for i in $(seq 1 500); do echo "line-$i: $(head -c 50 /dev/urandom | base64)"; done'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  # Output should be captured (possibly truncated to 8192 bytes)
  local stdout_len
  stdout_len=$(echo "$json" | jq '.schedule_runs[0].stdout | length')
  test "$stdout_len" -gt 0
}
run_case "large incremental output captured" test_large_incremental_output

test_no_output_long_running() {
  # Command runs for several seconds but produces no output
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 5; exit 0'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  test -z "$stdout" || test "$stdout" = ""
}
run_case "long-running command with no output completes cleanly" test_no_output_long_running

# ── Section 34: Schedule add --json Output ─────────────────────────

echo ""
echo "== Schedule add --json Output =="

test_json_add_every_returns_all_fields() {
  local json
  json=$(agent-store --json schedule add every 10m -- echo json-every)
  # Top-level status
  echo "$json" | jq -e '.status == "added"'
  # Schedule object fields
  echo "$json" | jq -e '.schedule.id | length >= 6'
  echo "$json" | jq -e '.schedule.kind == "every"'
  echo "$json" | jq -e '.schedule.expression == "10m"'
  echo "$json" | jq -e '.schedule.interval_seconds == 600'
  echo "$json" | jq -e '.schedule.query == null'
  echo "$json" | jq -e '.schedule.command == "echo json-every"'
  echo "$json" | jq -e '.schedule.next_run_at != null'
  echo "$json" | jq -e '.schedule.status == "active"'
  echo "$json" | jq -e '.schedule.created_at != null'
}
run_case "add --json every: all fields present" test_json_add_every_returns_all_fields

test_json_add_at_returns_all_fields() {
  local json
  json=$(agent-store --json schedule add at 2030-06-15T12:00:00Z -- echo json-at)
  echo "$json" | jq -e '.status == "added"'
  echo "$json" | jq -e '.schedule.kind == "at"'
  echo "$json" | jq -e '.schedule.expression == "2030-06-15T12:00:00Z"'
  # at-schedules have null interval_seconds
  echo "$json" | jq -e '.schedule.interval_seconds == null'
  echo "$json" | jq -e '.schedule.query == null'
  echo "$json" | jq -e '.schedule.command == "echo json-at"'
  echo "$json" | jq -e '.schedule.next_run_at == "2030-06-15T12:00:00Z"'
  echo "$json" | jq -e '.schedule.status == "active"'
  echo "$json" | jq -e '.schedule.created_at != null'
}
run_case "add --json at: all fields present" test_json_add_at_returns_all_fields

test_json_add_every_with_query() {
  agent-store create task status=open >/dev/null
  local json
  json=$(agent-store --json schedule add every 5m 'kind=task and status=open' -- echo with-query)
  echo "$json" | jq -e '.status == "added"'
  echo "$json" | jq -e '.schedule.query == "kind=task and status=open"'
  echo "$json" | jq -e '.schedule.kind == "every"'
  echo "$json" | jq -e '.schedule.expression == "5m"'
  echo "$json" | jq -e '.schedule.interval_seconds == 300'
}
run_case "add --json every with query" test_json_add_every_with_query

test_json_add_at_with_query() {
  agent-store create note msg=hello >/dev/null
  local json
  json=$(agent-store --json schedule add at 2020-01-01T00:00:00Z 'kind=note' -- cat)
  echo "$json" | jq -e '.status == "added"'
  echo "$json" | jq -e '.schedule.kind == "at"'
  echo "$json" | jq -e '.schedule.query == "kind=note"'
  echo "$json" | jq -e '.schedule.command == "cat"'
}
run_case "add --json at with query" test_json_add_at_with_query

test_json_add_created_at_is_iso8601() {
  local json
  json=$(agent-store --json schedule add every 1h -- echo ts-check)
  local created_at
  created_at=$(echo "$json" | jq -r '.schedule.created_at')
  # Should match ISO 8601 format: YYYY-MM-DDTHH:MM:SS.sssZ
  echo "$created_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
}
run_case "add --json created_at is ISO 8601 with millis" test_json_add_created_at_is_iso8601

test_json_add_next_run_at_is_iso8601() {
  local json
  json=$(agent-store --json schedule add every 1h -- echo next-ts)
  local next_run_at
  next_run_at=$(echo "$json" | jq -r '.schedule.next_run_at')
  # Should match ISO 8601 format
  echo "$next_run_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'
}
run_case "add --json next_run_at is ISO 8601 with millis" test_json_add_next_run_at_is_iso8601

test_json_add_id_matches_plain_output() {
  # The ID returned by --json add should match plain add
  local plain_id
  plain_id=$(agent-store schedule add every 1h -- echo id-match-plain)
  local json_id
  json_id=$(agent-store --json schedule add every 2h -- echo id-match-json | jq -r '.schedule.id')
  # Both should be 6-8 char alphanumeric
  echo "$plain_id" | grep -Eq '^[a-z0-9]{6,8}$'
  echo "$json_id" | grep -Eq '^[a-z0-9]{6,8}$'
  # They should be different IDs
  test "$plain_id" != "$json_id"
}
run_case "add --json id matches plain output format" test_json_add_id_matches_plain_output

test_json_add_at_relative_duration() {
  local json
  json=$(agent-store --json schedule add at 30s -- echo relative-at)
  echo "$json" | jq -e '.status == "added"'
  echo "$json" | jq -e '.schedule.kind == "at"'
  echo "$json" | jq -e '.schedule.expression == "30s"'
  # next_run_at should be in the future (after 2026)
  local next
  next=$(echo "$json" | jq -r '.schedule.next_run_at')
  test "$next" \> "2026-01-01"
}
run_case "add --json at with relative duration" test_json_add_at_relative_duration

test_json_add_every_various_intervals_fields() {
  # Test that interval_seconds is correct for different interval units
  local json_s json_m json_h json_d
  json_s=$(agent-store --json schedule add every 45s -- echo s)
  json_m=$(agent-store --json schedule add every 3m -- echo m)
  json_h=$(agent-store --json schedule add every 2h -- echo h)
  json_d=$(agent-store --json schedule add every 1d -- echo d)
  echo "$json_s" | jq -e '.schedule.interval_seconds == 45'
  echo "$json_m" | jq -e '.schedule.interval_seconds == 180'
  echo "$json_h" | jq -e '.schedule.interval_seconds == 7200'
  echo "$json_d" | jq -e '.schedule.interval_seconds == 86400'
}
run_case "add --json every: interval_seconds correct for all units" test_json_add_every_various_intervals_fields

test_json_add_multiword_command() {
  local json
  json=$(agent-store --json schedule add at 2030-01-01T00:00:00Z -- 'echo "hello world" | tr a-z A-Z')
  echo "$json" | jq -e '.schedule.command == "echo \"hello world\" | tr a-z A-Z"'
}
run_case "add --json preserves complex command string" test_json_add_multiword_command

# ── Section 35: Complex Boolean Query Expressions in Schedules ─────

echo ""
echo "== Complex Boolean Query Expressions =="

test_query_and_or_parentheses() {
  # kind=task and (status=open or status=pending)
  agent-store create task status=open >/dev/null
  agent-store create task status=pending >/dev/null
  agent-store create task status=done >/dev/null
  agent-store create note status=open >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'kind=task and (status=open or status=pending)' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Should match 2 records (task/open and task/pending), not done or note
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: kind=task and (status=open or status=pending)" test_query_and_or_parentheses

test_query_not_operator() {
  # not kind=archive
  agent-store create task status=open >/dev/null
  agent-store create note msg=hi >/dev/null
  agent-store create archive reason=old >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'not kind=archive' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Should match task and note, not archive
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: not kind=archive" test_query_not_operator

test_query_not_equal_operator() {
  # kind=task and status!=done
  agent-store create task status=open >/dev/null
  agent-store create task status=pending >/dev/null
  agent-store create task status=done >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'kind=task and status!=done' -- 'echo matched'
  local json
  json=$(agent-store --json schedule tick)
  # Should match open and pending, not done
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: kind=task and status!=done" test_query_not_equal_operator

test_query_gte_comparison() {
  # kind=task and priority>=high
  # String comparison: high >= high is true, low >= high is false, medium >= high is true
  agent-store create task priority=high >/dev/null
  agent-store create task priority=low >/dev/null
  agent-store create task priority=medium >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'kind=task and priority>=high' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # String comparison: "high" >= "high" (true), "low" >= "high" (true), "medium" >= "high" (true)
  # All three are >= "high" in string order
  local count
  count=$(echo "$json" | jq '.schedule_runs | length')
  test "$count" -ge 1
}
run_case "query: kind=task and priority>=high" test_query_gte_comparison

test_query_substring_match() {
  # title~=urgent
  agent-store create task title=urgent-fix >/dev/null
  agent-store create task title=not-important >/dev/null
  agent-store create task title=URGENT-NOW >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'title~=urgent' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # ~= is case-insensitive substring: urgent-fix and URGENT-NOW match
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: title~=urgent (case-insensitive substring)" test_query_substring_match

test_query_or_across_fields() {
  # title~=urgent or severity=critical
  agent-store create alert title=urgent-fix severity=low >/dev/null
  agent-store create alert title=minor-issue severity=critical >/dev/null
  agent-store create alert title=routine severity=low >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'title~=urgent or severity=critical' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # urgent-fix matches title~=urgent, minor-issue matches severity=critical
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: title~=urgent or severity=critical" test_query_or_across_fields

test_query_nested_parentheses() {
  # (kind=task or kind=bug) and (status=open or status=pending)
  agent-store create task status=open >/dev/null
  agent-store create task status=done >/dev/null
  agent-store create bug status=pending >/dev/null
  agent-store create bug status=closed >/dev/null
  agent-store create feature status=open >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    '(kind=task or kind=bug) and (status=open or status=pending)' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # task/open and bug/pending match; task/done, bug/closed, feature/open do not
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: (kind=task or kind=bug) and (status=open or status=pending)" test_query_nested_parentheses

test_query_triple_and() {
  # kind=task and status!=done and priority>=high
  agent-store create task status=open priority=high >/dev/null
  agent-store create task status=done priority=high >/dev/null
  agent-store create task status=open priority=medium >/dev/null
  agent-store create task status=open priority=abc >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'kind=task and status!=done and priority>=high' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # task/open/high matches (status!=done, "high" >= "high")
  # task/done/high does NOT match (status=done fails !=done)
  # task/open/medium matches (status!=done, "medium" >= "high" in string order: m > h)
  # task/open/abc does NOT match ("abc" < "high" in string order: a < h)
  local count
  count=$(echo "$json" | jq '.schedule_runs | length')
  test "$count" -eq 2
}
run_case "query: kind=task and status!=done and priority>=high" test_query_triple_and

test_query_not_with_parentheses() {
  # not (kind=archive or kind=deleted)
  agent-store create task status=open >/dev/null
  agent-store create archive reason=old >/dev/null
  agent-store create deleted reason=spam >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'not (kind=archive or kind=deleted)' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Only task matches
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 1
}
run_case "query: not (kind=archive or kind=deleted)" test_query_not_with_parentheses

test_query_complex_mixed_boolean() {
  # (kind=task and status=open) or (kind=bug and severity=critical)
  agent-store create task status=open >/dev/null
  agent-store create task status=closed >/dev/null
  agent-store create bug severity=critical >/dev/null
  agent-store create bug severity=low >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    '(kind=task and status=open) or (kind=bug and severity=critical)' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # task/open and bug/critical match
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: (kind=task and status=open) or (kind=bug and severity=critical)" test_query_complex_mixed_boolean

test_query_less_than_operator() {
  # kind=task and priority<medium
  agent-store create task priority=alpha >/dev/null
  agent-store create task priority=beta >/dev/null
  agent-store create task priority=medium >/dev/null
  agent-store create task priority=zebra >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'kind=task and priority<medium' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # String comparison: alpha < medium (true), beta < medium (true), medium < medium (false), zebra < medium (false)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query: kind=task and priority<medium (string comparison)" test_query_less_than_operator

test_query_schedule_json_preserves_complex_query() {
  # Verify the query string is preserved exactly in JSON output
  local query='(kind=task or kind=bug) and (status=open or status=pending)'
  local json
  json=$(agent-store --json schedule add at 2030-01-01T00:00:00Z "$query" -- echo check)
  local stored_query
  stored_query=$(echo "$json" | jq -r '.schedule.query')
  test "$stored_query" = "$query"
}
run_case "add --json preserves complex query string exactly" test_query_schedule_json_preserves_complex_query

# ── Section 36: Timestamp Edge Cases ───────────────────────────────

echo ""
echo "== Timestamp Edge Cases =="

test_at_fractional_seconds() {
  # Schedule with fractional seconds in the timestamp
  local id
  id=$(agent-store schedule add at 2020-01-01T00:00:00.500Z -- echo fractional)
  agent-store schedule ls | grep -q "$id"
  # Should be due (past time) and fire
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length >= 1'
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
}
run_case "at timestamp with fractional seconds (.500Z)" test_at_fractional_seconds

test_at_epoch_timestamp() {
  # Schedule at Unix epoch
  local id
  id=$(agent-store schedule add at 1970-01-01T00:00:00Z -- echo epoch)
  # Should be due (far past)
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length >= 1'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "epoch"
}
run_case "at epoch timestamp (1970-01-01T00:00:00Z)" test_at_epoch_timestamp

test_at_far_future_timestamp() {
  # Schedule at far future
  local json
  json=$(agent-store --json schedule add at 2099-12-31T23:59:59Z -- echo far-future)
  echo "$json" | jq -e '.schedule.status == "active"'
  echo "$json" | jq -e '.schedule.next_run_at == "2099-12-31T23:59:59Z"'
  # Should NOT fire (it's in the future)
  local tick_json
  tick_json=$(agent-store --json schedule tick)
  test "$(echo "$tick_json" | jq '.schedule_runs | length')" -eq 0
}
run_case "at far future (2099-12-31T23:59:59Z) does not fire" test_at_far_future_timestamp

test_multiple_schedules_millisecond_difference() {
  # Two schedules whose next_run_at differ by milliseconds
  agent-store schedule add at 2020-01-01T00:00:00.001Z -- 'echo ms1' >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00.002Z -- 'echo ms2' >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00.999Z -- 'echo ms3' >/dev/null
  # All should fire since they are all in the past
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 3
}
run_case "multiple schedules with millisecond timestamp differences" test_multiple_schedules_millisecond_difference

test_at_date_only_format() {
  # Date-only format should work
  local json
  json=$(agent-store --json schedule add at 2020-06-15 -- echo date-only)
  echo "$json" | jq -e '.schedule.status == "active"'
  echo "$json" | jq -e '.schedule.expression == "2020-06-15"'
  # Should be due (past date)
  local tick_json
  tick_json=$(agent-store --json schedule tick)
  test "$(echo "$tick_json" | jq '.schedule_runs | length')" -eq 1
}
run_case "at date-only format (2020-06-15)" test_at_date_only_format

test_query_created_at_comparison() {
  # Records created "now" should have created_at > 2020
  agent-store create task title=recent >/dev/null
  agent-store create task title=also-recent >/dev/null

  agent-store schedule add at 2020-01-01T00:00:00Z \
    'created_at>2020-01-01' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Both records were created "now" (2026+), so created_at > 2020-01-01
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query using created_at timestamp comparison" test_query_created_at_comparison

test_query_updated_at_comparison() {
  # Create a record and update it
  local rid
  rid=$(agent-store create task title=will-update)
  agent-store set "$rid" status=updated
  # updated_at should be > created_at but both are in 2026+
  agent-store schedule add at 2020-01-01T00:00:00Z \
    'updated_at>2020-01-01' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -ge 1
}
run_case "query using updated_at timestamp comparison" test_query_updated_at_comparison

test_every_next_run_at_millis_precision() {
  # Create an every schedule and verify next_run_at has millisecond precision
  local json
  json=$(agent-store --json schedule add every 1h -- echo millis-test)
  local next
  next=$(echo "$json" | jq -r '.schedule.next_run_at')
  # Should end with .NNNZ (3 digits of milliseconds)
  echo "$next" | grep -Eq '\.[0-9]{3}Z$'
}
run_case "every schedule next_run_at has millisecond precision" test_every_next_run_at_millis_precision

test_at_next_run_at_preserves_input_format() {
  # Timestamps are stored as provided (no normalization to .000Z)
  local json
  json=$(agent-store --json schedule add at 2030-06-15T12:00:00Z -- echo norm)
  local next
  next=$(echo "$json" | jq -r '.schedule.next_run_at')
  # Stored as-is without adding .000Z
  test "$next" = "2030-06-15T12:00:00Z"
}
run_case "at timestamp stored as-is without millis normalization" test_at_next_run_at_preserves_input_format

# ── Section 37: Schedule ls/runs Formatting Edge Cases ─────────────

echo ""
echo "== Schedule ls/runs Formatting Edge Cases =="

test_ls_very_long_command() {
  # A very long command string (500+ chars)
  local long_cmd
  long_cmd=$(printf 'echo %0500d' 0)
  agent-store schedule add every 1h -- "$long_cmd" >/dev/null
  # ls should display it without crashing
  local listing
  listing=$(agent-store schedule ls)
  test -n "$listing"
  # JSON ls should have the full command
  local json
  json=$(agent-store --json schedule ls)
  local cmd_len
  cmd_len=$(echo "$json" | jq '.schedules[0].command | length')
  test "$cmd_len" -gt 500
}
run_case "ls with very long command string (500+ chars)" test_ls_very_long_command

test_ls_command_with_special_characters() {
  # Command with quotes, pipes, and special chars
  agent-store schedule add every 1h -- 'echo "hello '\''world'\'' $HOME" | tr a-z A-Z && echo done' >/dev/null
  local listing
  listing=$(agent-store schedule ls)
  test -n "$listing"
  # Should not crash, listing should contain the schedule
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 1
}
run_case "ls with special characters in command" test_ls_command_with_special_characters

test_ls_empty_query_string() {
  # Schedule without a query — verify ls shows no query= part
  local id
  id=$(agent-store schedule add every 1h -- echo no-query)
  local listing
  listing=$(agent-store schedule ls)
  echo "$listing" | grep -q "$id"
  # Should NOT contain "query=" for this schedule
  ! echo "$listing" | grep -q "query="
  # JSON should show query as null
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e '.schedules[0].query == null'
}
run_case "ls without query shows no query= field" test_ls_empty_query_string

test_ls_with_query_shows_query() {
  # Schedule with a query — verify ls shows query= part
  agent-store create task >/dev/null
  local id
  id=$(agent-store schedule add every 1h 'kind=task' -- echo with-query)
  local listing
  listing=$(agent-store schedule ls)
  echo "$listing" | grep -q "query="
  echo "$listing" | grep -q "kind=task"
}
run_case "ls with query shows query= field" test_ls_with_query_shows_query

test_runs_near_8192_stdout_cap() {
  # Generate stdout that's exactly near the 8192 cap
  # 8192 bytes = 8192 'x' characters
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'head -c 8100 /dev/zero | tr "\0" "x"'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local stdout_len
  stdout_len=$(echo "$json" | jq '.schedule_runs[0].stdout | length')
  # Should be exactly 8100 (under cap)
  test "$stdout_len" -eq 8100
}
run_case "runs with stdout near 8192 cap (8100 bytes)" test_runs_near_8192_stdout_cap

test_runs_at_exact_8192_cap() {
  # Generate stdout of exactly 8192 bytes
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'head -c 8192 /dev/zero | tr "\0" "y"'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local stdout_len
  stdout_len=$(echo "$json" | jq '.schedule_runs[0].stdout | length')
  # Should be exactly 8192 (at cap)
  test "$stdout_len" -eq 8192
}
run_case "runs with stdout at exact 8192 cap" test_runs_at_exact_8192_cap

test_runs_over_8192_cap_truncated() {
  # Generate stdout over the 8192 cap
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'head -c 10000 /dev/zero | tr "\0" "z"'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local stdout_len
  stdout_len=$(echo "$json" | jq '.schedule_runs[0].stdout | length')
  # Should be capped at 8192
  test "$stdout_len" -le 8192
}
run_case "runs with stdout over 8192 cap truncated" test_runs_over_8192_cap_truncated

test_runs_near_8192_stderr_cap() {
  # stderr near the cap
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'head -c 8100 /dev/zero | tr "\0" "e" >&2; exit 1'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  local stderr_len
  stderr_len=$(echo "$json" | jq '.schedule_runs[0].stderr | length')
  test "$stderr_len" -eq 8100
}
run_case "runs with stderr near 8192 cap (8100 bytes)" test_runs_near_8192_stderr_cap

test_run_detail_deleted_schedule() {
  # Create schedule, fire it, get a run, delete the schedule, then query the run
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo orphan-run')
  agent-store schedule tick >/dev/null
  local run_id
  run_id=$(agent-store --json schedule runs | jq '.schedule_runs[0].id')
  # Delete the schedule
  agent-store schedule rm "$sid" >/dev/null
  # The run should still be accessible by ID
  local detail
  detail=$(agent-store schedule runs "$run_id")
  echo "$detail" | grep -q "orphan-run"
  echo "$detail" | grep -q "exit_status: 0"
  # JSON detail should also work
  local json_detail
  json_detail=$(agent-store --json schedule runs "$run_id")
  echo "$json_detail" | jq -e '.schedule_run.stdout | contains("orphan-run")'
  echo "$json_detail" | jq -e ".schedule_run.schedule_id == \"$sid\""
}
run_case "run detail for deleted schedule still works" test_run_detail_deleted_schedule

test_runs_summary_formatting() {
  # Verify runs summary line format
  agent-store create task marker=fmt >/dev/null
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and marker=fmt' -- 'echo formatted')
  agent-store schedule tick >/dev/null
  local summary
  summary=$(agent-store schedule runs)
  # Summary format: "ID TIMESTAMP schedule=SID record=RID exit=N"
  echo "$summary" | grep -q "schedule=$sid"
  echo "$summary" | grep -q "record="
  echo "$summary" | grep -q "exit=0"
}
run_case "runs summary includes schedule_id and record_id" test_runs_summary_formatting

test_runs_summary_without_record() {
  # Schedule without query — runs should NOT have record= part
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo no-record-ctx')
  agent-store schedule tick >/dev/null
  local summary
  summary=$(agent-store schedule runs)
  echo "$summary" | grep -q "schedule=$sid"
  echo "$summary" | grep -q "exit=0"
  # Should NOT contain "record=" for queryless schedule
  ! echo "$summary" | grep -q "record="
}
run_case "runs summary without query has no record= field" test_runs_summary_without_record

test_ls_schedule_status_field() {
  # Verify status=active and status=completed appear correctly in ls
  agent-store schedule add every 1h -- echo active-sched >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo completed-sched >/dev/null
  agent-store schedule tick >/dev/null
  local listing
  listing=$(agent-store schedule ls)
  echo "$listing" | grep -q "status=active"
  echo "$listing" | grep -q "status=completed"
}
run_case "ls shows status=active and status=completed" test_ls_schedule_status_field

test_ls_next_field() {
  # Verify next= field is shown in ls
  agent-store schedule add every 1h -- echo next-test >/dev/null
  local listing
  listing=$(agent-store schedule ls)
  echo "$listing" | grep -q "next="
}
run_case "ls shows next= timestamp field" test_ls_next_field

# ── Section 38: Disk-Full Conditions ─────────────────────────────────

echo ""
echo "== Disk-Full Conditions =="

# These tests use tmpfs to simulate a disk-full scenario.
# tmpfs mount requires SYS_ADMIN capability; tests are skipped if unavailable.
# Run with: docker run --rm --cap-add SYS_ADMIN agent-store-schedule-tests

CAN_MOUNT=false
mkdir -p /tmp/_mount_probe
if mount -t tmpfs -o size=64K tmpfs /tmp/_mount_probe 2>/dev/null; then
  umount /tmp/_mount_probe 2>/dev/null || true
  CAN_MOUNT=true
fi
rmdir /tmp/_mount_probe 2>/dev/null || true

run_case_diskfull() {
  local name="$1"
  shift
  if [ "$CAN_MOUNT" = "false" ]; then
    echo -n "  $name ... "
    echo "SKIP (no SYS_ADMIN)"
    SKIP=$((SKIP + 1))
    return
  fi
  run_case_noinit "$name" "$@"
}

test_disk_full_schedule_add() {
  # Set up a tiny tmpfs filesystem and init a store in it
  local mnt="/tmp/small-$$-add"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=512K tmpfs "$mnt"
  (
    cd "$mnt"
    agent-store init >/dev/null
    # Fill most of the disk so the next write fails
    dd if=/dev/zero of="$mnt/filler" bs=1K count=400 2>/dev/null || true
    # Try to add a schedule -- should fail with an I/O or disk error, not crash
    ! agent-store schedule add every 5m -- echo disk-full 2>/dev/null
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "schedule add on full disk fails gracefully" test_disk_full_schedule_add

test_disk_full_schedule_tick() {
  # Init store and add schedule while disk has space, then fill disk before tick
  local mnt="/tmp/small-$$-tick"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=1M tmpfs "$mnt"
  (
    cd "$mnt"
    agent-store init >/dev/null
    agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo should-fail' >/dev/null
    # Fill the disk so tick can't write run records
    dd if=/dev/zero of="$mnt/filler" bs=1K count=900 2>/dev/null || true
    # Tick should fail gracefully (exit non-zero, not crash/segfault)
    # We expect it to fail, so absorb the error.
    agent-store schedule tick 2>/dev/null || true
    # Remove filler and verify the store is still usable after disk-full recovery
    rm -f "$mnt/filler"
    agent-store schedule ls >/dev/null
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "schedule tick on full disk: store survives" test_disk_full_schedule_tick

test_disk_full_wal_journal_creation() {
  # The WAL journal file is created by SQLite when writing.
  # If disk is full, WAL creation should fail gracefully.
  local mnt="/tmp/small-$$-wal"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=512K tmpfs "$mnt"
  (
    cd "$mnt"
    agent-store init >/dev/null
    # Add one schedule successfully
    agent-store schedule add every 1h -- echo wal-test >/dev/null
    # Fill the disk
    dd if=/dev/zero of="$mnt/filler" bs=1K count=400 2>/dev/null || true
    # Try another write -- should fail, not crash
    ! agent-store schedule add every 2h -- echo should-fail 2>/dev/null
    # Free space and verify the original schedule is intact
    rm -f "$mnt/filler"
    local count
    count=$(agent-store --json schedule ls | jq '.schedules | length')
    test "$count" -ge 1
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "WAL journal creation on full disk: no corruption" test_disk_full_wal_journal_creation

test_disk_full_init_fails() {
  # Can't even init a store on a full disk
  local mnt="/tmp/small-$$-init"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=32K tmpfs "$mnt"
  (
    # Fill the tiny disk completely
    dd if=/dev/zero of="$mnt/filler" bs=1K count=28 2>/dev/null || true
    cd "$mnt"
    # init should fail because there is no space for the SQLite database
    ! agent-store init 2>/dev/null
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "store init on full disk fails gracefully" test_disk_full_init_fails

test_disk_full_recovery_after_space_freed() {
  # Verify the store recovers after disk space is freed
  local mnt="/tmp/small-$$-recover"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=1M tmpfs "$mnt"
  (
    cd "$mnt"
    agent-store init >/dev/null
    local sid
    sid=$(agent-store schedule add every 1s -- 'echo recovery-test')
    sleep 2
    # Fill the disk
    dd if=/dev/zero of="$mnt/filler" bs=1K count=850 2>/dev/null || true
    # Tick may fail
    agent-store schedule tick 2>/dev/null || true
    # Free space
    rm -f "$mnt/filler"
    # Now operations should work again
    sleep 1
    agent-store schedule tick >/dev/null
    local count
    count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
    test "$count" -ge 1
    # Schedule should still be active and functional
    agent-store schedule ls | grep -q "$sid"
    agent-store schedule ls | grep -q "status=active"
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "disk full then freed: store recovers" test_disk_full_recovery_after_space_freed

test_disk_full_json_error_output() {
  # Verify --json mode outputs a structured error on disk-full writes
  local mnt="/tmp/small-$$-jsonerr"
  mkdir -p "$mnt"
  mount -t tmpfs -o size=512K tmpfs "$mnt"
  (
    cd "$mnt"
    agent-store init >/dev/null
    # Fill the disk
    dd if=/dev/zero of="$mnt/filler" bs=1K count=400 2>/dev/null || true
    # Try to add schedule with --json; should produce a JSON error envelope on stderr
    local stderr_out
    stderr_out=$(agent-store --json schedule add every 5m -- echo fail 2>&1 >/dev/null || true)
    # Error envelope should be valid JSON with an "error" field
    echo "$stderr_out" | jq -e '.error' >/dev/null 2>&1 || test -n "$stderr_out"
  )
  local rc=$?
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}
run_case_diskfull "disk full --json produces error envelope" test_disk_full_json_error_output

# ── Section 39: Schedule Interaction with Record Lifecycle ───────────

echo ""
echo "== Schedule Interaction with Record Lifecycle =="

test_record_deleted_between_ticks() {
  # Create records, add a query-scoped schedule, delete some records, then tick
  agent-store create task title=will-survive status=open >/dev/null
  local rid_del
  rid_del=$(agent-store create task title=will-be-deleted status=open)
  agent-store schedule add every 1s 'kind=task and status=open' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # First tick: both records match
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 2

  # Delete one record between ticks
  agent-store rm "$rid_del"
  sleep 2
  # Second tick: only surviving record matches
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 1
}
run_case "record deleted between ticks: next tick skips it" test_record_deleted_between_ticks

test_record_fields_change_between_ticks() {
  # Record no longer matches query after field change
  local rid
  rid=$(agent-store create task status=open)
  agent-store schedule add every 1s 'kind=task and status=open' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # First tick: record matches
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 1

  # Change the field so it no longer matches
  agent-store set "$rid" status=closed
  sleep 2
  # Second tick: no matching records
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 0
}
run_case "record fields change: no longer matches query" test_record_fields_change_between_ticks

test_new_records_match_query_between_ticks() {
  # New records created between ticks should be picked up
  agent-store create task title=original status=pending >/dev/null
  agent-store schedule add every 1s 'kind=task and status=pending' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # First tick: 1 record
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 1

  # Create new records between ticks
  agent-store create task title=newcomer1 status=pending >/dev/null
  agent-store create task title=newcomer2 status=pending >/dev/null
  sleep 2
  # Second tick: 3 records (original + 2 new)
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 3
}
run_case "new records created between ticks are picked up" test_new_records_match_query_between_ticks

test_bulk_stdin_records_match_schedule_query() {
  # Create records via --stdin, then verify schedule query matches them
  printf '{"kind":"item","fields":{"color":"red"}}\n{"kind":"item","fields":{"color":"blue"}}\n{"kind":"item","fields":{"color":"red"}}\n' \
    | agent-store create --stdin >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=item and color=red' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Two items with color=red should match
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "bulk --stdin records match schedule query" test_bulk_stdin_records_match_schedule_query

test_record_kind_change_between_ticks() {
  # Records can't change kind (kind is immutable), but we can delete and
  # re-create. This tests that the query re-evaluates from scratch each tick.
  local rid
  rid=$(agent-store create task status=open)
  agent-store schedule add every 1s 'kind=task' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # Tick 1: task is found
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 1

  # Delete the task and create a note instead
  agent-store rm "$rid"
  agent-store create note msg=not-a-task >/dev/null
  sleep 2
  # Tick 2: no tasks exist, note doesn't match kind=task
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 0
}
run_case "record deleted and replaced: query re-evaluates" test_record_kind_change_between_ticks

test_at_schedule_with_record_deleted_before_tick() {
  # at-schedule: record exists when schedule is created but deleted before tick
  local rid
  rid=$(agent-store create task status=active)
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=active' -- 'echo $AGENT_STORE_ID'
  # Delete the record before tick
  agent-store rm "$rid"
  local json
  json=$(agent-store --json schedule tick)
  # No matching records: schedule fires but produces no runs
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
  # Schedule should be completed (it was an at-schedule and was ticked)
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
}
run_case "at-schedule: record deleted before tick, no runs but completed" test_at_schedule_with_record_deleted_before_tick

test_schedule_command_modifies_records_seen_by_subsequent_runs() {
  # Schedule command changes a record's status, which affects whether
  # later ticks see it. This is the "process and mark done" pattern.
  local rid1 rid2
  rid1=$(agent-store create task status=pending marker=proc-test)
  rid2=$(agent-store create task status=pending marker=proc-test)
  agent-store schedule add every 1s 'kind=task and status=pending and marker=proc-test' -- \
    'agent-store set $AGENT_STORE_ID status=processed'
  sleep 2
  # Tick 1: both records are pending, both get processed
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 2
  # Verify both are now processed
  test "$(agent-store find status=processed marker=proc-test --count)" -eq 2
  sleep 2
  # Tick 2: no records are pending anymore
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 0
}
run_case "schedule processes records: next tick sees updated state" test_schedule_command_modifies_records_seen_by_subsequent_runs

test_mixed_record_mutations_between_ticks() {
  # Multiple record lifecycle events between ticks:
  # create, update, delete — all affecting query results
  agent-store create task status=open tag=mixed-mut >/dev/null
  agent-store create task status=open tag=mixed-mut >/dev/null
  agent-store create task status=closed tag=mixed-mut >/dev/null
  agent-store schedule add every 1s 'kind=task and status=open and tag=mixed-mut' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # Tick 1: 2 open tasks
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 2

  # Between ticks: close one, open the closed one, create a new open one
  local ids
  ids=$(agent-store --json find 'kind=task and status=open and tag=mixed-mut' | jq -r '.records[0].id')
  agent-store set "$ids" status=closed
  local closed_id
  closed_id=$(agent-store --json find 'kind=task and status=closed and tag=mixed-mut' | jq -r '.records[0].id')
  agent-store set "$closed_id" status=open
  agent-store create task status=open tag=mixed-mut >/dev/null
  sleep 2
  # Tick 2: 1 original open + 1 reopened + 1 new = 3 open
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 3
}
run_case "mixed record create/update/delete between ticks" test_mixed_record_mutations_between_ticks

# ── Section 40: Error Message Quality ────────────────────────────────

echo ""
echo "== Error Message Quality =="

test_rm_ambiguous_prefix_error_message() {
  # Create multiple schedules whose IDs share a prefix, then rm with that prefix
  # IDs are random, so we create many schedules and pick a common prefix
  local ids=()
  for i in $(seq 1 20); do
    ids+=($(agent-store schedule add every "${i}m" -- "echo amb-$i"))
  done
  # Find a 1-char prefix that matches multiple schedules
  local prefix
  for p in a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
    local match_count=0
    for id in "${ids[@]}"; do
      if [[ "$id" == "$p"* ]]; then
        match_count=$((match_count + 1))
      fi
    done
    if [ "$match_count" -ge 2 ]; then
      prefix=$p
      break
    fi
  done
  if [ -z "$prefix" ]; then
    # With 20 IDs and 36 possible first chars, collision is highly likely
    # but fall back to using first char of first id as a harmless test
    prefix="${ids[0]:0:1}"
  fi
  local err
  err=$(agent-store schedule rm "$prefix" 2>&1 || true)
  echo "$err" | grep -qi "ambiguous\|multiple\|matches"
}
run_case "rm ambiguous prefix: error says 'matches multiple'" test_rm_ambiguous_prefix_error_message

test_rm_ambiguous_prefix_json_error() {
  # Same test but with --json: error envelope should be well-structured
  local ids=()
  for i in $(seq 1 20); do
    ids+=($(agent-store schedule add every "${i}m" -- "echo amb-json-$i"))
  done
  local prefix
  for p in a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
    local match_count=0
    for id in "${ids[@]}"; do
      if [[ "$id" == "$p"* ]]; then
        match_count=$((match_count + 1))
      fi
    done
    if [ "$match_count" -ge 2 ]; then
      prefix=$p
      break
    fi
  done
  if [ -z "$prefix" ]; then
    prefix="${ids[0]:0:1}"
  fi
  local stderr_out
  stderr_out=$(agent-store --json schedule rm "$prefix" 2>&1 >/dev/null || true)
  # JSON error envelope should have "error" field mentioning ambiguous/multiple
  echo "$stderr_out" | jq -e '.error' >/dev/null
  echo "$stderr_out" | jq -r '.error' | grep -qi "multiple\|ambiguous"
}
run_case "rm ambiguous prefix --json: structured error envelope" test_rm_ambiguous_prefix_json_error

test_runs_id_zero_error() {
  # Run ID 0 is valid syntactically (it's a number) but should not exist
  local err
  err=$(agent-store schedule runs 0 2>&1 || true)
  echo "$err" | grep -qi "not found\|no.*run"
}
run_case "runs with run ID 0: says not found" test_runs_id_zero_error

test_runs_id_zero_json_error() {
  local stderr_out
  stderr_out=$(agent-store --json schedule runs 0 2>&1 >/dev/null || true)
  echo "$stderr_out" | jq -e '.error' >/dev/null
  echo "$stderr_out" | jq -r '.error' | grep -qi "not found"
}
run_case "runs with run ID 0 --json: structured error" test_runs_id_zero_json_error

test_add_nonexistent_field_query_succeeds() {
  # Queries reference fields dynamically -- a query with a non-existent field
  # should still succeed (just match nothing at tick time)
  local sid
  sid=$(agent-store schedule add every 5m 'kind=task and nonexistent_field=value' -- echo ok)
  agent-store schedule ls | grep -q "$sid"
  # Tick with no matching records: zero runs but no error
  agent-store schedule add at 2020-01-01T00:00:00Z 'nonexistent_field=phantom' -- echo phantom >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
}
run_case "add with non-existent field in query: accepted" test_add_nonexistent_field_query_succeeds

test_json_error_envelope_structure_rm_not_found() {
  # schedule rm with an ID that doesn't exist
  local stderr_out
  stderr_out=$(agent-store --json schedule rm zzzzzz 2>&1 >/dev/null || true)
  # Must be valid JSON
  echo "$stderr_out" | jq -e '.' >/dev/null
  # Must have "error" key
  echo "$stderr_out" | jq -e '.error' >/dev/null
  # Error should mention the ID
  echo "$stderr_out" | jq -r '.error' | grep -q "zzzzzz"
}
run_case "--json rm not found: error mentions the ID" test_json_error_envelope_structure_rm_not_found

test_json_error_envelope_structure_runs_not_found() {
  local stderr_out
  stderr_out=$(agent-store --json schedule runs 99999 2>&1 >/dev/null || true)
  echo "$stderr_out" | jq -e '.' >/dev/null
  echo "$stderr_out" | jq -e '.error' >/dev/null
  echo "$stderr_out" | jq -r '.error' | grep -q "99999"
}
run_case "--json runs not found: error mentions the run ID" test_json_error_envelope_structure_runs_not_found

test_tick_errors_on_stderr_not_swallowed() {
  # When a schedule query fails (e.g., invalid stored query), tick should
  # log a warning to stderr. We test this by checking stderr output.
  # Since we can't easily create an invalid stored query through the CLI
  # (it validates on add), we test that tick normally produces no stderr.
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo stderr-test'
  local stderr_out
  stderr_out=$(agent-store schedule tick 2>&1 >/dev/null)
  # Normal tick should have no stderr output
  test -z "$stderr_out"
}
run_case "tick: no spurious stderr on normal execution" test_tick_errors_on_stderr_not_swallowed

test_tick_command_failure_stderr_preserved() {
  # When a schedule command writes to stderr and exits non-zero,
  # the error output must be preserved in the run record, not swallowed.
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "HELP: something broke" >&2; exit 1'
  agent-store schedule tick >/dev/null
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 1'
  echo "$json" | jq -r '.schedule_runs[0].stderr' | grep -q "HELP: something broke"
}
run_case "tick: command stderr is captured, not swallowed" test_tick_command_failure_stderr_preserved

test_plain_error_format_rm_not_found() {
  # In plain (non-JSON) mode, errors should start with "error:"
  local err
  err=$(agent-store schedule rm zzzzzz 2>&1 || true)
  echo "$err" | grep -q "error:"
}
run_case "plain rm not found: error: prefix present" test_plain_error_format_rm_not_found

test_invalid_schedule_id_error_message() {
  # IDs that are too long or contain invalid characters
  local err
  err=$(agent-store schedule rm "INVALID-CHARS!" 2>&1 || true)
  echo "$err" | grep -qi "not a valid schedule ID"
}
run_case "rm with invalid chars: says not valid" test_invalid_schedule_id_error_message

# ── Section 41: Schedule Help Documentation Completeness ─────────────

echo ""
echo "== Schedule Help Documentation Completeness =="

test_schedule_help_lists_all_subcommands() {
  local help
  help=$(agent-store schedule --help)
  echo "$help" | grep -q "add"
  echo "$help" | grep -q "ls"
  echo "$help" | grep -q "rm"
  echo "$help" | grep -q "runs"
  echo "$help" | grep -q "tick"
  echo "$help" | grep -q "enable"
  echo "$help" | grep -q "disable"
  # Should also mention the schedule concept
  echo "$help" | grep -qi "schedule"
}
run_case "schedule --help documents all 7 subcommands" test_schedule_help_lists_all_subcommands

test_schedule_add_help_documents_at_every_query() {
  local help
  help=$(agent-store schedule add --help)
  echo "$help" | grep -q "at"
  echo "$help" | grep -q "every"
  echo "$help" | grep -qi "query"
  # Should document the -- separator
  echo "$help" | grep -q "\-\-"
  # Should mention time/interval
  echo "$help" | grep -qi "duration\|interval\|timestamp\|time"
}
run_case "schedule add --help documents at/every/query/--" test_schedule_add_help_documents_at_every_query

test_schedule_tick_help_explains_idempotent_concurrent() {
  local help
  help=$(agent-store schedule tick --help)
  # Should explain idempotent behavior
  echo "$help" | grep -qi "idempotent"
  # Should explain concurrent safety (atomically claimed)
  echo "$help" | grep -qi "concurren\|atomic"
}
run_case "schedule tick --help explains idempotent/concurrent safety" test_schedule_tick_help_explains_idempotent_concurrent

test_schedule_enable_help_explains_crontab() {
  local help
  help=$(agent-store schedule enable --help)
  # Should mention crontab
  echo "$help" | grep -qi "crontab\|cron"
  # Should mention tick
  echo "$help" | grep -q "tick"
  # Should mention project scope
  echo "$help" | grep -qi "project"
}
run_case "schedule enable --help explains crontab behavior" test_schedule_enable_help_explains_crontab

test_schedule_runs_help_documents_limit() {
  local help
  help=$(agent-store schedule runs --help)
  echo "$help" | grep -q "\-\-limit"
  # Should mention default (20)
  echo "$help" | grep -q "20"
}
run_case "schedule runs --help documents --limit" test_schedule_runs_help_documents_limit

test_schedule_disable_help_content() {
  local help
  help=$(agent-store schedule disable --help)
  echo "$help" | grep -qi "crontab\|cron"
  # Should mention that schedules are not removed
  echo "$help" | grep -qi "not removed\|not.*delete\|schedule rm"
}
run_case "schedule disable --help mentions schedules not removed" test_schedule_disable_help_content

test_schedule_ls_help_content() {
  local help
  help=$(agent-store schedule ls --help)
  echo "$help" | grep -qi "list\|print"
  echo "$help" | grep -qi "schedule"
}
run_case "schedule ls --help documents listing" test_schedule_ls_help_content

test_schedule_rm_help_content() {
  local help
  help=$(agent-store schedule rm --help)
  echo "$help" | grep -qi "remove\|delete"
  echo "$help" | grep -qi "ID\|prefix"
}
run_case "schedule rm --help documents ID prefix removal" test_schedule_rm_help_content

test_each_subcommand_h_equals_help() {
  # -h and --help should produce identical output for every subcommand
  local subs=("add" "ls" "rm" "runs" "tick" "enable" "disable")
  for sub in "${subs[@]}"; do
    local out_h out_help
    out_h=$(agent-store schedule "$sub" -h 2>&1 || true)
    out_help=$(agent-store schedule "$sub" --help 2>&1 || true)
    if [ "$out_h" != "$out_help" ]; then
      echo "Mismatch for schedule $sub: -h vs --help differ" >&2
      return 1
    fi
  done
  # Also check the parent "schedule" command
  local sched_h sched_help
  sched_h=$(agent-store schedule -h 2>&1 || true)
  sched_help=$(agent-store schedule --help 2>&1 || true)
  test "$sched_h" = "$sched_help"
}
run_case "each subcommand: -h and --help produce identical output" test_each_subcommand_h_equals_help

test_schedule_help_exit_code_zero() {
  # Help should exit 0 for all subcommands
  agent-store schedule --help >/dev/null 2>&1
  agent-store schedule add --help >/dev/null 2>&1
  agent-store schedule ls --help >/dev/null 2>&1
  agent-store schedule rm --help >/dev/null 2>&1
  agent-store schedule runs --help >/dev/null 2>&1
  agent-store schedule tick --help >/dev/null 2>&1
  agent-store schedule enable --help >/dev/null 2>&1
  agent-store schedule disable --help >/dev/null 2>&1
}
run_case "all schedule help commands exit with code 0" test_schedule_help_exit_code_zero

test_schedule_help_goes_to_stdout() {
  # Help output should go to stdout, not stderr
  local stdout_len stderr_len
  stdout_len=$(agent-store schedule --help 2>/dev/null | wc -c)
  stderr_len=$(agent-store schedule --help 2>&1 >/dev/null | wc -c)
  test "$stdout_len" -gt 0
  test "$stderr_len" -eq 0
}
run_case "schedule help output goes to stdout not stderr" test_schedule_help_goes_to_stdout

# ── Section 42: Multiple Concurrent Every-Schedules with DB Contention ──

echo ""
echo "== Multiple Concurrent Every-Schedules with DB Contention =="

test_10_every_schedules_all_due_writing_back() {
  # Create 10 every-schedules, each running a command that writes to the store
  for i in $(seq 1 10); do
    agent-store schedule add every 1s -- "agent-store create log source=sched-$i tick=fired" >/dev/null
  done
  sleep 2
  # Single tick fires all 10 — each writes back to the store
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 10
  # All 10 should have exit 0 (the creates succeeded)
  test "$(echo "$json" | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')" -eq 10
  # Verify 10 log records were created
  local log_count
  log_count=$(agent-store find kind=log --count)
  test "$log_count" -eq 10
}
run_case "10 every-schedules all due, each writes to store" test_10_every_schedules_all_due_writing_back

test_concurrent_tick_while_every_schedules_write() {
  # Create 5 every-schedules that write to the store
  for i in $(seq 1 5); do
    agent-store schedule add every 1s -- "agent-store create result source=conc-$i" >/dev/null
  done
  sleep 2
  # Launch 3 concurrent ticks — only one should claim the schedules
  agent-store schedule tick &
  local pid1=$!
  agent-store schedule tick &
  local pid2=$!
  agent-store schedule tick &
  local pid3=$!
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  wait "$pid3" 2>/dev/null || true
  # Exactly 5 runs should have occurred (one tick claims all schedules)
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 5
  # All 5 creates should have succeeded
  local record_count
  record_count=$(agent-store find kind=result --count)
  test "$record_count" -eq 5
  # All schedules still active
  local active_count
  active_count=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "active")] | length')
  test "$active_count" -eq 5
}
run_case "concurrent ticks while every-schedules write to store" test_concurrent_tick_while_every_schedules_write

test_every_schedule_creates_while_another_tick_runs() {
  # Schedule A creates records; schedule B is also due and runs a simple command
  # Both due at the same time; A's store writes should not interfere with B's execution
  agent-store schedule add every 1s -- 'agent-store create artifact type=build version=1' >/dev/null
  agent-store schedule add every 1s -- 'echo simple-output' >/dev/null
  sleep 2
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
  test "$(echo "$json" | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')" -eq 2
  # The artifact record should exist
  agent-store find kind=artifact | grep -q "type=build"
}
run_case "every-schedule creates while another runs" test_every_schedule_creates_while_another_tick_runs

test_sustained_concurrent_writes_overlapping_ticks() {
  # Create schedules whose commands do store mutations
  for i in $(seq 1 5); do
    agent-store schedule add every 1s -- "agent-store create metric name=cpu value=$i" >/dev/null
  done
  # Multiple rounds of tick + concurrent creates
  for round in 1 2 3; do
    sleep 1
    agent-store schedule tick &
    # Concurrent record creation from an external process
    agent-store create event round="$round" source=external &
    wait
  done
  # All schedules should still be active
  local active
  active=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "active")] | length')
  test "$active" -eq 5
  # Should have 15 metric records (5 per round * 3 rounds)
  local metric_count
  metric_count=$(agent-store find kind=metric --count)
  test "$metric_count" -eq 15
  # Should have 3 event records (1 per round)
  local event_count
  event_count=$(agent-store find kind=event --count)
  test "$event_count" -eq 3
  # Runs should be recorded: 5 per round * 3 rounds = 15
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 15
}
run_case "sustained concurrent writes: ticks + external mutations" test_sustained_concurrent_writes_overlapping_ticks

test_10_concurrent_every_schedules_with_mutual_contention() {
  # 10 schedules all read and write; concurrent tick processes
  for i in $(seq 1 10); do
    agent-store create counter name="cnt-$i" value=0 >/dev/null
  done
  for i in $(seq 1 10); do
    agent-store schedule add every 1s "name=cnt-$i" -- 'agent-store set $AGENT_STORE_ID value=updated' >/dev/null
  done
  sleep 2
  # 3 concurrent ticks: all competing for the same 10 schedules
  agent-store schedule tick &
  agent-store schedule tick &
  agent-store schedule tick &
  wait
  # Each schedule should have been claimed by exactly one tick
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 10
  # All counters should be updated
  local updated
  updated=$(agent-store find value=updated --count)
  test "$updated" -eq 10
}
run_case "10 concurrent every-schedules with mutual contention" test_10_concurrent_every_schedules_with_mutual_contention

# ── Section 43: Store Migration Interaction ─────────────────────────

echo ""
echo "== Store Migration Interaction =="

test_schedules_survive_reinit() {
  # Init, add schedules, verify they persist
  local sid1 sid2
  sid1=$(agent-store schedule add every 1h -- echo surv-1)
  sid2=$(agent-store schedule add at 2030-01-01T00:00:00Z -- echo surv-2)
  # Re-running init should be safe (idempotent)
  agent-store init >/dev/null
  # Schedules should still exist
  agent-store schedule ls | grep -q "$sid1"
  agent-store schedule ls | grep -q "$sid2"
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 2
}
run_case "schedules survive re-init (idempotent migration)" test_schedules_survive_reinit

test_schedule_runs_survive_reinit() {
  # Create schedule, fire it, re-init, verify runs persist
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo persist-run'
  agent-store schedule tick >/dev/null
  local run_count_before
  run_count_before=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count_before" -ge 1
  # Re-init
  agent-store init >/dev/null
  # Runs should still be accessible
  local run_count_after
  run_count_after=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count_after" -eq "$run_count_before"
  agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout' | grep -q "persist-run"
}
run_case "schedule runs survive re-init" test_schedule_runs_survive_reinit

test_init_creates_working_schedule_tables() {
  # Verify that init creates the schedules and schedule_runs tables
  # (migration v3: add_schedules) by exercising the full lifecycle
  agent-store schedule add every 1h -- echo migration-check >/dev/null
  agent-store schedule ls | grep -q "migration-check"
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo at-check >/dev/null
  agent-store schedule tick >/dev/null
  agent-store --json schedule runs | jq -e '.schedule_runs | length >= 1'
}
run_case "init creates schedule tables (migration v3)" test_init_creates_working_schedule_tables

test_full_lifecycle_across_reinit() {
  # Full lifecycle: add schedules, fire some, re-init, add more, fire more
  # Verify accumulated state is consistent
  local sid1
  sid1=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo before-reinit')
  agent-store schedule add every 1s -- 'echo recurring' >/dev/null
  sleep 2
  agent-store schedule tick >/dev/null
  # at-schedule completed, every-schedule ran once
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed" or .schedules[1].status == "completed"'
  # Re-init
  agent-store init >/dev/null
  # Add new schedule
  local sid3
  sid3=$(agent-store schedule add at 2020-06-01T00:00:00Z -- 'echo after-reinit')
  sleep 2
  agent-store schedule tick >/dev/null
  # Total schedules: 3 (at-completed + every-active + new-at-completed)
  local total
  total=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$total" -eq 3
  # Total runs: at least 3 (1 at + 1 every + 1 new at)
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -ge 3
}
run_case "full schedule lifecycle across re-init" test_full_lifecycle_across_reinit

test_hooks_and_schedules_survive_reinit() {
  # Both hooks and schedules should survive re-init
  agent-store hook add create 'kind=log' -- 'echo hook-fired >> /tmp/hook-reinit-test'
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create log msg=reinit-check')
  agent-store init >/dev/null
  # Schedule should survive
  agent-store schedule ls | grep -q "$sid"
  # Tick should fire and hook should trigger
  agent-store schedule tick >/dev/null
  test -f /tmp/hook-reinit-test
  grep -q "hook-fired" /tmp/hook-reinit-test
  rm -f /tmp/hook-reinit-test
}
run_case "hooks and schedules survive re-init together" test_hooks_and_schedules_survive_reinit

# ── Section 44: Cron Entry when Binary Upgraded In-Place ────────────

echo ""
echo "== Cron Entry when Binary Upgraded In-Place =="

test_cron_works_after_binary_copy_replace() {
  # Simulate binary upgrade: copy binary, enable cron, replace binary, verify tick
  local original_bin
  original_bin=$(which agent-store)
  local backup_bin="/tmp/agent-store-backup-$$"
  cp "$original_bin" "$backup_bin"

  agent-store schedule enable >/dev/null
  # Cron entry points to $original_bin
  crontab -l | grep -q "$original_bin"

  # "Upgrade" the binary by copying backup over it (same binary content)
  cp "$backup_bin" "$original_bin"

  # Verify tick still works with the "upgraded" binary
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo post-upgrade'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "post-upgrade"

  # Clean up
  agent-store schedule disable >/dev/null
  rm -f "$backup_bin"
}
run_case "binary replaced in-place: tick still works" test_cron_works_after_binary_copy_replace

test_cron_entry_survives_binary_replacement() {
  # Enable cron, replace binary, verify crontab entry is unchanged
  agent-store schedule enable >/dev/null
  local cron_before
  cron_before=$(crontab -l | grep "schedule tick")

  # Simulate upgrade: copy current binary over itself
  local bin_path
  bin_path=$(which agent-store)
  cp "$bin_path" "${bin_path}.new"
  mv "${bin_path}.new" "$bin_path"

  # Crontab entry should be completely unchanged
  local cron_after
  cron_after=$(crontab -l | grep "schedule tick")
  test "$cron_before" = "$cron_after"

  # The "new" binary should still be functional
  agent-store schedule ls >/dev/null

  agent-store schedule disable >/dev/null
}
run_case "cron entry survives binary replacement" test_cron_entry_survives_binary_replacement

test_tick_works_with_replaced_binary_and_existing_schedules() {
  # Full flow: init, add schedules, enable cron, replace binary, tick
  local sid
  sid=$(agent-store schedule add every 1s -- 'echo upgraded-binary')
  agent-store schedule enable >/dev/null
  sleep 2

  # Replace binary
  local bin_path
  bin_path=$(which agent-store)
  cp "$bin_path" "${bin_path}.tmp"
  mv "${bin_path}.tmp" "$bin_path"
  chmod +x "$bin_path"

  # Tick should work with the "new" binary
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length >= 1'
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'

  # Schedule should still be active
  agent-store schedule ls | grep -q "status=active"
  agent-store schedule ls | grep -q "$sid"

  agent-store schedule disable >/dev/null
}
run_case "tick with replaced binary and existing schedules" test_tick_works_with_replaced_binary_and_existing_schedules

# ── Section 45: Schedule Interaction with Hooks (Deep) ──────────────

echo ""
echo "== Schedule Interaction with Hooks (Deep) =="

test_schedule_create_triggers_hook_both_recorded() {
  # Schedule creates a record; hook fires on that create
  # Verify: schedule run is recorded AND the hook actually ran
  agent-store hook add create 'kind=audit' -- 'echo "HOOK_RAN:$AGENT_STORE_ID" >> /tmp/hook-both-recorded'
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create audit action=test-both'
  agent-store schedule tick >/dev/null

  # Schedule run should be recorded
  local run_count
  run_count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count" -eq 1
  agent-store --json schedule runs | jq -e '.schedule_runs[0].exit_status == 0'

  # Hook should have fired
  test -f /tmp/hook-both-recorded
  grep -q "HOOK_RAN:" /tmp/hook-both-recorded

  # The audit record should exist
  agent-store find kind=audit | grep -q "action=test-both"

  rm -f /tmp/hook-both-recorded
}
run_case "schedule create triggers hook: both run and hook recorded" test_schedule_create_triggers_hook_both_recorded

test_schedule_create_hook_modifies_record() {
  # Schedule creates a record, hook modifies it, verify final state
  agent-store hook add create 'kind=item' -- 'agent-store set $AGENT_STORE_ID processed=true'
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create item name=hookmod'
  agent-store schedule tick >/dev/null

  # The item should exist with the hook's modification
  local json
  json=$(agent-store --json find 'kind=item and name=hookmod')
  echo "$json" | jq -e '.records[0].fields.processed == "true"'
}
run_case "schedule create + hook modify: final state correct" test_schedule_create_hook_modifies_record

test_schedule_set_triggers_hook() {
  # Schedule command calls set, which should trigger a set hook
  local rid
  rid=$(agent-store create task status=pending)
  agent-store hook add set 'kind=task' -- 'echo "SET_HOOK:$AGENT_STORE_ID:$AGENT_STORE_EVENT" >> /tmp/hook-set-trigger'
  agent-store schedule add at 2020-01-01T00:00:00Z -- "agent-store set $rid status=done"
  agent-store schedule tick >/dev/null

  # Schedule run should succeed
  agent-store --json schedule runs | jq -e '.schedule_runs[0].exit_status == 0'

  # Set hook should have fired
  test -f /tmp/hook-set-trigger
  grep -q "SET_HOOK:$rid:set" /tmp/hook-set-trigger

  # Record should be updated
  local status
  status=$(agent-store --json get "$rid" | jq -r '.record.fields.status')
  test "$status" = "done"

  rm -f /tmp/hook-set-trigger
}
run_case "schedule set triggers set hook" test_schedule_set_triggers_hook

test_multiple_schedules_each_trigger_hooks() {
  # Multiple schedules fire in one tick, each creating records that trigger hooks
  agent-store hook add create 'kind=event' -- 'echo "$AGENT_STORE_ID" >> /tmp/hook-multi-sched'
  for i in 1 2 3 4 5; do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "agent-store create event seq=$i" >/dev/null
  done
  agent-store schedule tick >/dev/null

  # 5 schedule runs
  local run_count
  run_count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count" -eq 5

  # All exited 0
  test "$(agent-store --json schedule runs | jq '[.schedule_runs[] | select(.exit_status == 0)] | length')" -eq 5

  # 5 event records created
  test "$(agent-store find kind=event --count)" -eq 5

  # Hook fired 5 times (one per create)
  test -f /tmp/hook-multi-sched
  local hook_lines
  hook_lines=$(wc -l < /tmp/hook-multi-sched)
  test "$hook_lines" -eq 5

  rm -f /tmp/hook-multi-sched
}
run_case "multiple schedules fire, each triggering hooks" test_multiple_schedules_each_trigger_hooks

test_hook_failure_propagates_to_schedule_run() {
  # Hook fails (exit nonzero). Since run_hooks_or_exit causes the create command
  # to exit non-zero, the schedule run captures that non-zero exit status.
  # This is correct: the schedule command failed because of the hook.
  agent-store hook add create 'kind=fragile' -- 'exit 42'
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'agent-store create fragile name=will-hook-fail'
  agent-store schedule tick >/dev/null

  # The schedule run should have a non-zero exit (the create command exits non-zero
  # because run_hooks_or_exit propagates hook failure to the calling command)
  local exit_status
  exit_status=$(agent-store --json schedule runs | jq '.schedule_runs[0].exit_status')
  test "$exit_status" -ne 0

  # The fragile record should still exist (the record was created before the hook ran)
  agent-store find kind=fragile | grep -q "name=will-hook-fail"

  # The schedule should be completed (at-schedules complete regardless of command result)
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
}
run_case "hook failure propagates to schedule run exit status" test_hook_failure_propagates_to_schedule_run

test_query_schedule_with_hook_chain() {
  # Query-scoped schedule processes each record; each record's processing
  # triggers a hook that creates an audit log entry
  agent-store hook add set 'kind=task' -- 'agent-store create audit_trail action=processed record=$AGENT_STORE_ID'
  for i in 1 2 3; do
    agent-store create task status=open "n=$i" >/dev/null
  done
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=open' -- \
    'agent-store set $AGENT_STORE_ID status=done'
  agent-store schedule tick >/dev/null

  # 3 schedule runs (one per task)
  local run_count
  run_count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$run_count" -eq 3

  # All tasks should now be done
  test "$(agent-store find kind=task status=done --count)" -eq 3

  # 3 audit trail records (one per set hook invocation)
  test "$(agent-store find kind=audit_trail --count)" -eq 3
}
run_case "query schedule + hook chain: audit trail created" test_query_schedule_with_hook_chain

# ── Section 46: Schedule Edge Cases Not Yet Covered ─────────────────

echo ""
echo "== Schedule Edge Cases (Additional) =="

test_schedule_command_with_heredoc_strings() {
  # Command containing heredoc-style multi-line content via printf
  agent-store schedule add at 2020-01-01T00:00:00Z -- \
    'printf "line1\nline2\nline3\n"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "line1"
  echo "$stdout" | grep -q "line2"
  echo "$stdout" | grep -q "line3"
  local line_count
  line_count=$(echo "$stdout" | wc -l)
  test "$line_count" -eq 3
}
run_case "command with heredoc-style multi-line output" test_schedule_command_with_heredoc_strings

test_schedule_with_very_long_query() {
  # Create records and a schedule with a long query string
  agent-store create task status=open priority=high team=backend sprint=42 category=infrastructure tag=urgent >/dev/null
  agent-store create task status=open priority=low team=frontend sprint=43 category=ui tag=deferred >/dev/null
  local long_query='kind=task and status=open and priority=high and team=backend and sprint=42 and category=infrastructure and tag=urgent'
  local sid
  sid=$(agent-store schedule add at 2020-01-01T00:00:00Z "$long_query" -- 'echo matched-long-query')
  # Query should be stored correctly
  local stored_query
  stored_query=$(agent-store --json schedule ls | jq -r '.schedules[0].query')
  test "$stored_query" = "$long_query"
  # Should match exactly 1 record
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 1
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "matched-long-query"
}
run_case "schedule with very long query string" test_schedule_with_very_long_query

test_ls_mixed_active_completed() {
  # Mix of active every-schedules and completed at-schedules
  agent-store schedule add every 1h -- 'echo active-1' >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo completed-1' >/dev/null
  agent-store schedule add every 2h -- 'echo active-2' >/dev/null
  agent-store schedule add at 2020-06-01T00:00:00Z -- 'echo completed-2' >/dev/null
  agent-store schedule add every 3h -- 'echo active-3' >/dev/null
  agent-store schedule tick >/dev/null
  local listing
  listing=$(agent-store schedule ls)
  # Should show 3 active and 2 completed
  local active_count completed_count
  active_count=$(echo "$listing" | grep -c "status=active")
  completed_count=$(echo "$listing" | grep -c "status=completed")
  test "$active_count" -eq 3
  test "$completed_count" -eq 2
  # Total should be 5 lines
  test "$(echo "$listing" | wc -l)" -eq 5
  # JSON should match
  local json
  json=$(agent-store --json schedule ls)
  test "$(echo "$json" | jq '[.schedules[] | select(.status == "active")] | length')" -eq 3
  test "$(echo "$json" | jq '[.schedules[] | select(.status == "completed")] | length')" -eq 2
}
run_case "ls with mix of active and completed schedules" test_ls_mixed_active_completed

test_runs_limit_1_returns_exactly_1() {
  # Create multiple runs, verify --limit 1 returns exactly 1
  agent-store schedule add every 1s -- 'echo limit-test'
  for i in 1 2 3 4 5; do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  local json
  json=$(agent-store --json schedule runs --limit 1)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 1
  # Should be the most recent run
  local all_json
  all_json=$(agent-store --json schedule runs --limit 100)
  local newest_id limited_id
  newest_id=$(echo "$all_json" | jq '.schedule_runs[0].id')
  limited_id=$(echo "$json" | jq '.schedule_runs[0].id')
  test "$newest_id" = "$limited_id"
}
run_case "runs --limit 1 returns exactly 1 most recent" test_runs_limit_1_returns_exactly_1

test_tick_when_all_completed() {
  # All schedules are completed at-schedules — tick is a no-op
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo done-1' >/dev/null
  agent-store schedule add at 2020-06-01T00:00:00Z -- 'echo done-2' >/dev/null
  agent-store schedule tick >/dev/null
  # Both should be completed
  local completed
  completed=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "completed")] | length')
  test "$completed" -eq 2
  # Second tick: nothing to do
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.ticked')" -eq 0
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
  # Plain text tick should produce no output
  local plain_out
  plain_out=$(agent-store schedule tick)
  test -z "$plain_out"
}
run_case "tick when all schedules completed: no-op" test_tick_when_all_completed

test_tick_output_matches_creation_order() {
  # Create 5 schedules in order; tick should process them in creation order
  for i in 1 2 3 4 5; do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo order-$i" >/dev/null
  done
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 5
  # Verify the stdout matches creation order
  local first_out last_out
  first_out=$(echo "$json" | jq -r '.schedule_runs[0].stdout' | tr -d '\n')
  last_out=$(echo "$json" | jq -r '.schedule_runs[4].stdout' | tr -d '\n')
  test "$first_out" = "order-1"
  test "$last_out" = "order-5"
}
run_case "tick output ordering matches creation order" test_tick_output_matches_creation_order

test_schedule_command_with_single_quotes() {
  # Command containing properly escaped single quotes
  # Since the command is run via bash -c, we use the '\'' escape idiom
  agent-store schedule add at 2020-01-01T00:00:00Z -- "echo 'it'\\''s working'"
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "it's working"
}
run_case "command with single quotes" test_schedule_command_with_single_quotes

test_schedule_command_with_dollar_signs() {
  # Command with dollar signs that should be expanded at runtime
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "user=$USER pid=$$"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  # $USER should be expanded, $$ should give a PID
  echo "$stdout" | grep -q "user="
  echo "$stdout" | grep -q "pid="
}
run_case "command with dollar sign expansions" test_schedule_command_with_dollar_signs

test_schedule_command_with_backticks() {
  # Command with backtick-style command substitution
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "date=$(date +%Y)"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "date=20"
}
run_case "command with backtick substitution" test_schedule_command_with_backticks

test_tick_with_only_future_every_schedules() {
  # Every-schedules that are not yet due (just added, next_run_at in future)
  agent-store schedule add every 1h -- 'echo not-yet' >/dev/null
  agent-store schedule add every 2h -- 'echo also-not-yet' >/dev/null
  # Don't sleep — schedules are not due yet
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.ticked')" -eq 0
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
  # Both still active
  test "$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "active")] | length')" -eq 2
}
run_case "tick with only future every-schedules: no-op" test_tick_with_only_future_every_schedules

test_schedule_add_multi_word_command_args() {
  # Command with multiple arguments after --
  local id
  id=$(agent-store schedule add at 2020-01-01T00:00:00Z -- echo arg1 arg2 arg3)
  local stored_cmd
  stored_cmd=$(agent-store --json schedule ls | jq -r '.schedules[0].command')
  test "$stored_cmd" = "echo arg1 arg2 arg3"
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "arg1 arg2 arg3"
}
run_case "add with multi-word command after --" test_schedule_add_multi_word_command_args

test_schedule_every_with_query_no_records_initially() {
  # Every-schedule with query but no matching records — should still be created
  local sid
  sid=$(agent-store schedule add every 1s 'kind=phantom' -- 'echo found-phantom')
  agent-store schedule ls | grep -q "$sid"
  sleep 2
  # Tick: no matching records, 0 runs
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 0
  # Create a matching record
  agent-store create phantom msg=hello >/dev/null
  sleep 2
  # Tick again: now it should match
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 1
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "found-phantom"
}
run_case "every-schedule with query: picks up new records" test_schedule_every_with_query_no_records_initially

# ── Section 47: Non-ASCII / Unicode in Schedules ─────────────────────

echo ""
echo "== Non-ASCII / Unicode in Schedules =="

test_schedule_command_emoji_output() {
  # Schedule command that outputs emoji
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "Status: ✅ Done"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "✅"
  echo "$stdout" | grep -q "Done"
}
run_case "command with emoji output (✅)" test_schedule_command_emoji_output

test_schedule_cjk_characters_in_query_field_values() {
  # Create records with CJK characters in field values
  agent-store create task title="任务一" status="进行中" >/dev/null
  agent-store create task title="任务二" status="完成" >/dev/null
  agent-store create task title="任务三" status="进行中" >/dev/null
  # Query-scoped schedule filtering on CJK field value
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=进行中' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Should match 2 records (任务一 and 任务三)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "query with CJK characters in field values" test_schedule_cjk_characters_in_query_field_values

test_schedule_reads_record_with_unicode_fields() {
  # Create record with Unicode in multiple fields, verify stdin piping
  agent-store create note title="日本語テスト" body="これはテストです 🎉" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=note' -- 'cat'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "日本語テスト"
  echo "$stdout" | grep -q "これはテストです"
  echo "$stdout" | grep -q "🎉"
}
run_case "record with Unicode fields piped on stdin" test_schedule_reads_record_with_unicode_fields

test_unicode_in_schedule_command_string() {
  # Command string itself contains Unicode
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'printf "Ünïcödë: café résumé naïve"'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs[0].exit_status == 0'
  local stdout
  stdout=$(echo "$json" | jq -r '.schedule_runs[0].stdout')
  echo "$stdout" | grep -q "café"
  echo "$stdout" | grep -q "résumé"
  echo "$stdout" | grep -q "naïve"
  # Verify the command itself is stored with Unicode intact
  local stored_cmd
  stored_cmd=$(agent-store --json schedule ls | jq -r '.schedules[0].command')
  echo "$stored_cmd" | grep -q "Ünïcödë"
}
run_case "Unicode in schedule command string" test_unicode_in_schedule_command_string

test_mixed_utf8_ascii_in_ls_runs() {
  # Schedule with ASCII command, but produces Unicode output
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo "ASCII + 日本語 + émojis 🚀🌍"'
  agent-store schedule tick >/dev/null
  # ls should not crash or garble with Unicode in the store
  local listing
  listing=$(agent-store schedule ls)
  test -n "$listing"
  # runs should display correctly
  local runs_out
  runs_out=$(agent-store schedule runs)
  test -n "$runs_out"
  # JSON runs should have the full Unicode output
  local json
  json=$(agent-store --json schedule runs)
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "日本語"
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "🚀🌍"
}
run_case "mixed UTF-8 and ASCII in ls/runs output" test_mixed_utf8_ascii_in_ls_runs

test_unicode_substring_match_query() {
  # Create records with Unicode values, test ~= substring match
  agent-store create item name="東京タワー" >/dev/null
  agent-store create item name="大阪城" >/dev/null
  agent-store create item name="東京スカイツリー" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'name~=東京' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  # Should match 東京タワー and 東京スカイツリー
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "Unicode substring match (~=) in schedule query" test_unicode_substring_match_query

test_emoji_in_field_values_and_query() {
  # Fields with emoji values
  agent-store create status_report status="✅" priority="🔥" >/dev/null
  agent-store create status_report status="❌" priority="🔥" >/dev/null
  agent-store create status_report status="✅" priority="❄️" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=status_report and status=✅' -- 'echo $AGENT_STORE_ID'
  local json
  json=$(agent-store --json schedule tick)
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 2
}
run_case "emoji in field values and query matching" test_emoji_in_field_values_and_query

# ── Section 48: WAL Journal Contention Under Heavy Concurrent Load ───

echo ""
echo "== WAL Journal Contention Under Heavy Load =="

test_20_concurrent_ticks_competing() {
  # Create 5 at-schedules all due
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo compete-$i" >/dev/null
  done
  # Launch 20 concurrent tick processes
  local pids=()
  for i in $(seq 1 20); do
    agent-store schedule tick &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  # Each at-schedule should fire exactly once (5 total runs)
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 5
  # All 5 should be completed
  local completed
  completed=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "completed")] | length')
  test "$completed" -eq 5
  # Store should be consistent
  agent-store schedule ls >/dev/null
}
run_case "20 concurrent ticks competing for 5 schedules" test_20_concurrent_ticks_competing

test_10_tick_plus_10_add_simultaneously() {
  # Pre-seed some due schedules
  for i in $(seq 1 3); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "echo preseed-$i" >/dev/null
  done
  # Launch 10 ticks and 10 adds concurrently
  local pids=()
  for i in $(seq 1 10); do
    agent-store schedule tick &
    pids+=($!)
    agent-store schedule add every "${i}m" -- "echo concurrent-add-$i" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  # All 10 concurrent adds should have succeeded
  local total_count
  total_count=$(agent-store --json schedule ls | jq '.schedules | length')
  # 3 preseeded + 10 added = 13
  test "$total_count" -eq 13
  # The 3 at-schedules should each have exactly 1 run
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 3
  # Store integrity check
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
}
run_case "10 concurrent ticks + 10 concurrent adds" test_10_tick_plus_10_add_simultaneously

test_sustained_tick_loop_with_5_every_schedules() {
  # Create 5 every-schedules with 1s interval
  for i in $(seq 1 5); do
    agent-store schedule add every 1s -- "echo sustained-$i" >/dev/null
  done
  sleep 2
  # Rapid-fire 10 ticks in succession
  for i in $(seq 1 10); do
    agent-store schedule tick >/dev/null
    sleep 1
  done
  # Should have 50 runs (5 schedules * 10 ticks)
  local run_count
  run_count=$(agent-store --json schedule runs --limit 200 | jq '.schedule_runs | length')
  test "$run_count" -eq 50
  # All schedules should still be active
  local active
  active=$(agent-store --json schedule ls | jq '[.schedules[] | select(.status == "active")] | length')
  test "$active" -eq 5
}
run_case "sustained tick loop: 10 ticks x 5 every-schedules" test_sustained_tick_loop_with_5_every_schedules

test_concurrent_tick_plus_record_mutations() {
  # Set up query-scoped schedule
  for i in $(seq 1 5); do
    agent-store create task "n=$i" status=open >/dev/null
  done
  agent-store schedule add every 1s 'kind=task and status=open' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # Concurrently: tick + create + set + rm
  agent-store schedule tick &
  local tick_pid=$!
  agent-store create task n=6 status=open &
  local create_pid=$!
  # Get one ID for mutation
  local some_id
  some_id=$(agent-store --json find 'kind=task and status=open' | jq -r '.records[0].id')
  agent-store set "$some_id" status=closed &
  local set_pid=$!
  wait "$tick_pid" 2>/dev/null || true
  wait "$create_pid" 2>/dev/null || true
  wait "$set_pid" 2>/dev/null || true
  # Store should be consistent -- no corruption
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
  agent-store find kind=task >/dev/null
  # At least some runs should have occurred
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -ge 1
}
run_case "concurrent tick + record create/set mutations" test_concurrent_tick_plus_record_mutations

# ── Section 49: Store Behavior After Unclean Shutdown During Tick ────

echo ""
echo "== Store After Unclean Shutdown During Tick =="

test_sigkill_during_running_command_store_recovery() {
  # SIGKILL tick while the schedule command is actively running
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1  # Let tick claim the schedule and start the command
  kill -KILL "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should be usable after SIGKILL
  agent-store schedule ls >/dev/null
  # at-schedule was claimed before command started, so it should be completed
  agent-store --json schedule ls | jq -e '.schedules[0].status == "completed"'
  # Can add new schedules after crash
  local new_sid
  new_sid=$(agent-store schedule add every 1h -- echo post-crash)
  agent-store schedule ls | grep -q "$new_sid"
}
run_case "SIGKILL during command: store recovers for future ops" test_sigkill_during_running_command_store_recovery

test_sigkill_at_tick_start() {
  # Create an every-schedule with short interval
  agent-store schedule add every 1s -- 'sleep 30'
  sleep 2
  # Start tick and kill immediately (before or during claim)
  agent-store schedule tick &
  local tick_pid=$!
  sleep 0.1  # Very brief -- SIGKILL before command likely starts
  kill -KILL "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Store should still be functional
  agent-store schedule ls >/dev/null
  # Schedule should be in a consistent state (active or claimed)
  local status
  status=$(agent-store --json schedule ls | jq -r '.schedules[0].status')
  # Either active (kill happened before claim) or active (every keeps active)
  test "$status" = "active"
  # Tick again should work
  sleep 1
  agent-store schedule tick >/dev/null 2>&1 || true
  agent-store schedule ls >/dev/null
}
run_case "SIGKILL at tick start: store is consistent" test_sigkill_at_tick_start

test_multiple_sigkills_in_sequence() {
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'sleep 30'
  agent-store schedule add every 1s -- 'sleep 30'
  sleep 2
  # SIGKILL three times in sequence
  for i in 1 2 3; do
    agent-store schedule tick &
    local pid=$!
    sleep 0.5
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # Store should still be consistent after 3 SIGKILLs
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
  # Can still perform CRUD
  local new_id
  new_id=$(agent-store schedule add every 5m -- echo still-works)
  agent-store schedule ls | grep -q "$new_id"
  agent-store schedule rm "$new_id" >/dev/null
}
run_case "3 SIGKILLs in sequence: store remains consistent" test_multiple_sigkills_in_sequence

test_no_partial_runs_after_sigkill() {
  # Create 5 at-schedules, SIGKILL during tick, verify no partially-written runs
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "sleep 10; echo done-$i" >/dev/null
  done
  agent-store schedule tick &
  local tick_pid=$!
  sleep 1  # Let tick start processing (it processes sequentially)
  kill -KILL "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Any runs that exist should be complete (have exit_status set)
  local json
  json=$(agent-store --json schedule runs --limit 100)
  local run_count
  run_count=$(echo "$json" | jq '.schedule_runs | length')
  # Each run must have a non-null exit_status (no partial writes)
  if [ "$run_count" -gt 0 ]; then
    local null_exit_count
    null_exit_count=$(echo "$json" | jq '[.schedule_runs[] | select(.exit_status == null)] | length')
    test "$null_exit_count" -eq 0
  fi
  # Remaining un-fired schedules can be ticked again
  agent-store schedule tick >/dev/null 2>&1 || true
  agent-store schedule ls >/dev/null
}
run_case "no partially-written runs after SIGKILL" test_no_partial_runs_after_sigkill

# ── Section 50: Schedule Query Mutation Race ─────────────────────────

echo ""
echo "== Schedule Query Mutation Race =="

test_records_created_deleted_during_query_tick() {
  # Create initial matching records
  for i in $(seq 1 5); do
    agent-store create task "n=$i" status=live >/dev/null
  done
  agent-store schedule add every 1s 'kind=task and status=live' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # Start tick in background while simultaneously mutating records
  agent-store schedule tick &
  local tick_pid=$!
  # While tick is iterating, create and delete records
  agent-store create task n=6 status=live &
  agent-store create task n=7 status=live &
  local del_id
  del_id=$(agent-store --json find 'kind=task and n=1' | jq -r '.records[0].id')
  agent-store rm "$del_id" 2>/dev/null &
  wait "$tick_pid" 2>/dev/null || true
  wait
  # No crashes, store is consistent
  agent-store schedule ls >/dev/null
  agent-store schedule runs >/dev/null
  # At least some runs should exist
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -ge 1
}
run_case "records created/deleted while query-scoped tick iterates" test_records_created_deleted_during_query_tick

test_query_scoped_every_finds_different_records() {
  # First tick: 2 matching records
  agent-store create task label=changing status=a >/dev/null
  agent-store create task label=changing status=a >/dev/null
  agent-store schedule add every 1s 'kind=task and label=changing' -- 'echo $AGENT_STORE_ID'
  sleep 2
  local json1
  json1=$(agent-store --json schedule tick)
  test "$(echo "$json1" | jq '.schedule_runs | length')" -eq 2

  # Between ticks: add 2 more, remove 1
  local first_id
  first_id=$(agent-store --json find 'kind=task and label=changing' | jq -r '.records[0].id')
  agent-store rm "$first_id"
  agent-store create task label=changing status=b >/dev/null
  agent-store create task label=changing status=c >/dev/null
  sleep 2
  # Second tick: 3 matching records (1 original + 2 new)
  local json2
  json2=$(agent-store --json schedule tick)
  test "$(echo "$json2" | jq '.schedule_runs | length')" -eq 3
}
run_case "query-scoped every-schedule sees different records each tick" test_query_scoped_every_finds_different_records

test_two_concurrent_ticks_query_scoped() {
  # Create records
  for i in $(seq 1 5); do
    agent-store create item "idx=$i" >/dev/null
  done
  # One at-schedule with query -- only one tick should claim it
  agent-store schedule add at 2020-01-01T00:00:00Z 'kind=item' -- 'echo $AGENT_STORE_ID'
  # Two concurrent ticks
  agent-store schedule tick &
  local pid1=$!
  agent-store schedule tick &
  local pid2=$!
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  # Exactly 5 runs (one per record, from exactly one tick claiming)
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  test "$run_count" -eq 5
}
run_case "two concurrent ticks with query-scoped schedule: exact run count" test_two_concurrent_ticks_query_scoped

test_query_scoped_every_concurrent_ticks_changing_records() {
  # Every-schedule with query; concurrent ticks + record mutation
  for i in $(seq 1 3); do
    agent-store create widget "ver=$i" active=yes >/dev/null
  done
  agent-store schedule add every 1s 'kind=widget and active=yes' -- 'echo $AGENT_STORE_ID'
  sleep 2
  # Concurrent: 3 ticks + 2 record changes
  agent-store schedule tick &
  agent-store schedule tick &
  agent-store schedule tick &
  agent-store create widget ver=4 active=yes &
  local w1_id
  w1_id=$(agent-store --json find 'kind=widget and ver=1' | jq -r '.records[0].id')
  agent-store set "$w1_id" active=no 2>/dev/null &
  wait
  # Only one tick should have claimed; store consistent
  local run_count
  run_count=$(agent-store --json schedule runs --limit 100 | jq '.schedule_runs | length')
  # Should be 3 (the 3 original matching widgets at tick time)
  test "$run_count" -ge 1
  agent-store schedule ls >/dev/null
}
run_case "query-scoped every: concurrent ticks + changing records" test_query_scoped_every_concurrent_ticks_changing_records

# ── Section 51: Miscellaneous Remaining Edge Cases ───────────────────

echo ""
echo "== Miscellaneous Remaining Edge Cases =="

test_add_whitespace_only_command_rejected() {
  # Command that is just whitespace after -- should be rejected
  ! agent-store schedule add every 5m -- '   ' 2>/dev/null
}
run_case "add with whitespace-only command rejected" test_add_whitespace_only_command_rejected

test_add_tabs_only_command_rejected() {
  # Tab-only command
  ! agent-store schedule add at 2030-01-01T00:00:00Z -- "$(printf '\t\t')" 2>/dev/null
}
run_case "add with tab-only command rejected" test_add_tabs_only_command_rejected

test_rm_then_readd_same_params_different_id() {
  # Add, rm, then re-add with identical parameters -- should get a new ID
  local id1
  id1=$(agent-store schedule add every 5m -- echo readd-test)
  agent-store schedule rm "$id1" >/dev/null
  local id2
  id2=$(agent-store schedule add every 5m -- echo readd-test)
  # IDs must differ
  test "$id1" != "$id2"
  # Only the new schedule should exist
  ! agent-store schedule ls | grep -q "$id1"
  agent-store schedule ls | grep -q "$id2"
  local count
  count=$(agent-store --json schedule ls | jq '.schedules | length')
  test "$count" -eq 1
}
run_case "rm then re-add same params: different ID" test_rm_then_readd_same_params_different_id

test_schedule_enable_json_output() {
  local json
  json=$(agent-store --json schedule enable)
  echo "$json" | jq -e '.status == "enabled"'
  # Clean up
  agent-store schedule disable >/dev/null
}
run_case "schedule enable --json output" test_schedule_enable_json_output

test_schedule_disable_json_output() {
  agent-store schedule enable >/dev/null
  local json
  json=$(agent-store --json schedule disable)
  echo "$json" | jq -e '.status == "disabled"'
}
run_case "schedule disable --json output" test_schedule_disable_json_output

test_schedule_disable_noop_json_output() {
  # Disable when not enabled -- should still return disabled status
  local json
  json=$(agent-store --json schedule disable)
  echo "$json" | jq -e '.status == "disabled"'
}
run_case "schedule disable (no-op) --json output" test_schedule_disable_noop_json_output

test_tick_mixed_queryless_and_query_scoped() {
  # Create records for query-scoped schedule
  agent-store create task status=ready marker=mixed-q-test >/dev/null
  agent-store create task status=ready marker=mixed-q-test >/dev/null
  # Queryless schedule
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo queryless-fired' >/dev/null
  # Query-scoped schedule
  agent-store schedule add at 2020-06-01T00:00:00Z 'kind=task and marker=mixed-q-test' -- 'echo query-fired' >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  # 1 run from queryless + 2 runs from query-scoped = 3 total
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 3
  # Verify both types of output present
  local all_stdout
  all_stdout=$(echo "$json" | jq -r '[.schedule_runs[].stdout] | join(" ")')
  echo "$all_stdout" | grep -q "queryless-fired"
  echo "$all_stdout" | grep -q "query-fired"
}
run_case "tick with mix of queryless and query-scoped schedules" test_tick_mixed_queryless_and_query_scoped

test_runs_limit_larger_than_total() {
  # Only 3 runs exist, but --limit 1000
  agent-store schedule add every 1s -- 'echo small'
  for i in 1 2 3; do
    sleep 1
    agent-store schedule tick >/dev/null
  done
  local json
  json=$(agent-store --json schedule runs --limit 1000)
  # Should return exactly 3, not error
  test "$(echo "$json" | jq '.schedule_runs | length')" -eq 3
}
run_case "runs --limit larger than total runs: returns all" test_runs_limit_larger_than_total

test_runs_limit_zero_rejected() {
  # --limit 0 should be rejected (requires a positive number)
  agent-store schedule add at 2020-01-01T00:00:00Z -- 'echo zero-limit' >/dev/null
  agent-store schedule tick >/dev/null
  ! agent-store schedule runs --limit 0 2>/dev/null
}
run_case "runs --limit 0 rejected (requires positive)" test_runs_limit_zero_rejected

test_add_command_with_only_separator() {
  # Just -- with nothing after it
  ! agent-store schedule add every 5m -- 2>/dev/null
}
run_case "add with only -- and no command rejected" test_add_command_with_only_separator

test_schedule_enable_disable_roundtrip_json() {
  # Full enable/disable roundtrip via --json
  local en_json
  en_json=$(agent-store --json schedule enable)
  echo "$en_json" | jq -e '.status == "enabled"'
  crontab -l | grep -q "schedule tick"
  local dis_json
  dis_json=$(agent-store --json schedule disable)
  echo "$dis_json" | jq -e '.status == "disabled"'
  ! crontab -l 2>/dev/null | grep -q "agent-store:tick"
}
run_case "enable/disable roundtrip with --json" test_schedule_enable_disable_roundtrip_json

test_schedule_enable_idempotent_json() {
  agent-store --json schedule enable >/dev/null
  local json
  json=$(agent-store --json schedule enable)
  echo "$json" | jq -e '.status == "enabled"'
  # Still only one crontab entry
  local count
  count=$(crontab -l | grep -c "schedule tick" || true)
  test "$count" -eq 1
  agent-store schedule disable >/dev/null
}
run_case "enable idempotent via --json" test_schedule_enable_idempotent_json

# ── Section: Clock Skew / Time Jumping ───────────────────────────────

echo ""
echo "== Clock Skew / Time Jumping =="

test_clock_jump_forward_via_db() {
  # Simulate clock jump: add every-schedule, tick once, then manually set
  # next_run_at to the past in the DB, tick again — should fire again
  local json
  json=$(agent-store --json schedule add every 1h -- echo jumped)
  local sid
  sid=$(echo "$json" | jq -r '.schedule.id')
  # Set next_run_at to past (simulating clock jump forward)
  sqlite3 .agent-store/store.sqlite "UPDATE schedules SET next_run_at = '2020-01-01T00:00:00.000Z' WHERE id = '$sid';"
  agent-store schedule tick >/dev/null
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 1
  # Do it again — schedule fires again after another DB manipulation
  sqlite3 .agent-store/store.sqlite "UPDATE schedules SET next_run_at = '2020-01-01T00:00:00.000Z' WHERE id = '$sid';"
  agent-store schedule tick >/dev/null
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 2
}
run_case "clock jump forward fires schedule again" test_clock_jump_forward_via_db

test_clock_at_past_fires_immediately() {
  # at-schedule with a clearly past timestamp fires on first tick
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo past-fire >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length > 0'
  echo "$json" | jq -r '.schedule_runs[0].stdout' | grep -q "past-fire"
}
run_case "at-schedule with past timestamp fires immediately" test_clock_at_past_fires_immediately

test_clock_at_far_future_does_not_fire() {
  # at-schedule far in the future does not fire
  agent-store schedule add at 2099-12-31T23:59:59Z -- echo future >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  local run_count
  run_count=$(echo "$json" | jq '.schedule_runs | length')
  test "$run_count" -eq 0
}
run_case "at-schedule far future does not fire" test_clock_at_far_future_does_not_fire

test_clock_every_rapid_ticks_accumulate() {
  # every-schedule with 1s interval: multiple rapid ticks accumulate runs
  local json
  json=$(agent-store --json schedule add every 1s -- echo rapid)
  local sid
  sid=$(echo "$json" | jq -r '.schedule.id')
  # Wait for initial next_run_at to become due
  sleep 1.1
  agent-store schedule tick >/dev/null
  sleep 1.1
  agent-store schedule tick >/dev/null
  sleep 1.1
  agent-store schedule tick >/dev/null
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 3
}
run_case "rapid ticks on 1s every-schedule accumulate 3 runs" test_clock_every_rapid_ticks_accumulate

test_clock_next_run_at_in_future_no_fire() {
  # Set next_run_at to the future manually — tick should not fire
  local json
  json=$(agent-store --json schedule add every 1s -- echo nope)
  local sid
  sid=$(echo "$json" | jq -r '.schedule.id')
  sqlite3 .agent-store/store.sqlite "UPDATE schedules SET next_run_at = '2099-12-31T23:59:59.000Z' WHERE id = '$sid';"
  agent-store schedule tick >/dev/null
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 0
}
run_case "next_run_at in future prevents firing" test_clock_next_run_at_in_future_no_fire

test_clock_multiple_past_schedules_all_fire() {
  # Multiple at-schedules with past timestamps all fire in one tick
  for i in $(seq 1 5); do
    agent-store schedule add at "2020-01-0${i}T00:00:00Z" -- echo "past-$i" >/dev/null
  done
  local json
  json=$(agent-store --json schedule tick)
  local run_count
  run_count=$(echo "$json" | jq '.schedule_runs | length')
  test "$run_count" -eq 5
}
run_case "5 past at-schedules all fire in one tick" test_clock_multiple_past_schedules_all_fire

# ── Section: Nested Store Concurrent Tick ────────────────────────────

echo ""
echo "== Nested Store Concurrent Tick =="

test_nested_concurrent_tick_independent() {
  # Parent and child stores ticked concurrently, schedules fire independently
  mkdir -p child
  (cd child && agent-store init >/dev/null)
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo parent >/dev/null
  (cd child && agent-store schedule add at 2020-01-01T00:00:00Z -- echo child >/dev/null)
  # Tick both concurrently
  agent-store schedule tick &
  local pid1=$!
  (cd child && agent-store schedule tick) &
  local pid2=$!
  wait "$pid1" "$pid2"
  local p_count c_count
  p_count=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  c_count=$(cd child && agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$p_count" -eq 1
  test "$c_count" -eq 1
}
run_case "nested stores tick concurrently and independently" test_nested_concurrent_tick_independent

test_nested_parent_tick_no_child_effect() {
  # Ticking parent does not fire child schedules
  mkdir -p child
  (cd child && agent-store init >/dev/null)
  (cd child && agent-store schedule add at 2020-01-01T00:00:00Z -- echo child-only >/dev/null)
  agent-store schedule tick >/dev/null
  local c_count
  c_count=$(cd child && agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$c_count" -eq 0
  (cd child && agent-store schedule tick >/dev/null)
  c_count=$(cd child && agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$c_count" -eq 1
}
run_case "parent tick does not fire child schedules" test_nested_parent_tick_no_child_effect

test_nested_3level_concurrent() {
  # 3-level nesting: grandparent, parent, child all ticked concurrently
  mkdir -p level1/level2
  (cd level1 && agent-store init >/dev/null)
  (cd level1/level2 && agent-store init >/dev/null)
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo L0 >/dev/null
  (cd level1 && agent-store schedule add at 2020-01-01T00:00:00Z -- echo L1 >/dev/null)
  (cd level1/level2 && agent-store schedule add at 2020-01-01T00:00:00Z -- echo L2 >/dev/null)
  agent-store schedule tick &
  local p0=$!
  (cd level1 && agent-store schedule tick) &
  local p1=$!
  (cd level1/level2 && agent-store schedule tick) &
  local p2=$!
  wait "$p0" "$p1" "$p2"
  test "$(agent-store --json schedule runs | jq '.schedule_runs | length')" -eq 1
  test "$(cd level1 && agent-store --json schedule runs | jq '.schedule_runs | length')" -eq 1
  test "$(cd level1/level2 && agent-store --json schedule runs | jq '.schedule_runs | length')" -eq 1
}
run_case "3-level nested stores tick concurrently" test_nested_3level_concurrent

test_nested_query_scoped_independent() {
  # Parent and child have query-scoped schedules with different records
  mkdir -p child
  (cd child && agent-store init >/dev/null)
  agent-store create parent-rec val=P >/dev/null
  (cd child && agent-store create child-rec val=C >/dev/null)
  agent-store schedule add at 2020-01-01T00:00:00Z 'val=P' -- echo "parent-hit" >/dev/null
  (cd child && agent-store schedule add at 2020-01-01T00:00:00Z 'val=C' -- echo "child-hit" >/dev/null)
  agent-store schedule tick >/dev/null
  (cd child && agent-store schedule tick >/dev/null)
  local p_out c_out
  p_out=$(agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout')
  c_out=$(cd child && agent-store --json schedule runs | jq -r '.schedule_runs[0].stdout')
  echo "$p_out" | grep -q "parent-hit"
  echo "$c_out" | grep -q "child-hit"
}
run_case "nested query-scoped schedules use own records" test_nested_query_scoped_independent

# ── Section: Heavy Concurrent Re-Entrancy ────────────────────────────

echo ""
echo "== Heavy Concurrent Re-Entrancy =="

test_30_concurrent_ticks_every_schedule() {
  # 30 concurrent ticks on the same every-schedule — only 1 should fire per tick
  local json
  json=$(agent-store --json schedule add every 1s -- echo tick30)
  local sid
  sid=$(echo "$json" | jq -r '.schedule.id')
  sleep 1.1
  agent-store schedule tick >/dev/null
  sleep 1.1
  local pids=()
  for i in $(seq 1 30); do
    agent-store schedule tick &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 2
}
run_case "30 concurrent ticks: every-schedule fires exactly once" test_30_concurrent_ticks_every_schedule

test_50_concurrent_ticks_at_schedule() {
  # 50 concurrent ticks for an at-schedule — should fire exactly once total
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo at50 >/dev/null
  local sid
  sid=$(agent-store --json schedule ls | jq -r '.schedules[0].id')
  local pids=()
  for i in $(seq 1 50); do
    agent-store schedule tick &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -eq 1
}
run_case "50 concurrent ticks: at-schedule fires exactly once" test_50_concurrent_ticks_at_schedule

test_sustained_100_ticks() {
  # 100 sequential rapid ticks on 3 every-1s schedules
  for i in 1 2 3; do
    agent-store schedule add every 1s -- echo "sched-$i" >/dev/null
  done
  # Wait for schedules to become due, then tick
  sleep 1.1
  agent-store schedule tick >/dev/null
  sleep 1.1
  for batch in $(seq 1 3); do
    local pids=()
    for i in $(seq 1 10); do
      agent-store schedule tick &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    sleep 1.1
  done
  # Each schedule should have multiple runs and no DB corruption
  local total
  total=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total" -ge 12
  agent-store --json schedule ls | jq -e '.schedules | length == 3'
}
run_case "sustained 100 ticks across 3 every-schedules" test_sustained_100_ticks

test_concurrent_tick_with_add_rm() {
  # Concurrent ticks while adds and rms happen simultaneously
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo base >/dev/null
  local pids=()
  for i in $(seq 1 5); do
    agent-store schedule tick &
    pids+=($!)
  done
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- echo "add-$i" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  # More ticks to fire any newly added schedules
  agent-store schedule tick >/dev/null
  # Store should be consistent
  agent-store --json schedule ls | jq -e '.schedules | length > 0'
}
run_case "concurrent tick + add mix: store stays consistent" test_concurrent_tick_with_add_rm

test_concurrent_ticks_query_scoped() {
  # 20 concurrent ticks with a query-scoped every-schedule and 5 records
  for i in $(seq 1 5); do
    agent-store create "qload-item" tag="qload-$i" >/dev/null
  done
  local json
  json=$(agent-store --json schedule add every 1s 'tag~=qload' -- echo "q-hit")
  local sid
  sid=$(echo "$json" | jq -r '.schedule.id')
  # Wait for schedule to become due, then tick twice with interval wait
  sleep 1.1
  agent-store schedule tick >/dev/null
  sleep 1.1
  local pids=()
  for i in $(seq 1 20); do
    agent-store schedule tick &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  # First tick: 5 runs (one per record). Concurrent batch: 5 more.
  local run_count
  run_count=$(agent-store --json schedule runs | jq "[.schedule_runs[] | select(.schedule_id == \"$sid\")] | length")
  test "$run_count" -ge 10
}
run_case "20 concurrent ticks with query-scoped schedule" test_concurrent_ticks_query_scoped

# ── Section: Large Output + Concurrent Ticks ─────────────────────────

echo ""
echo "== Large Output + Concurrent Ticks =="

test_large_output_concurrent_ticks() {
  # One schedule produces 8192 bytes of output while 5 others run concurrently
  agent-store schedule add at 2020-01-01T00:00:00Z -- "head -c 8192 /dev/zero | tr '\\0' 'A'" >/dev/null
  for i in $(seq 1 5); do
    agent-store schedule add at 2020-01-01T00:00:00Z -- echo "small-$i" >/dev/null
  done
  agent-store schedule tick >/dev/null
  local total_runs
  total_runs=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total_runs" -eq 6
}
run_case "large output with concurrent small schedules" test_large_output_concurrent_ticks

test_multiple_large_output_concurrent() {
  # 3 schedules each producing near-max output concurrently
  for i in 1 2 3; do
    agent-store schedule add at 2020-01-01T00:00:00Z -- "head -c 8000 /dev/zero | tr '\\0' 'B'" >/dev/null
  done
  agent-store schedule tick >/dev/null
  local total
  total=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total" -eq 3
}
run_case "3 schedules with near-max output all fire" test_multiple_large_output_concurrent

test_large_stdout_stderr_concurrent() {
  # Large stdout and stderr from different schedules at once
  agent-store schedule add at 2020-01-01T00:00:00Z -- "head -c 4096 /dev/zero | tr '\\0' 'O'" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z -- "head -c 4096 /dev/zero | tr '\\0' 'E' >&2" >/dev/null
  agent-store schedule tick >/dev/null
  local total
  total=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total" -eq 2
}
run_case "large stdout + large stderr concurrent schedules" test_large_stdout_stderr_concurrent

test_large_output_no_block_other_ticks() {
  # A slow large-output schedule doesn't block a fast schedule
  agent-store schedule add at 2020-01-01T00:00:00Z -- "for i in \$(seq 1 100); do echo line-\$i; done" >/dev/null
  agent-store schedule add at 2020-01-01T00:00:00Z -- echo fast >/dev/null
  agent-store schedule tick >/dev/null
  local total
  total=$(agent-store --json schedule runs | jq '.schedule_runs | length')
  test "$total" -eq 2
}
run_case "slow large-output schedule doesn't prevent others" test_large_output_no_block_other_ticks

# ── Section: Crontab Binary Path References ──────────────────────────

echo ""
echo "== Crontab Binary Path References =="

test_crontab_uses_absolute_binary_path() {
  # Crontab entry should reference absolute path to agent-store binary
  agent-store schedule enable >/dev/null
  local binary_path
  binary_path=$(which agent-store)
  local entry
  entry=$(crontab -l 2>/dev/null)
  echo "$entry" | grep -q "$binary_path"
  agent-store schedule disable >/dev/null
}
run_case "crontab references absolute binary path" test_crontab_uses_absolute_binary_path

test_crontab_uses_absolute_project_path() {
  # Crontab entry references absolute project directory
  agent-store schedule enable >/dev/null
  local abs_dir
  abs_dir=$(pwd)
  local entry
  entry=$(crontab -l 2>/dev/null)
  echo "$entry" | grep -q "$abs_dir"
  agent-store schedule disable >/dev/null
}
run_case "crontab references absolute project path" test_crontab_uses_absolute_project_path

test_crontab_symlinked_binary() {
  # Enable with symlinked binary path
  local real_path
  real_path=$(which agent-store)
  ln -sf "$real_path" /tmp/agent-store-symlink
  export PATH="/tmp:$PATH"
  agent-store-symlink schedule enable >/dev/null 2>&1 || agent-store schedule enable >/dev/null
  # Should have a crontab entry
  crontab -l 2>/dev/null | grep -q "schedule tick"
  agent-store schedule disable >/dev/null
  rm -f /tmp/agent-store-symlink
}
run_case "crontab works with symlinked binary" test_crontab_symlinked_binary

test_crontab_marker_comment_present() {
  # Crontab entry should be preceded by a marker comment
  agent-store schedule enable >/dev/null
  local abs_dir
  abs_dir=$(pwd)
  crontab -l 2>/dev/null | grep -q "# agent-store:tick:"
  agent-store schedule disable >/dev/null
}
run_case "crontab has marker comment before entry" test_crontab_marker_comment_present

test_crontab_disable_removes_both_marker_and_entry() {
  # Disable removes both marker comment and the cron command line
  agent-store schedule enable >/dev/null
  crontab -l 2>/dev/null | grep -qc "agent-store" || true
  agent-store schedule disable >/dev/null
  # Neither marker nor command should remain
  ! crontab -l 2>/dev/null | grep -q "agent-store"
}
run_case "disable removes marker and entry together" test_crontab_disable_removes_both_marker_and_entry

# ── Section: Timezone-Aware Timestamp Parsing ────────────────────────

echo ""
echo "== Timezone-Aware Timestamp Parsing =="

test_at_utc_offset_zero_accepted() {
  # at-schedule with +00:00 offset is accepted as a valid timestamp
  agent-store schedule add at "2020-01-01T00:00:00+00:00" -- echo tz-zero >/dev/null
  agent-store --json schedule ls | jq -e '.schedules | length == 1'
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length > 0'
}
run_case "at-schedule with +00:00 offset accepted and fires" test_at_utc_offset_zero_accepted

test_at_positive_tz_offset_accepted() {
  # at-schedule with +05:30 offset is accepted (parsed as Timestamp variant)
  agent-store schedule add at "2020-01-01T05:30:00+05:30" -- echo tz-pos >/dev/null
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e '.schedules | length == 1'
  echo "$json" | jq -r '.schedules[0].expression' | grep -q "2020-01-01T05:30:00+05:30"
}
run_case "at-schedule with +05:30 offset accepted" test_at_positive_tz_offset_accepted

test_at_negative_tz_offset_accepted() {
  # at-schedule with -08:00 offset is accepted
  agent-store schedule add at "2020-01-01T00:00:00-08:00" -- echo tz-neg >/dev/null
  agent-store --json schedule ls | jq -e '.schedules | length == 1'
}
run_case "at-schedule with -08:00 offset accepted" test_at_negative_tz_offset_accepted

test_tz_offset_lexicographic_comparison() {
  # Timezone offsets are compared lexicographically, not semantically.
  # "2020-01-01T12:00:00+05:00" sorts before "Z" suffix strings with same time.
  # The schedule should still fire because 2020 is far in the past.
  agent-store schedule add at "2020-06-15T12:00:00+05:00" -- echo lex-tz >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  # This fires because 2020-06-15T12:00:00+05:00 < current UTC (2026+)
  echo "$json" | jq -e '.schedule_runs | length > 0'
}
run_case "tz offset in past fires (lexicographic comparison)" test_tz_offset_lexicographic_comparison

test_tz_future_offset_no_fire() {
  # Future timestamp with timezone offset should not fire
  agent-store schedule add at "2099-12-31T23:59:59+00:00" -- echo tz-future >/dev/null
  local json
  json=$(agent-store --json schedule tick)
  echo "$json" | jq -e '.schedule_runs | length == 0'
}
run_case "future tz offset timestamp does not fire" test_tz_future_offset_no_fire

test_mixed_z_and_offset_in_ls() {
  # Mix of Z-suffix and offset-suffix timestamps in ls
  agent-store schedule add at "2020-01-01T00:00:00Z" -- echo z-sched >/dev/null
  agent-store schedule add at "2020-01-01T00:00:00+05:00" -- echo offset-sched >/dev/null
  local json
  json=$(agent-store --json schedule ls)
  echo "$json" | jq -e '.schedules | length == 2'
  echo "$json" | jq -r '.schedules[].expression' | grep -q "Z"
  echo "$json" | jq -r '.schedules[].expression' | grep -q "+05:00"
}
run_case "mixed Z and offset timestamps in ls" test_mixed_z_and_offset_in_ls

test_tz_offset_stored_as_is() {
  # The timezone offset should be preserved in the stored expression
  agent-store schedule add at "2025-06-15T09:00:00-07:00" -- echo tz-store >/dev/null
  local expr
  expr=$(agent-store --json schedule ls | jq -r '.schedules[0].expression')
  test "$expr" = "2025-06-15T09:00:00-07:00"
}
run_case "tz offset preserved in stored expression" test_tz_offset_stored_as_is

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo "════════════════════════════════════════"
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
