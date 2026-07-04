#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-context-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

latest_activity() {
  python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
row = con.execute(
    "select created_at from store_events order by id desc limit 1"
).fetchone()
print(row[0] if row else "none")
PY
}

case "$case_name" in
  ctx_summary_default)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-wpx-init.out
    task_one="$(run_agent_store create task title=Write status=open)"
    task_two="$(run_agent_store create task title=Ship status=done)"
    note="$(run_agent_store create note title=Plan status=open)"
    run_agent_store hook add create kind=task -- true >"$tmp"/agent-store-ctx-wpx-hook.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  note: 1
    fields: status, title
    status: open=1
  task: 2
    fields: status, title
    status: done=1, open=1
Hooks: 1
Latest activity: $latest
Recent records:
  $note note status=open title=Plan
  $task_two task status=done title=Ship
  $task_one task status=open title=Write"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  ctx_summary_counts)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-raf-init.out
    task_one="$(run_agent_store create task title=Write)"
    task_two="$(run_agent_store create task title=Ship)"
    bug="$(run_agent_store create bug title=Fix)"
    run_agent_store hook add rm -- true >"$tmp"/agent-store-ctx-raf-hook.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  bug: 1
    fields: title
  task: 2
    fields: title
Hooks: 1
Latest activity: $latest
Recent records:
  $bug bug title=Fix
  $task_two task title=Ship
  $task_one task title=Write"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  ctx_domain_summary_contract)
    cd "$tmp"
    run_agent_store init >init.out
    task="$(run_agent_store create task title='Secret Plan' status=open due=2026-07-20 notes=hidden)"
    note="$(run_agent_store create note title='Private Note' topic=confidential)"
    hook_id="$(run_agent_store hook add create 'kind=task and status=open' -- 'printf hook-command-ran')"

    task_id="${task%% *}"
    note_id="${note%% *}"
    latest="$(latest_activity)"
    expected="Quick Context
Records: 2
Record kinds:
  note: 1
    fields: title, topic
  task: 1
    fields: due, notes, status, title
    status: open=1
    due: 2026-07-20..2026-07-20
Hooks: 1
Latest activity: $latest
Recent records:
  $note_id note title='Private Note' topic=confidential
  $task_id task due=2026-07-20 notes=hidden status=open title='Secret Plan'"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"

    byte_count="$(printf "%s" "$got" | wc -c | tr -d ' ')"
    test "$byte_count" -le 8192

    aggregates="${got%%Recent records:*}"
    case "$aggregates" in
      *"$task_id"*|*"$note_id"*|*"$hook_id"*|*"Secret Plan"*|*"Private Note"*|*"confidential"*|*"hidden"*|*"kind=task"*|*"status=open"*|*"hook-command-ran"*) exit 1 ;;
    esac
    case "$got" in
      *"$hook_id"*|*"hook-command-ran"*) exit 1 ;;
    esac
    ;;

  context_alias_matches_ctx)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-context-i3l-init.out
    run_agent_store create task title=Write status=open >"$tmp"/agent-store-context-i3l-task.out
    run_agent_store hook add create -- true >"$tmp"/agent-store-context-i3l-hook.out

    ctx_out="$(run_agent_store ctx)"
    context_out="$(run_agent_store context)"
    test "$context_out" = "$ctx_out"

    if run_agent_store context extra >"$tmp"/agent-store-context-i3l-extra.out 2>"$tmp"/agent-store-context-i3l-extra.err; then
      exit 1
    fi
    grep -Fq "context does not accept argument 'extra'" "$tmp"/agent-store-context-i3l-extra.err
    ;;

  ctx_empty_store)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-k7a-init.out
    expected="Quick Context
Records: 0
Record kinds: none
Hooks: 0
Latest activity: none"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  ctx_fields_by_kind)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-261-init.out
    task_one="$(run_agent_store create task title=Write phase=open deadline=2026-06-30 task_only=yes)"
    task_two="$(run_agent_store create task title=Ship priority=high)"
    note="$(run_agent_store create note title=Plan topic=agents note_only=yes)"

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  note: 1
    fields: note_only, title, topic
  task: 2
    fields: deadline, phase, priority, task_only, title
