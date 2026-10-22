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

build_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
  bin="$target_dir/debug/agent-store"
}

# Puts a fake `crontab` first on PATH that keeps the table in $FAKE_CRONTAB,
# so facts never read or write the developer's real crontab. Setting
# FAKE_CRONTAB_LIST_ERROR makes `crontab -l` fail with that message.
use_fake_crontab() {
  mkdir -p "$tmp/fakebin"
  export FAKE_CRONTAB="$tmp/crontab.txt"
  cat >"$tmp/fakebin/crontab" <<'EOF'
#!/bin/sh
case "$1" in
  -l)
    if [ -n "${FAKE_CRONTAB_LIST_ERROR:-}" ]; then
      echo "$FAKE_CRONTAB_LIST_ERROR" >&2
      exit 1
    fi
    if [ -f "$FAKE_CRONTAB" ]; then
      cat "$FAKE_CRONTAB"
    else
      echo "no crontab for $(id -un)" >&2
      exit 1
    fi
    ;;
  -) cat >"$FAKE_CRONTAB" ;;
  *) echo "fake crontab: unsupported arguments: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$tmp/fakebin/crontab"
  export PATH="$tmp/fakebin:$PATH"
}

# Prints the fake crontab line that follows the exact marker line $1.
entry_after() {
  M="$1" awk 'found { print; exit } $0 == ENVIRON["M"] { found = 1 }' "$FAKE_CRONTAB"
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
    use_fake_crontab
    build_agent_store
    root="$(cd "$tmp" && pwd -P)"
    mkdir "$tmp/proj" "$tmp/proj2"
    (cd "$tmp/proj" && "$bin" init >/dev/null)
    (cd "$tmp/proj2" && "$bin" init >/dev/null)
    printf '%s\n' '# user-custom-entry' '0 3 * * * /bin/true' >"$FAKE_CRONTAB"

    out=$(cd "$tmp/proj2" && "$bin" schedule enable)
    test "$out" = "Enabled: crontab entry installed for schedule tick"
    out=$(cd "$tmp/proj" && "$bin" schedule enable)
    test "$out" = "Enabled: crontab entry installed for schedule tick"
    (cd "$tmp/proj" && "$bin" schedule enable >/dev/null)

    # proj's root is a prefix of proj2's: each keeps exactly one entry.
    for p in proj proj2; do
      test "$(grep -cFx "# agent-store:tick:$root/$p" "$FAKE_CRONTAB")" -eq 1
      entry_after "# agent-store:tick:$root/$p" | grep -Eq '^\* \* \* \* \* .*schedule tick'
    done
    test "$(grep -c 'schedule tick' "$FAKE_CRONTAB")" -eq 2
    grep -Fxq '# user-custom-entry' "$FAKE_CRONTAB"

    out=$(cd "$tmp/proj" && "$bin" schedule disable)
    test "$out" = "Disabled: crontab entry removed"
    if grep -Fxq "# agent-store:tick:$root/proj" "$FAKE_CRONTAB"; then exit 1; fi
    entry_after "# agent-store:tick:$root/proj2" | grep -q 'schedule tick'
    test "$(grep -c 'schedule tick' "$FAKE_CRONTAB")" -eq 1

    # proj is no longer enabled; proj2's entry must not be taken for it.
    out=$(cd "$tmp/proj" && "$bin" schedule disable)
    test "$out" = "No crontab entry found for this project"
    entry_after "# agent-store:tick:$root/proj2" | grep -q 'schedule tick'

    out=$(cd "$tmp/proj2" && "$bin" schedule disable)
    test "$out" = "Disabled: crontab entry removed"
    if grep -q 'agent-store:tick' "$FAKE_CRONTAB"; then exit 1; fi
    test "$(cat "$FAKE_CRONTAB")" = "$(printf '%s\n' '# user-custom-entry' '0 3 * * * /bin/true')"
    ;;

  schedule_enable_cron_line)
    use_fake_crontab
    build_agent_store
    root="$(cd "$tmp" && pwd -P)"
    project="$root/it's my proj 100%"
    mkdir "$project" "$tmp/brew bin"
    ln -s "$bin" "$tmp/brew bin/agent-store"
    cd "$project"
    "$bin" init >/dev/null
    "$bin" schedule add at 2020-01-01T00:00:00Z -- "touch '$root/fired'" >/dev/null

    # Invoked through a PATH symlink (Homebrew/Nix layout): the entry keeps
    # the symlink, not the resolved versioned target.
    PATH="$tmp/brew bin:$PATH" agent-store schedule enable >/dev/null
    line=$(entry_after "# agent-store:tick:$project")
    printf '%s\n' "$line" | grep -Fq "brew bin/agent-store'"
    if printf '%s\n' "$line" | grep -Fq "debug/agent-store"; then exit 1; fi
    "$tmp/brew bin/agent-store" schedule enable >/dev/null
    test "$(entry_after "# agent-store:tick:$project")" = "$line"

    # cron turns an unescaped % into a newline and \% into %, then runs the
    # rest with sh.
    cmd=${line#\* \* \* \* \* }
    test "$cmd" != "$line"
    if printf '%s' "$cmd" | sed 's/\\%//g' | grep -q '%'; then exit 1; fi
    cmd=$(printf '%s' "$cmd" | sed 's/\\%/%/g')
    cd /
    env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c "$cmd"
    test -f "$root/fired"
    (cd "$project" && "$bin" schedule runs) | grep -q "exit=0"
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

    # With no crontab for the user, disable reports no entry and stays rc=0.
    use_fake_crontab
    disable_out=$("$bin" schedule disable)
    echo "$disable_out" | grep -q "No crontab entry found for this project"

    # Any other `crontab -l` failure is an error and leaves the crontab as is.
    printf '%s\n' '# user-custom-entry' '0 3 * * * /bin/true' >"$FAKE_CRONTAB"
    cp "$FAKE_CRONTAB" "$tmp/crontab.before"
    export FAKE_CRONTAB_LIST_ERROR="crontab: cannot open spool file: Permission denied"
    set +e
    "$bin" schedule enable >"$tmp"/enable.out 2>"$tmp"/enable.err
    enable_status=$?
    "$bin" schedule disable >"$tmp"/disable.out 2>"$tmp"/disable.err
    disable_status=$?
    set -e
    test "$enable_status" -eq 1
    test "$disable_status" -eq 1
    grep -Fq "Permission denied" "$tmp"/enable.err
    grep -Fq "Permission denied" "$tmp"/disable.err
    test ! -s "$tmp"/enable.out
    cmp "$tmp/crontab.before" "$FAKE_CRONTAB"
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

  schedule_at_timestamp_validation)
    cd "$tmp"
    build_agent_store
    "$bin" init >"$tmp"/init.out

    for bad in 2026-13-45 2026-02-30 2025-02-29 2026-07-10T25:99:00Z \
      2026-07-10T12:60:00Z 2026-07-10T12:00:00+25:00 2026-07-10Tnoon 2026-07-10T12:00:00Zjunk 5é; do
      status=0
      "$bin" schedule add at "$bad" -- true >"$tmp/bad.out" 2>"$tmp/bad.err" || status=$?
      test "$status" -eq 2
      grep -qF "invalid time '$bad'" "$tmp/bad.err"
    done
    test "$("$bin" --json schedule ls | jq '.schedules | length')" -eq 0

    next_of() {
      "$bin" --json schedule ls | jq -r --arg id "$1" '.schedules[] | select(.id == $id) | .next_run_at'
    }
    leap_id=$("$bin" schedule add at 2028-02-29 -- true)
    offset_id=$("$bin" schedule add at 2026-11-01T10:00:00+02:00 -- true)
    west_id=$("$bin" schedule add at 2026-12-31T23:30:00-01:00 -- true)
    zulu_id=$("$bin" schedule add at 2026-12-31T23:59:59Z -- true)
    test "$(next_of "$leap_id")" = 2028-02-29T00:00:00.000Z
    test "$(next_of "$offset_id")" = 2026-11-01T08:00:00.000Z
    test "$(next_of "$west_id")" = 2027-01-01T00:30:00.000Z
    test "$(next_of "$zulu_id")" = 2026-12-31T23:59:59.000Z
    "$bin" schedule ls | grep -q "^$offset_id at 2026-11-01T10:00:00+02:00 next=2026-11-01T08:00:00.000Z "
    for id in "$leap_id" "$offset_id" "$west_id" "$zulu_id"; do
      "$bin" schedule rm "$id" >/dev/null
    done

    # An instant 2 minutes ago written with a +03:00 offset is due now; one
    # 2 hours ahead written with a -03:00 offset is not.
    past=$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)
    future=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
    past_east=$(date -u -d "$past +3 hours" +%Y-%m-%dT%H:%M:%S)+03:00
    future_west=$(date -u -d "$future -3 hours" +%Y-%m-%dT%H:%M:%S)-03:00
    due_id=$("$bin" schedule add at "$past_east" -- 'echo due')
    later_id=$("$bin" schedule add at "$future_west" -- 'echo later')
    tick=$("$bin" --json schedule tick)
    echo "$tick" | jq -e --arg id "$due_id" '.ticked == 1 and .schedule_runs[0].schedule_id == $id'
    "$bin" schedule ls | grep -q "^$due_id .* status=completed"
    "$bin" schedule ls | grep -q "^$later_id .* status=active"
    ;;

  *)
    echo "unknown case: $case_name" >&2
    exit 1
    ;;
esac
