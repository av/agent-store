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
    run_agent_store init >/tmp/agent-store-ctx-wpx-init.out
    task_one="$(run_agent_store create task title=Write status=open)"
    task_two="$(run_agent_store create task title=Ship status=done)"
    note="$(run_agent_store create note title=Plan status=open)"
    run_agent_store hook add create kind=task -- true >/tmp/agent-store-ctx-wpx-hook.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  note: 1
    fields: status, title
  task: 2
    fields: status, title
Hooks: 1
Latest activity: $latest"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"

    case "$got" in
      *"$task_one"*|*"$task_two"*|*"$note"*|*"title="*|*"status="*) exit 1 ;;
    esac
    ;;

  ctx_summary_counts)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-ctx-raf-init.out
    run_agent_store create task title=Write >/tmp/agent-store-ctx-raf-task-1.out
    run_agent_store create task title=Ship >/tmp/agent-store-ctx-raf-task-2.out
    run_agent_store create bug title=Fix >/tmp/agent-store-ctx-raf-bug.out
    run_agent_store hook add rm -- true >/tmp/agent-store-ctx-raf-hook.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  bug: 1
    fields: title
  task: 2
    fields: title
Hooks: 1
Latest activity: $latest"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"
    ;;

  context_alias_matches_ctx)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-context-i3l-init.out
    run_agent_store create task title=Write status=open >/tmp/agent-store-context-i3l-task.out
    run_agent_store hook add create -- true >/tmp/agent-store-context-i3l-hook.out

    ctx_out="$(run_agent_store ctx)"
    context_out="$(run_agent_store context)"
    test "$context_out" = "$ctx_out"

    if run_agent_store context extra >/tmp/agent-store-context-i3l-extra.out 2>/tmp/agent-store-context-i3l-extra.err; then
      exit 1
    fi
    grep -Fq "context does not accept argument 'extra'" /tmp/agent-store-context-i3l-extra.err
    ;;

  ctx_empty_store)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-ctx-k7a-init.out
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
    run_agent_store init >/tmp/agent-store-ctx-261-init.out
    run_agent_store create task title=Write status=open due=2026-06-30 task_only=yes >/tmp/agent-store-ctx-261-task-1.out
    run_agent_store create task title=Ship priority=high >/tmp/agent-store-ctx-261-task-2.out
    run_agent_store create note title=Plan topic=agents note_only=yes >/tmp/agent-store-ctx-261-note.out

    latest="$(latest_activity)"
    expected="Quick Context
Records: 3
Record kinds:
  note: 1
    fields: note_only, title, topic
  task: 2
    fields: due, priority, status, task_only, title
Hooks: 0
Latest activity: $latest"
    got="$(run_agent_store ctx)"
    test "$got" = "$expected"

    case "$got" in
      *"Fields:"*|*"Write"*|*"open"*|*"2026-06-30"*|*"agents"*|*"high"*|*"yes"*) exit 1 ;;
    esac
    ;;

  ctx_output_byte_limit)
    cd "$tmp"
    run_agent_store --help | grep -Fq "Quick Context output is capped at 8192 bytes."

    run_agent_store init >/tmp/agent-store-ctx-uha-init.out
    fields=()
    for index in $(seq -w 1 1600); do
      fields+=("field_$index=value")
    done
    run_agent_store create massive "${fields[@]}" >/tmp/agent-store-ctx-uha-record.out

    run_agent_store ctx >ctx.out
    byte_count="$(wc -c <ctx.out | tr -d ' ')"
    test "$byte_count" -le 8192
    grep -Fq "... truncated at 8192 bytes" ctx.out
    ;;

  *)
    echo "unknown cli_context case: $case_name" >&2
    exit 2
    ;;
esac