Hooks: 0
Latest activity: $latest
Recent records:
  $note note note_only=yes title=Plan topic=agents
  $task_two task priority=high title=Ship
  $task_one task deadline=2026-06-30 phase=open task_only=yes title=Write"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"

    aggregates="${got%%Recent records:*}"
    case "$aggregates" in
      *"Fields:"*|*"Write"*|*"open"*|*"2026-06-30"*|*"agents"*|*"high"*|*"yes"*) exit 1 ;;
    esac
    ;;

  ctx_status_date_summaries)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-iln-init.out
    task_one="$(run_agent_store create task title=Plan status=open due=2026-07-15 start=2026-06-01)"
    task_two="$(run_agent_store create task title=Build status=open due=2026-06-28 start=2026-06-03T09:30:00Z)"
    task_three="$(run_agent_store create task title=Ship status=done due=2026-07-01)"
    bug_one="$(run_agent_store create bug title=Fix status=open due=2026-07-10)"
    bug_two="$(run_agent_store create bug title=Triage status=open due=2026-06-29)"

    latest="$(latest_activity)"
    expected="Quick Context
Records: 5
Record kinds:
  bug: 2
    fields: due, status, title
    status: open=2
    due: 2026-06-29..2026-07-10
  task: 3
    fields: due, start, status, title
    status: done=1, open=2
    due: 2026-06-28..2026-07-15
    start: 2026-06-01..2026-06-03T09:30:00Z
Hooks: 0
Latest activity: $latest
Recent records:
  $bug_two bug due=2026-06-29 status=open title=Triage
  $bug_one bug due=2026-07-10 status=open title=Fix
  $task_three task due=2026-07-01 status=done title=Ship
  $task_two task due=2026-06-28 start=2026-06-03T09:30:00Z status=open title=Build
  $task_one task due=2026-07-15 start=2026-06-01 status=open title=Plan"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  ctx_link_summaries)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-pev-init.out
    task_one="$(run_agent_store create task title=Write)"
    task_two="$(run_agent_store create task title=Ship)"
    bug="$(run_agent_store create bug title=Fix)"
    milestone="$(run_agent_store create milestone title=Launch)"
    task_one_id="${task_one%% *}"
    task_two_id="${task_two%% *}"
    bug_id="${bug%% *}"
    milestone_id="${milestone%% *}"

    run_agent_store link "$task_one_id" blocks "$task_two_id" >"$tmp"/agent-store-ctx-pev-link-1.out
    run_agent_store link "$task_one_id" blocks "$bug_id" >"$tmp"/agent-store-ctx-pev-link-2.out
    run_agent_store link "$task_two_id" relates_to "$bug_id" >"$tmp"/agent-store-ctx-pev-link-3.out
    run_agent_store link "$bug_id" tracks "$milestone_id" >"$tmp"/agent-store-ctx-pev-link-4.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 4
Record kinds:
  bug: 1
    fields: title
  milestone: 1
    fields: title
  task: 2
    fields: title
Links: 4
  blocks: 2
  relates_to: 1
  tracks: 1
Hooks: 0
Latest activity: $latest
Recent records:
  $milestone_id milestone title=Launch
  $bug_id bug title=Fix
  $task_two_id task title=Ship
  $task_one_id task title=Write"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  ctx_output_byte_limit)
    cd "$tmp"
    run_agent_store --help | grep -Fq "Quick Context output is capped at 8192 bytes."

    run_agent_store init >"$tmp"/agent-store-ctx-uha-init.out
    fields=()
    for index in $(seq -w 1 1600); do
      fields+=("field_$index=value")
    done
    run_agent_store create massive "${fields[@]}" >"$tmp"/agent-store-ctx-uha-record.out

    run_agent_store ctx >ctx.out
    byte_count="$(wc -c <ctx.out | tr -d ' ')"
    test "$byte_count" -le 8193
    test "$(tail -c1 ctx.out)" = ""
    content_byte_count="$(head -c -1 ctx.out | wc -c | tr -d ' ')"
    test "$content_byte_count" -le 8192
    grep -Fq "... truncated at 8192 bytes" ctx.out
    ;;

  ctx_json_summary)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-cxj-init.out
    task_one="$(run_agent_store create task title=Write status=open due=2026-06-26)"
    task_two="$(run_agent_store create task title=Ship status=done due=2026-06-30)"
    note="$(run_agent_store create note title=Plan)"
    run_agent_store link "$task_one" blocks "$task_two" >"$tmp"/agent-store-ctx-cxj-link.out
    run_agent_store hook add create kind=task -- true >"$tmp"/agent-store-ctx-cxj-hook.out

    latest="$(latest_activity)"
    run_agent_store --json ctx >ctx.json
    python3 - ctx.json "$latest" "$note" "$task_two" "$task_one" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    summary = json.load(handle)

