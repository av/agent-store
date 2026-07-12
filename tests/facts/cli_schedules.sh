#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-schedules-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

case "$case_name" in
  schedule_add_list_remove)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    id=$(run_agent_store schedule add every 5m -- echo tick)
    printf "%s\n" "$id" | grep -Eq "^[a-z0-9]{6,8}$"

    at_id=$(run_agent_store schedule add at 2026-12-31T23:59:59Z -- echo once)
    printf "%s\n" "$at_id" | grep -Eq "^[a-z0-9]{6,8}$"

    listing=$(run_agent_store schedule ls)
    echo "$listing" | grep -q "$id"
    echo "$listing" | grep -q "$at_id"
    echo "$listing" | grep -q "every 5m"
    echo "$listing" | grep -q "at 2026-12-31T23:59:59Z"

    out=$(run_agent_store schedule rm "$id")
    test "$out" = "Removed $id"

    listing_after=$(run_agent_store schedule ls)
    if echo "$listing_after" | grep -q "$id"; then exit 1; fi
    echo "$listing_after" | grep -q "$at_id"
    ;;

  schedule_json_output)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    id=$(run_agent_store schedule add every 10m -- echo json)

    json_ls=$(run_agent_store --json schedule ls)
    echo "$json_ls" | jq -e ".schedules[0].id == \"$id\""
    echo "$json_ls" | jq -e ".schedules[0].kind == \"every\""
    echo "$json_ls" | jq -e ".schedules[0].expression == \"10m\""
    echo "$json_ls" | jq -e ".schedules[0].interval_seconds == 600"
    echo "$json_ls" | jq -e ".schedules[0].command == \"echo json\""
    echo "$json_ls" | jq -e ".schedules[0].status == \"active\""

    json_rm=$(run_agent_store --json schedule rm "$id")
    echo "$json_rm" | jq -e ".status == \"removed\""
    echo "$json_rm" | jq -e ".schedule.id == \"$id\""
    ;;

  schedule_tick_fires_due)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    at_id=$(run_agent_store schedule add at 2020-01-01T00:00:00Z -- 'echo fired')
    every_id=$(run_agent_store schedule add every 1s -- 'echo recurring')
    sleep 2

    tick_out=$(run_agent_store schedule tick)
    echo "$tick_out" | grep -q "exit=0"

    runs=$(run_agent_store schedule runs)
    echo "$runs" | grep -q "exit=0"

    listing=$(run_agent_store schedule ls)
    echo "$listing" | grep -q "status=completed"
    echo "$listing" | grep -q "status=active"
    ;;

  schedule_tick_json)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    run_agent_store schedule add at 2020-01-01T00:00:00Z -- 'echo ok'

    json_tick=$(run_agent_store --json schedule tick)
    test "$(echo "$json_tick" | jq '.ticked')" -ge 1
    echo "$json_tick" | jq -e ".schedule_runs | length >= 1"
    ;;

  schedule_with_query)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    run_agent_store create task title=A status=open >/dev/null
    run_agent_store create task title=B status=done >/dev/null

    run_agent_store schedule add at 2020-01-01T00:00:00Z 'kind=task and status=open' -- 'echo $AGENT_STORE_RECORD_ID'

    json_tick=$(run_agent_store --json schedule tick)
    test "$(echo "$json_tick" | jq '.ticked')" -eq 1
    test "$(echo "$json_tick" | jq '.schedule_runs | length')" -eq 1
    ;;

  schedule_runs_detail)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    run_agent_store schedule add at 2020-01-01T00:00:00Z -- 'echo detail-test'
    run_agent_store schedule tick >/dev/null

    run_id=$(run_agent_store --json schedule runs | jq '.schedule_runs[0].id')
    detail=$(run_agent_store schedule runs "$run_id")
    echo "$detail" | grep -q "detail-test"
    echo "$detail" | grep -q "exit_status: 0"
    ;;

  schedule_enable_disable)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    enable_out=$(run_agent_store schedule enable)
    echo "$enable_out" | grep -q "Enabled"

    crontab -l | grep -q "agent-store:tick:$tmp"
    crontab -l | grep -q "schedule tick"

    disable_out=$(run_agent_store schedule disable)
    echo "$disable_out" | grep -q "Disabled"

    if crontab -l 2>/dev/null | grep -q "agent-store:tick:$tmp"; then exit 1; fi
    ;;

  schedule_disable_missing_crontab)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$bin" init >"$tmp"/init.out

    # A PATH with no crontab binary must fail enable and disable alike.
    mkdir "$tmp/emptybin"
    set +e
    env PATH="$tmp/emptybin" "$bin" schedule enable \
      >"$tmp"/enable.out 2>"$tmp"/enable.err
    enable_status=$?
    env PATH="$tmp/emptybin" "$bin" schedule disable \
      >"$tmp"/disable.out 2>"$tmp"/disable.err
    disable_status=$?
    set -e
    test "$enable_status" -eq 1
    test "$disable_status" -eq 1
    grep -Fq "failed to run crontab" "$tmp"/disable.err
    test ! -s "$tmp"/disable.out

    # With a working crontab and no entry for this project, disable stays rc=0.
    disable_out=$("$bin" schedule disable)
    echo "$disable_out" | grep -q "No crontab entry found for this project"
    ;;

  schedule_ctx_integration)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    run_agent_store schedule add every 1h -- 'echo ctx-test'

    ctx_out=$(run_agent_store ctx)
    echo "$ctx_out" | grep -q "Schedules: 1 active"

    json_ctx=$(run_agent_store --json ctx)
    echo "$json_ctx" | jq -e ".schedule_summary.active_schedules == 1"
    echo "$json_ctx" | jq -e ".schedule_summary.status == \"enabled\""
    ;;

  schedule_help)
    cd "$tmp"
    run_agent_store init >"$tmp"/init.out

    help_out=$(run_agent_store schedule --help)
    echo "$help_out" | grep -q "schedule"
    echo "$help_out" | grep -q "add"
    echo "$help_out" | grep -q "tick"
    echo "$help_out" | grep -q "enable"
    echo "$help_out" | grep -q "disable"

    add_help=$(run_agent_store schedule add --help)
    echo "$add_help" | grep -q "at"
    echo "$add_help" | grep -q "every"
    ;;

  *)
    echo "unknown case: $case_name" >&2
    exit 1
    ;;
esac