assert summary["record_count"] == 3, summary
assert summary["records_by_kind"] == {"note": 1, "task": 2}, summary
assert summary["fields_by_kind"] == {
    "note": ["title"],
    "task": ["due", "status", "title"],
}, summary
assert summary["status_counts_by_kind"] == {"task": {"done": 1, "open": 1}}, summary
assert summary["date_windows_by_kind"] == {
    "task": {"due": {"earliest": "2026-06-26", "latest": "2026-06-30"}}
}, summary
assert summary["link_count"] == 1, summary
assert summary["links_by_relation"] == {"blocks": 1}, summary
assert summary["hook_count"] == 1, summary
assert summary["latest_activity_at"] == sys.argv[2], summary
assert summary["recent_records"] == [
    {"id": sys.argv[3], "kind": "note", "fields": {"title": "Plan"}},
    {
        "id": sys.argv[4],
        "kind": "task",
        "fields": {"due": "2026-06-30", "status": "done", "title": "Ship"},
    },
    {
        "id": sys.argv[5],
        "kind": "task",
        "fields": {"due": "2026-06-26", "status": "open", "title": "Write"},
    },
], summary
PY

    byte_count="$(wc -c <ctx.json | tr -d ' ')"
    test "$byte_count" -le 8193
    ;;

  ctx_recent_value_truncation)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-trunc-init.out
    long_value="$(printf 'a%.0s' $(seq 1 300))"
    record="$(run_agent_store create note body="$long_value")"

    truncated="$(printf 'a%.0s' $(seq 1 100))..."
    got="$(run_agent_store ctx)"
    case "$got" in
      *"$long_value"*) exit 1 ;;
    esac
    case "$got" in
      *"  $record note body=$truncated"*) ;;
      *) exit 1 ;;
    esac

    run_agent_store --json ctx >ctx.json
    test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["recent_records"][0]["fields"]["body"])' ctx.json)" = "$truncated"
    ;;

  ctx_recent_cap_large_field)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-cap-init.out
    run_agent_store create handoff summary='Refactor auth module next' >"$tmp"/agent-store-ctx-cap-handoff.out
    big="$(head -c 20000 /dev/zero | tr '\0' 'x')"
    run_agent_store create blob data="$big" >"$tmp"/agent-store-ctx-cap-blob.out

    run_agent_store ctx >ctx.out
    grep -Fq "Recent records:" ctx.out
    grep -Fq "Refactor auth module next" ctx.out
    test "$(wc -c <ctx.out | tr -d ' ')" -le 8192
    if grep -Fq "$big" ctx.out; then exit 1; fi

    run_agent_store --json ctx >ctx.json
    test "$(wc -c <ctx.json | tr -d ' ')" -le 8192
    python3 - ctx.json <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    summary = json.load(handle)

assert len(summary["recent_records"]) >= 1, summary
for record in summary["recent_records"]:
    for value in record["fields"].values():
        assert len(value) <= 103, record
PY
    ;;

  ctx_recent_ordering)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-ctx-order-init.out
    first="$(run_agent_store create task title=First)"
    second="$(run_agent_store create task title=Second)"
    third="$(run_agent_store create task title=Third)"
    run_agent_store set "$first" status=open >"$tmp"/agent-store-ctx-order-set.out

    expected_recent="Recent records:
  $first task status=open title=First
  $third task title=Third
  $second task title=Second"
    got="$(run_agent_store ctx)"
    case "$got" in
      *"$expected_recent"*) ;;
      *) exit 1 ;;
    esac

    run_agent_store --json ctx >ctx.json
    test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["recent_records"][0]["id"])' ctx.json)" = "$first"
    ;;

  *)
    echo "usage: $0 {ctx_summary_default|ctx_summary_counts|ctx_domain_summary_contract|context_alias_matches_ctx|ctx_empty_store|ctx_fields_by_kind|ctx_status_date_summaries|ctx_link_summaries|ctx_output_byte_limit|ctx_json_summary|ctx_recent_value_truncation|ctx_recent_cap_large_field|ctx_recent_ordering}" >&2
    exit 2
    ;;
esac
