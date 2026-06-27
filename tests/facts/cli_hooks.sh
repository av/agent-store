#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-hooks-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

unique_prefix_for() {
  local first="$1"
  local second="$2"
  local length

  for length in 1 2 3 4 5 6; do
    local prefix
    prefix="$(printf "%s" "$first" | cut -c1-"$length")"
    case "$second" in
      "$prefix"*) ;;
      *)
        printf "%s" "$prefix"
        return 0
        ;;
    esac
  done

  printf "%s" "$first"
}

case "$case_name" in
  hook_add_stores_metadata)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-add-1me-init.out

    id="$(run_agent_store hook add create 'kind=task and status=open' -- echo created)"
    no_query_id="$(run_agent_store hook add rm -- echo removed)"
    printf "%s\n" "$id" | grep -Eq "^[a-z0-9]{6,8}$"
    printf "%s\n" "$no_query_id" | grep -Eq "^[a-z0-9]{6,8}$"

    python3 - .agent-store/store.sqlite "$id" "$no_query_id" <<'PY'
import sqlite3
import sys

db, with_query_id, no_query_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = {
    row[0]: row[1:]
    for row in con.execute(
        """
        select id, event, query, command, created_at
        from hooks
        order by id
        """
    )
}
assert set(rows) == {with_query_id, no_query_id}, rows
assert rows[with_query_id][:3] == (
    "create",
    "kind=task and status=open",
    "echo created",
), rows[with_query_id]
assert rows[with_query_id][3], rows[with_query_id]
assert rows[no_query_id][:3] == ("rm", None, "echo removed"), rows[no_query_id]
assert rows[no_query_id][3], rows[no_query_id]
PY

    if run_agent_store hook add update -- echo nope >/tmp/agent-store-hook-add-1me-bad-event.out 2>/tmp/agent-store-hook-add-1me-bad-event.err; then
      exit 1
    fi
    grep -Fq "not supported" /tmp/agent-store-hook-add-1me-bad-event.err

    if run_agent_store hook add create 'kind=task and' -- echo bad >/tmp/agent-store-hook-add-1me-bad-query.out 2>/tmp/agent-store-hook-add-1me-bad-query.err; then
      exit 1
    fi
    grep -Fq "invalid hook query" /tmp/agent-store-hook-add-1me-bad-query.err
    ;;

  hook_ls_deterministic)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-ls-pn0-init.out

    first="$(run_agent_store hook add create kind=task -- echo created)"
    second="$(run_agent_store hook add rm -- echo removed)"

    first_line="$first create query='kind=task' -- 'echo created'"
    second_line="$second rm -- 'echo removed'"
    expected="$(printf "%s\n%s\n" "$first_line" "$second_line" | sort)"
    got="$(run_agent_store hook ls)"
    test "$got" = "$expected"
    ;;

  hook_rm_deletes_metadata)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-rm-nih-init.out

    removed_id="$(run_agent_store hook add create kind=task -- echo created)"
    kept_id="$(run_agent_store hook add rm -- echo removed)"
    removed_prefix="$(unique_prefix_for "$removed_id" "$kept_id")"

    out="$(run_agent_store hook rm "$removed_prefix")"
    test "$out" = "Removed $removed_id"

    kept_line="$kept_id rm -- 'echo removed'"
    got="$(run_agent_store hook ls)"
    test "$got" = "$kept_line"

    python3 - .agent-store/store.sqlite "$removed_id" "$kept_id" <<'PY'
import sqlite3
import sys

db, removed_id, kept_id = sys.argv[1:]
con = sqlite3.connect(db)
ids = [row[0] for row in con.execute("select id from hooks order by id")]
assert ids == [kept_id], ids
assert removed_id not in ids
PY

    if run_agent_store hook rm "$removed_id" >/tmp/agent-store-hook-rm-nih-again.out 2>/tmp/agent-store-hook-rm-nih-again.err; then
      exit 1
    fi
    grep -Fq "was not found" /tmp/agent-store-hook-rm-nih-again.err
    ;;

  hooks_run_after_commit)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-runtime-w5s-init.out

    cat > agent-store <<SH
#!/usr/bin/env bash
exec "$target_dir/debug/agent-store" "\$@"
SH
    chmod +x agent-store
    export PATH="$tmp:$PATH"

    create_hook_id="$(run_agent_store hook add create -- 'agent-store find kind=task > hook-visible.txt; printf hook-stdout')"
    set_hook_id="$(run_agent_store hook add set -- 'touch failed-set-hook-ran')"

    id="$(run_agent_store create task title=Committed status=open)"
    visible="$(cat hook-visible.txt)"
    test "$visible" = "$id task status=open title=Committed"

    if run_agent_store set missing status=done >/tmp/agent-store-hook-runtime-w5s-failed-set.out 2>/tmp/agent-store-hook-runtime-w5s-failed-set.err; then
      exit 1
    fi
    grep -Fq "was not found" /tmp/agent-store-hook-runtime-w5s-failed-set.err
    test ! -e failed-set-hook-ran

    python3 - .agent-store/store.sqlite "$create_hook_id" "$set_hook_id" "$id" <<'PY'
import sqlite3
import sys

db, create_hook_id, set_hook_id, record_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (create_hook_id, "create", record_id, 0, "hook-stdout", ""),
], rows
assert not any(row[0] == set_hook_id for row in rows), rows
PY
    ;;

  hook_query_filters_records)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-query-mlq-init.out

    source_id="$(run_agent_store create task title=Source status=open score=11)"
    target_id="$(run_agent_store create note title=Target status=open)"

    create_hook_id="$(run_agent_store hook add create '(kind=task and status=open) or score>=10' -- 'printf "create-match\n" >> hook-log.txt; printf create-stdout')"
    skipped_create_hook_id="$(run_agent_store hook add create 'kind=bug or score<0' -- 'printf "create-skip\n" >> hook-log.txt; printf create-skip')"
    link_hook_id="$(run_agent_store hook add link 'kind=task and status=open' -- 'printf "link-match\n" >> hook-log.txt; printf link-stdout')"
    skipped_link_hook_id="$(run_agent_store hook add link 'kind=note' -- 'printf "link-skip\n" >> hook-log.txt; printf link-skip')"

    matched_id="$(run_agent_store create task title=Matched status=open score=12)"
    run_agent_store create task title=Closed status=done score=2 >/tmp/agent-store-hook-query-mlq-closed.out
    run_agent_store link "$source_id" blocks "$target_id" >/tmp/agent-store-hook-query-mlq-link.out

    expected_log="$(printf "create-match\nlink-match\n")"
    test "$(cat hook-log.txt)" = "$expected_log"

    python3 - .agent-store/store.sqlite \
      "$create_hook_id" \
      "$skipped_create_hook_id" \
      "$link_hook_id" \
      "$skipped_link_hook_id" \
      "$matched_id" \
      "$source_id" <<'PY'
import sqlite3
import sys

(
    db,
    create_hook_id,
    skipped_create_hook_id,
    link_hook_id,
    skipped_link_hook_id,
    matched_id,
    source_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (create_hook_id, "create", matched_id, 0, "create-stdout", ""),
    (link_hook_id, "link", source_id, 0, "link-stdout", ""),
], rows
skipped = {skipped_create_hook_id, skipped_link_hook_id}
assert not any(row[0] in skipped for row in rows), rows
PY
    ;;

  hook_query_uses_mutation_snapshot)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-query-887-init.out

    cat > hook-log.sh <<'SH'
#!/usr/bin/env bash
printf "%s\n" "$1" >> hook-log.txt
printf "%s" "$1"
SH
    chmod +x hook-log.sh

    create_after_id="$(run_agent_store hook add create 'kind=task and status=new' -- './hook-log.sh create-after')"
    create_skip_id="$(run_agent_store hook add create 'status=done' -- './hook-log.sh create-skip')"

    record_id="$(run_agent_store create task title=Snapshot status=new flag=keep)"

    set_after_id="$(run_agent_store hook add set 'status=done' -- './hook-log.sh set-after')"
    set_before_id="$(run_agent_store hook add set 'status=new' -- './hook-log.sh set-before')"
    run_agent_store set "$record_id" status=done >/tmp/agent-store-hook-query-887-set.out

    unset_after_id="$(run_agent_store hook add unset 'not flag=keep' -- './hook-log.sh unset-after')"
    unset_before_id="$(run_agent_store hook add unset 'flag=keep' -- './hook-log.sh unset-before')"
    run_agent_store unset "$record_id" flag >/tmp/agent-store-hook-query-887-unset.out

    rm_pre_id="$(run_agent_store hook add rm 'status=done' -- './hook-log.sh rm-pre')"
    rm_after_id="$(run_agent_store hook add rm 'not status=done' -- './hook-log.sh rm-after')"
    run_agent_store rm "$record_id" >/tmp/agent-store-hook-query-887-rm.out

    expected_log="$(printf "create-after\nset-after\nunset-after\nrm-pre\n")"
    test "$(cat hook-log.txt)" = "$expected_log"

    python3 - .agent-store/store.sqlite \
      "$create_after_id" \
      "$create_skip_id" \
      "$set_after_id" \
      "$set_before_id" \
      "$unset_after_id" \
      "$unset_before_id" \
      "$rm_pre_id" \
      "$rm_after_id" \
      "$record_id" <<'PY'
import sqlite3
import sys

(
    db,
    create_after_id,
    create_skip_id,
    set_after_id,
    set_before_id,
    unset_after_id,
    unset_before_id,
    rm_pre_id,
    rm_after_id,
    record_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (create_after_id, "create", record_id, 0, "create-after", ""),
    (set_after_id, "set", record_id, 0, "set-after", ""),
    (unset_after_id, "unset", record_id, 0, "unset-after", ""),
    (rm_pre_id, "rm", record_id, 0, "rm-pre", ""),
], rows
skipped = {create_skip_id, set_before_id, unset_before_id, rm_after_id}
assert not any(row[0] in skipped for row in rows), rows
PY
    ;;

  hook_stdin_receives_record_snapshot)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-stdin-9i8-init.out

    cat > hook-stdin.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf "%s:%s\n" "$1" "$payload" >> hook-stdin.log
printf "%s" "$1"
SH
    chmod +x hook-stdin.sh

    create_hook_id="$(run_agent_store hook add create -- './hook-stdin.sh create')"
    record_id="$(run_agent_store create task title='Hello world' status=new flag=keep)"

    set_hook_id="$(run_agent_store hook add set -- './hook-stdin.sh set')"
    run_agent_store set "$record_id" status=done note='needs review' >/tmp/agent-store-hook-stdin-9i8-set.out

    unset_hook_id="$(run_agent_store hook add unset -- './hook-stdin.sh unset')"
    run_agent_store unset "$record_id" flag >/tmp/agent-store-hook-stdin-9i8-unset.out

    rm_hook_id="$(run_agent_store hook add rm -- './hook-stdin.sh rm')"
    run_agent_store rm "$record_id" >/tmp/agent-store-hook-stdin-9i8-rm.out

    expected_log="$(
      printf "create:%s task flag=keep status=new title='Hello world'\n" "$record_id"
      printf "set:%s task flag=keep note='needs review' status=done title='Hello world'\n" "$record_id"
      printf "unset:%s task note='needs review' status=done title='Hello world'\n" "$record_id"
      printf "rm:%s task note='needs review' status=done title='Hello world'\n" "$record_id"
    )"
    test "$(cat hook-stdin.log)" = "$expected_log"

    python3 - .agent-store/store.sqlite \
      "$create_hook_id" \
      "$set_hook_id" \
      "$unset_hook_id" \
      "$rm_hook_id" \
      "$record_id" <<'PY'
import sqlite3
import sys

(
    db,
    create_hook_id,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    record_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (create_hook_id, "create", record_id, 0, "create", ""),
    (set_hook_id, "set", record_id, 0, "set", ""),
    (unset_hook_id, "unset", record_id, 0, "unset", ""),
    (rm_hook_id, "rm", record_id, 0, "rm", ""),
], rows
PY
    ;;

  hook_failure_reports_details)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-failure-hxt-init.out

    hook_command='printf hook-stdout; printf hook-stderr >&2; exit 17'
    hook_id="$(run_agent_store hook add create -- "$hook_command")"

    if run_agent_store create task title=Failure >/tmp/agent-store-hook-failure-hxt.out 2>/tmp/agent-store-hook-failure-hxt.err; then
      exit 1
    fi

    grep -Fq "hook $hook_id" /tmp/agent-store-hook-failure-hxt.err
    grep -Fq -- "$hook_command" /tmp/agent-store-hook-failure-hxt.err
    grep -Fq "exit status 17" /tmp/agent-store-hook-failure-hxt.err
    grep -Fq "hook-stderr" /tmp/agent-store-hook-failure-hxt.err

    python3 - .agent-store/store.sqlite "$hook_id" <<'PY'
import sqlite3
import sys

db, hook_id = sys.argv[1:]
con = sqlite3.connect(db)
records = con.execute("select id, kind from records").fetchall()
assert len(records) == 1, records
record_id, kind = records[0]
assert kind == "task", records

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (hook_id, "create", record_id, 17, "hook-stdout", "hook-stderr"),
], rows
PY
    ;;

  hook_failure_or_timeout_reports_committed_mutation)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-committed-fgg-init.out

    failure_command='printf failure-stdout; printf failure-stderr >&2; exit 23'
    failure_hook_id="$(run_agent_store hook add create title=CommittedFailure -- "$failure_command")"

    if run_agent_store create task title=CommittedFailure >/tmp/agent-store-hook-committed-fgg-failure.out 2>/tmp/agent-store-hook-committed-fgg-failure.err; then
      exit 1
    fi

    grep -Fq "Store mutation already committed" /tmp/agent-store-hook-committed-fgg-failure.err
    grep -Fq "exit status 23" /tmp/agent-store-hook-committed-fgg-failure.err
    grep -Fq "failure-stderr" /tmp/agent-store-hook-committed-fgg-failure.err

    timeout_command='printf timeout-stderr >&2; while :; do sleep 1; done'
    timeout_hook_id="$(run_agent_store hook add create title=CommittedTimeout -- "$timeout_command")"

    set +e
    timeout 40s "$target_dir/debug/agent-store" create task title=CommittedTimeout >/tmp/agent-store-hook-committed-fgg-timeout.out 2>/tmp/agent-store-hook-committed-fgg-timeout.err
    timeout_status=$?
    set -e

    test "$timeout_status" -ne 0
    test "$timeout_status" -ne 124
    grep -Fq "Store mutation already committed" /tmp/agent-store-hook-committed-fgg-timeout.err
    grep -Fq "timed out after 30 seconds" /tmp/agent-store-hook-committed-fgg-timeout.err
    grep -Fq "timeout-stderr" /tmp/agent-store-hook-committed-fgg-timeout.err

    python3 - .agent-store/store.sqlite "$failure_hook_id" "$timeout_hook_id" <<'PY'
import sqlite3
import sys

db, failure_hook_id, timeout_hook_id = sys.argv[1:]
con = sqlite3.connect(db)
records = {
    row[1]: row[0]
    for row in con.execute(
        """
        select records.id, record_fields.raw_value
        from records
        join record_fields on record_fields.record_id = records.id
        where records.kind = 'task'
          and record_fields.key = 'title'
          and record_fields.raw_value in ('CommittedFailure', 'CommittedTimeout')
        """
    )
}
assert set(records) == {"CommittedFailure", "CommittedTimeout"}, records

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id in (?, ?)
    order by id
    """,
    (failure_hook_id, timeout_hook_id),
).fetchall()
assert len(rows) == 2, rows

by_hook = {row[0]: row[1:] for row in rows}
assert by_hook[failure_hook_id] == (
    "create",
    records["CommittedFailure"],
    23,
    "failure-stdout",
    "failure-stderr",
), by_hook[failure_hook_id]

timeout_row = by_hook[timeout_hook_id]
assert timeout_row[:4] == (
    "create",
    records["CommittedTimeout"],
    -1,
    "",
), timeout_row
assert "timeout-stderr" in timeout_row[4], timeout_row
assert "timed out after 30 seconds" in timeout_row[4], timeout_row
PY
    ;;

  json_mutation_hook_failure_or_timeout_reports_committed_without_success_json)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-json-hook-failure-jhf-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    cat > fail-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
printf "%s-failure-stdout" "$name"
printf "%s-failure-stderr" "$name" >&2
exit 31
SH
    chmod +x fail-hook.sh

    cat > timeout-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
printf "%s-timeout-stderr" "$name" >&2
while :; do
  sleep 1
done
SH
    chmod +x timeout-hook.sh

    set_record="$("$agent_store_bin" create task op=json-fail-set status=pending)"
    unset_record="$("$agent_store_bin" create task op=json-fail-unset flag=present)"
    rm_record="$("$agent_store_bin" create task op=json-fail-rm action=remove)"
    link_source="$("$agent_store_bin" create task op=json-fail-link status=open)"
    link_target="$("$agent_store_bin" create note op=json-fail-link-target status=open)"
    unlink_source="$("$agent_store_bin" create task op=json-fail-unlink status=open)"
    unlink_target="$("$agent_store_bin" create note op=json-fail-unlink-target status=open)"
    timeout_record="$("$agent_store_bin" create task op=json-timeout-set status=pending)"
    "$agent_store_bin" link "$unlink_source" blocks "$unlink_target" >/tmp/agent-store-json-hook-failure-jhf-seed-unlink.out

    create_hook_id="$("$agent_store_bin" hook add create 'kind=task and op=json-fail-create' -- './fail-hook.sh create')"
    set_hook_id="$("$agent_store_bin" hook add set 'kind=task and op=json-fail-set and status=done' -- './fail-hook.sh set')"
    unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and op=json-fail-unset and not flag=present' -- './fail-hook.sh unset')"
    rm_hook_id="$("$agent_store_bin" hook add rm 'kind=task and op=json-fail-rm and action=remove' -- './fail-hook.sh rm')"
    link_hook_id="$("$agent_store_bin" hook add link 'kind=task and op=json-fail-link' -- './fail-hook.sh link')"
    unlink_hook_id="$("$agent_store_bin" hook add unlink 'kind=task and op=json-fail-unlink' -- './fail-hook.sh unlink')"
    timeout_hook_id="$("$agent_store_bin" hook add set 'kind=task and op=json-timeout-set and status=timeout' -- './timeout-hook.sh set')"
    create_timeout_hook_id="$("$agent_store_bin" hook add create 'kind=task and op=json-timeout-create' -- './timeout-hook.sh create')"

    event_marker="$(python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
print(con.execute("select coalesce(max(id), 0) from store_events").fetchone()[0])
PY
)"
    hook_marker="$(python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
print(con.execute("select coalesce(max(id), 0) from hook_runs").fetchone()[0])
PY
)"

    run_json_failure() {
      local name="$1"
      shift
      set +e
      "$agent_store_bin" --json "$@" >"$tmp/json-hook-$name.out" 2>"$tmp/json-hook-$name.err"
      local status="$?"
      set -e
      printf "%s" "$status" >"$tmp/json-hook-$name.status"
      test "$status" -ne 0
      test ! -s "$tmp/json-hook-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/json-hook-$name.err"
      grep -Fq "exit status 31" "$tmp/json-hook-$name.err"
      grep -Fq "$name-failure-stderr" "$tmp/json-hook-$name.err"
    }

    run_json_failure create create task op=json-fail-create status=committed
    run_json_failure set set "$set_record" status=done
    run_json_failure unset unset "$unset_record" flag
    run_json_failure rm rm "$rm_record"
    run_json_failure link link "$link_source" blocks "$link_target"
    run_json_failure unlink unlink "$unlink_source" blocks "$unlink_target"

    set +e
    timeout 40s "$agent_store_bin" --json set "$timeout_record" status=timeout >"$tmp/json-hook-timeout.out" 2>"$tmp/json-hook-timeout.err"
    timeout_status="$?"
    set -e
    printf "%s" "$timeout_status" >"$tmp/json-hook-timeout.status"
    test "$timeout_status" -ne 0
    test "$timeout_status" -ne 124
    test ! -s "$tmp/json-hook-timeout.out"
    grep -Fq "Store mutation already committed" "$tmp/json-hook-timeout.err"
    grep -Fq "timed out after 30 seconds" "$tmp/json-hook-timeout.err"
    grep -Fq "set-timeout-stderr" "$tmp/json-hook-timeout.err"

    set +e
    timeout 40s "$agent_store_bin" --json create task op=json-timeout-create status=committed >"$tmp/json-hook-create-timeout.out" 2>"$tmp/json-hook-create-timeout.err"
    create_timeout_status="$?"
    set -e
    printf "%s" "$create_timeout_status" >"$tmp/json-hook-create-timeout.status"
    test "$create_timeout_status" -ne 0
    test "$create_timeout_status" -ne 124
    test ! -s "$tmp/json-hook-create-timeout.out"
    grep -Fq "Store mutation already committed" "$tmp/json-hook-create-timeout.err"
    grep -Fq "timed out after 30 seconds" "$tmp/json-hook-create-timeout.err"
    grep -Fq "create-timeout-stderr" "$tmp/json-hook-create-timeout.err"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$set_record" \
      "$unset_record" \
      "$rm_record" \
      "$link_source" \
      "$link_target" \
      "$unlink_source" \
      "$unlink_target" \
      "$timeout_record" \
      "$create_hook_id" \
      "$set_hook_id" \
      "$unset_hook_id" \
      "$rm_hook_id" \
      "$link_hook_id" \
      "$unlink_hook_id" \
      "$timeout_hook_id" \
      "$create_timeout_hook_id" <<'PY'
from collections import Counter
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    event_marker_s,
    hook_marker_s,
    set_record,
    unset_record,
    rm_record,
    link_source,
    link_target,
    unlink_source,
    unlink_target,
    timeout_record,
    create_hook_id,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    link_hook_id,
    unlink_hook_id,
    timeout_hook_id,
    create_timeout_hook_id,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)

for name in ["create", "set", "unset", "rm", "link", "unlink", "timeout", "create-timeout"]:
    stdout = (tmp / f"json-hook-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"json-hook-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"json-hook-{name}.status").read_text(encoding="utf-8"))
    assert stdout == "", (name, stdout)
    assert status != 0, (name, status)
    assert "Store mutation already committed" in stderr, (name, stderr)
    if name in {"timeout", "create-timeout"}:
        assert status != 124, status
        assert "timed out after 30 seconds" in stderr, stderr
        expected_stderr = "create-timeout-stderr" if name == "create-timeout" else "set-timeout-stderr"
        assert expected_stderr in stderr, stderr
    else:
        assert "exit status 31" in stderr, (name, stderr)
        assert f"{name}-failure-stderr" in stderr, (name, stderr)

con = sqlite3.connect(db)

def fields(record_id):
    return dict(
        con.execute(
            "select key, raw_value from record_fields where record_id = ?",
            (record_id,),
        ).fetchall()
    )

def record_by_op(op):
    rows = con.execute(
        """
        select records.id
        from records
        join record_fields on record_fields.record_id = records.id
        where record_fields.key = 'op' and record_fields.raw_value = ?
        order by records.id
        """,
        (op,),
    ).fetchall()
    assert len(rows) == 1, (op, rows)
    return rows[0][0]

create_record = record_by_op("json-fail-create")
create_timeout_record = record_by_op("json-timeout-create")
assert fields(create_record)["status"] == "committed", fields(create_record)
assert fields(set_record)["status"] == "done", fields(set_record)
assert "flag" not in fields(unset_record), fields(unset_record)
assert fields(timeout_record)["status"] == "timeout", fields(timeout_record)
assert fields(create_timeout_record)["status"] == "committed", fields(create_timeout_record)
assert con.execute("select count(*) from records where id = ?", (rm_record,)).fetchone()[0] == 0
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (link_source, link_target),
).fetchone()[0] == 1
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (unlink_source, unlink_target),
).fetchone()[0] == 0

event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where id > ?
    order by id
    """,
    (event_marker,),
).fetchall()
assert Counter(row[0] for row in event_rows) == {
    "create": 2,
    "set": 2,
    "unset": 1,
    "rm": 1,
    "link": 1,
    "unlink": 1,
}, event_rows
assert ("create", create_record) in event_rows, event_rows
assert ("set", set_record) in event_rows, event_rows
assert ("unset", unset_record) in event_rows, event_rows
assert ("rm", rm_record) in event_rows, event_rows
assert ("link", link_source) in event_rows, event_rows
assert ("unlink", unlink_source) in event_rows, event_rows
assert ("set", timeout_record) in event_rows, event_rows
assert ("create", create_timeout_record) in event_rows, event_rows

hook_ids = [
    create_hook_id,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    link_hook_id,
    unlink_hook_id,
    timeout_hook_id,
    create_timeout_hook_id,
]
placeholders = ",".join("?" for _ in hook_ids)
rows = con.execute(
    f"""
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ? and hook_id in ({placeholders})
    order by id
    """,
    [hook_marker, *hook_ids],
).fetchall()
assert len(rows) == len(hook_ids), rows
by_hook = {row[0]: row[1:] for row in rows}
expected_failures = {
    create_hook_id: ("create", create_record, 31, "create-failure-stdout", "create-failure-stderr"),
    set_hook_id: ("set", set_record, 31, "set-failure-stdout", "set-failure-stderr"),
    unset_hook_id: ("unset", unset_record, 31, "unset-failure-stdout", "unset-failure-stderr"),
    rm_hook_id: ("rm", rm_record, 31, "rm-failure-stdout", "rm-failure-stderr"),
    link_hook_id: ("link", link_source, 31, "link-failure-stdout", "link-failure-stderr"),
    unlink_hook_id: ("unlink", unlink_source, 31, "unlink-failure-stdout", "unlink-failure-stderr"),
}
for hook_id, expected in expected_failures.items():
    assert by_hook[hook_id] == expected, (hook_id, by_hook[hook_id], expected)

timeout_row = by_hook[timeout_hook_id]
assert timeout_row[:4] == ("set", timeout_record, -1, ""), timeout_row
assert "set-timeout-stderr" in timeout_row[4], timeout_row
assert "timed out after 30 seconds" in timeout_row[4], timeout_row

create_timeout_row = by_hook[create_timeout_hook_id]
assert create_timeout_row[:4] == ("create", create_timeout_record, -1, ""), create_timeout_row
assert "create-timeout-stderr" in create_timeout_row[4], create_timeout_row
assert "timed out after 30 seconds" in create_timeout_row[4], create_timeout_row

print(
    "json_failures=6 json_timeouts=2 stdout_empty=8 hook_runs={} events={} create_record={} create_timeout_record={}".format(
        len(rows),
        len(event_rows),
        create_record,
        create_timeout_record,
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'json-hook-*' -o -name 'fail-hook.sh' -o -name 'timeout-hook.sh' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/json-mutation-hook-failure-timeout.md" <<EOF
# JSON Mutation Hook Failure/Timeout Evidence

- set_record: $set_record
- unset_record: $unset_record
- rm_record: $rm_record
- link_source: $link_source
- link_target: $link_target
- unlink_source: $unlink_source
- unlink_target: $unlink_target
- timeout_record: $timeout_record
- failing_hook_ids: $create_hook_id $set_hook_id $unset_hook_id $rm_hook_id $link_hook_id $unlink_hook_id
- timeout_hook_ids: $timeout_hook_id $create_timeout_hook_id
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  json_multiple_matching_hooks_stop_after_failure_or_timeout)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-json-multi-hook-9ev-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    cat > multi-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

scenario="$1"
mode="$2"
state_dir="multi-state"
mkdir -p "$state_dir"
count_file="$state_dir/$scenario.count"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf "%s" "$count" >"$count_file"

printf "%s count=%s event=%s id=%s rel=%s target=%s\n" \
  "$scenario" \
  "$count" \
  "${AGENT_STORE_EVENT:-}" \
  "${AGENT_STORE_ID:-}" \
  "${AGENT_STORE_REL:-}" \
  "${AGENT_STORE_TARGET_ID:-}" >>"$state_dir/invocations.log"

if [ "$count" -le 2 ]; then
  printf "%s-success-%s-stdout" "$scenario" "$count"
  printf "%s-success-%s-stderr" "$scenario" "$count" >&2
  exit 0
fi

if [ "$count" -eq 3 ]; then
  if [ "$mode" = "timeout" ]; then
    printf "%s-timeout-stderr" "$scenario" >&2
    while :; do
      sleep 1
    done
  fi

  printf "%s-failure-stdout" "$scenario"
  printf "%s-failure-stderr" "$scenario" >&2
  exit 41
fi

printf "%s-after-failure-ran" "$scenario" >"$state_dir/$scenario.after-failure-ran"
printf "%s-late-stdout" "$scenario"
SH
    chmod +x multi-hook.sh

    add_multi_hooks() {
      local event="$1"
      local query="$2"
      local scenario="$3"
      local mode="$4"
      local ids=""
      local hook_id

      for _ in 1 2 3 4; do
        hook_id="$("$agent_store_bin" hook add "$event" "$query" -- "./multi-hook.sh $scenario $mode")"
        ids="${ids}${ids:+,}$hook_id"
      done

      printf "%s" "$ids"
    }

    set_record="$("$agent_store_bin" create task op=json-multi-set status=pending)"
    unset_record="$("$agent_store_bin" create task op=json-multi-unset flag=present status=pending)"
    rm_record="$("$agent_store_bin" create task op=json-multi-rm action=remove status=open)"
    link_source="$("$agent_store_bin" create task op=json-multi-link-timeout status=open)"
    link_target="$("$agent_store_bin" create note op=json-multi-link-target status=open)"
    unlink_source="$("$agent_store_bin" create task op=json-multi-unlink status=open)"
    unlink_target="$("$agent_store_bin" create note op=json-multi-unlink-target status=open)"
    "$agent_store_bin" link "$unlink_source" blocks "$unlink_target" >/tmp/agent-store-json-multi-hook-9ev-seed-unlink.out

    create_hook_ids="$(add_multi_hooks create 'kind=task and op=json-multi-create-fail' create-fail fail)"
    set_hook_ids="$(add_multi_hooks set 'kind=task and op=json-multi-set and status=done' set-fail fail)"
    unset_hook_ids="$(add_multi_hooks unset 'kind=task and op=json-multi-unset and not flag=present' unset-fail fail)"
    rm_hook_ids="$(add_multi_hooks rm 'kind=task and op=json-multi-rm and action=remove' rm-timeout timeout)"
    link_hook_ids="$(add_multi_hooks link 'kind=task and op=json-multi-link-timeout' link-timeout timeout)"
    unlink_hook_ids="$(add_multi_hooks unlink 'kind=task and op=json-multi-unlink' unlink-fail fail)"

    event_marker="$(python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
print(con.execute("select coalesce(max(id), 0) from store_events").fetchone()[0])
PY
)"
    hook_marker="$(python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
print(con.execute("select coalesce(max(id), 0) from hook_runs").fetchone()[0])
PY
)"

    run_json_multi_failure() {
      local name="$1"
      local expected_stderr="$2"
      shift 2
      set +e
      "$agent_store_bin" --json "$@" >"$tmp/json-multi-$name.out" 2>"$tmp/json-multi-$name.err"
      local status="$?"
      set -e
      printf "%s" "$status" >"$tmp/json-multi-$name.status"
      test "$status" -ne 0
      test ! -s "$tmp/json-multi-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/json-multi-$name.err"
      grep -Fq "exit status 41" "$tmp/json-multi-$name.err"
      grep -Fq "$expected_stderr" "$tmp/json-multi-$name.err"
    }

    run_json_multi_timeout() {
      local name="$1"
      local expected_stderr="$2"
      shift 2
      set +e
      timeout 40s "$agent_store_bin" --json "$@" >"$tmp/json-multi-$name.out" 2>"$tmp/json-multi-$name.err"
      local status="$?"
      set -e
      printf "%s" "$status" >"$tmp/json-multi-$name.status"
      test "$status" -ne 0
      test "$status" -ne 124
      test ! -s "$tmp/json-multi-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/json-multi-$name.err"
      grep -Fq "timed out after 30 seconds" "$tmp/json-multi-$name.err"
      grep -Fq "$expected_stderr" "$tmp/json-multi-$name.err"
    }

    run_json_multi_failure create create-fail-failure-stderr create task op=json-multi-create-fail status=committed
    run_json_multi_failure set set-fail-failure-stderr set "$set_record" status=done
    run_json_multi_failure unset unset-fail-failure-stderr unset "$unset_record" flag
    run_json_multi_timeout rm-timeout rm-timeout-timeout-stderr rm "$rm_record"
    run_json_multi_timeout link-timeout link-timeout-timeout-stderr link "$link_source" blocks "$link_target"
    run_json_multi_failure unlink unlink-fail-failure-stderr unlink "$unlink_source" blocks "$unlink_target"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$set_record" \
      "$unset_record" \
      "$rm_record" \
      "$link_source" \
      "$link_target" \
      "$unlink_source" \
      "$unlink_target" \
      "$create_hook_ids" \
      "$set_hook_ids" \
      "$unset_hook_ids" \
      "$rm_hook_ids" \
      "$link_hook_ids" \
      "$unlink_hook_ids" <<'PY'
from collections import Counter
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    event_marker_s,
    hook_marker_s,
    set_record,
    unset_record,
    rm_record,
    link_source,
    link_target,
    unlink_source,
    unlink_target,
    create_hook_ids_s,
    set_hook_ids_s,
    unset_hook_ids_s,
    rm_hook_ids_s,
    link_hook_ids_s,
    unlink_hook_ids_s,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)

for name, expected in [
    ("create", "create-fail-failure-stderr"),
    ("set", "set-fail-failure-stderr"),
    ("unset", "unset-fail-failure-stderr"),
    ("rm-timeout", "rm-timeout-timeout-stderr"),
    ("link-timeout", "link-timeout-timeout-stderr"),
    ("unlink", "unlink-fail-failure-stderr"),
]:
    stdout = (tmp / f"json-multi-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"json-multi-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"json-multi-{name}.status").read_text(encoding="utf-8"))
    assert stdout == "", (name, stdout)
    assert status != 0, (name, status)
    assert "Store mutation already committed" in stderr, (name, stderr)
    assert expected in stderr, (name, stderr)
    if name.endswith("-timeout"):
        assert status != 124, status
        assert "timed out after 30 seconds" in stderr, stderr
    else:
        assert "exit status 41" in stderr, (name, stderr)

con = sqlite3.connect(db)

def fields(record_id):
    return dict(
        con.execute(
            "select key, raw_value from record_fields where record_id = ?",
            (record_id,),
        ).fetchall()
    )

def record_by_op(op):
    rows = con.execute(
        """
        select records.id
        from records
        join record_fields on record_fields.record_id = records.id
        where record_fields.key = 'op' and record_fields.raw_value = ?
        order by records.id
        """,
        (op,),
    ).fetchall()
    assert len(rows) == 1, (op, rows)
    return rows[0][0]

create_record = record_by_op("json-multi-create-fail")
assert fields(create_record)["status"] == "committed", fields(create_record)
assert fields(set_record)["status"] == "done", fields(set_record)
assert "flag" not in fields(unset_record), fields(unset_record)
assert con.execute(
    "select count(*) from records where id = ?",
    (rm_record,),
).fetchone()[0] == 0
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (link_source, link_target),
).fetchone()[0] == 1
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (unlink_source, unlink_target),
).fetchone()[0] == 0

event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where id > ?
    order by id
    """,
    (event_marker,),
).fetchall()
assert Counter(row[0] for row in event_rows) == {
    "create": 1,
    "set": 1,
    "unset": 1,
    "rm": 1,
    "link": 1,
    "unlink": 1,
}, event_rows
assert ("create", create_record) in event_rows, event_rows
assert ("set", set_record) in event_rows, event_rows
assert ("unset", unset_record) in event_rows, event_rows
assert ("rm", rm_record) in event_rows, event_rows
assert ("link", link_source) in event_rows, event_rows
assert ("unlink", unlink_source) in event_rows, event_rows

def split_ids(ids):
    values = [value for value in ids.split(",") if value]
    assert len(values) == 4, values
    return sorted(values)

scenarios = [
    {
        "name": "create-fail",
        "ids": split_ids(create_hook_ids_s),
        "event": "create",
        "record": create_record,
        "mode": "fail",
    },
    {
        "name": "set-fail",
        "ids": split_ids(set_hook_ids_s),
        "event": "set",
        "record": set_record,
        "mode": "fail",
    },
    {
        "name": "unset-fail",
        "ids": split_ids(unset_hook_ids_s),
        "event": "unset",
        "record": unset_record,
        "mode": "fail",
    },
    {
        "name": "rm-timeout",
        "ids": split_ids(rm_hook_ids_s),
        "event": "rm",
        "record": rm_record,
        "mode": "timeout",
    },
    {
        "name": "link-timeout",
        "ids": split_ids(link_hook_ids_s),
        "event": "link",
        "record": link_source,
        "mode": "timeout",
    },
    {
        "name": "unlink-fail",
        "ids": split_ids(unlink_hook_ids_s),
        "event": "unlink",
        "record": unlink_source,
        "mode": "fail",
    },
]

all_hook_ids = [hook_id for scenario in scenarios for hook_id in scenario["ids"]]
placeholders = ",".join("?" for _ in all_hook_ids)
rows = con.execute(
    f"""
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ? and hook_id in ({placeholders})
    order by id
    """,
    [hook_marker, *all_hook_ids],
).fetchall()
by_hook = {row[0]: row[1:] for row in rows}
assert len(rows) == 18, rows

for scenario in scenarios:
    name = scenario["name"]
    ids = scenario["ids"]
    expected_run_ids = ids[:3]
    actual_run_ids = [hook_id for hook_id in ids if hook_id in by_hook]
    assert actual_run_ids == expected_run_ids, (name, ids, actual_run_ids)
    assert ids[3] not in by_hook, (name, ids[3], by_hook.get(ids[3]))

    for index, hook_id in enumerate(ids[:2], start=1):
        assert by_hook[hook_id] == (
            scenario["event"],
            scenario["record"],
            0,
            f"{name}-success-{index}-stdout",
            f"{name}-success-{index}-stderr",
        ), (name, hook_id, by_hook[hook_id])

    failing_row = by_hook[ids[2]]
    if scenario["mode"] == "timeout":
        assert failing_row[:4] == (scenario["event"], scenario["record"], -1, ""), failing_row
        assert f"{name}-timeout-stderr" in failing_row[4], failing_row
        assert "timed out after 30 seconds" in failing_row[4], failing_row
    else:
        assert failing_row == (
            scenario["event"],
            scenario["record"],
            41,
            f"{name}-failure-stdout",
            f"{name}-failure-stderr",
        ), (name, failing_row)

    count_text = (tmp / "multi-state" / f"{name}.count").read_text(encoding="utf-8")
    assert count_text == "3", (name, count_text)
    assert not (tmp / "multi-state" / f"{name}.after-failure-ran").exists(), name

log_lines = (tmp / "multi-state" / "invocations.log").read_text(encoding="utf-8").splitlines()
for scenario in scenarios:
    scenario_lines = [line for line in log_lines if line.startswith(f"{scenario['name']} ")]
    assert len(scenario_lines) == 3, (scenario["name"], scenario_lines)

print(
    "multi_hook_json_cases=6 hook_runs={} skipped_later_hooks=6 events={} create_record={} set_record={} unset_record={} rm_record={} link_source={} unlink_source={}".format(
        len(rows),
        len(event_rows),
        create_record,
        set_record,
        unset_record,
        rm_record,
        link_source,
        unlink_source,
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'json-multi-*' -o -name 'multi-hook.sh' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp -R "$tmp/multi-state" "$evidence_root/logs/"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/json-multiple-matching-hooks.md" <<EOF
# JSON Multiple Matching Hook Failure/Timeout Evidence

- set_record: $set_record
- unset_record: $unset_record
- rm_record: $rm_record
- link_source: $link_source
- link_target: $link_target
- unlink_source: $unlink_source
- unlink_target: $unlink_target
- create_hook_ids: $create_hook_ids
- set_hook_ids: $set_hook_ids
- unset_hook_ids: $unset_hook_ids
- rm_hook_ids: $rm_hook_ids
- link_hook_ids: $link_hook_ids
- unlink_hook_ids: $unlink_hook_ids
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  hooks_run_sequentially_from_project_root_with_timeout)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-runtime-4as-init.out

    mkdir -p "$tmp/bin" "$tmp/subdir"
    cat > "$tmp/bin/agent-store" <<SH
#!/usr/bin/env bash
exec "$target_dir/debug/agent-store" "\$@"
SH
    chmod +x "$tmp/bin/agent-store"
    export PATH="$tmp/bin:$PATH"

    cat > hook-sequence.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
root="$(pwd)"
test -d .agent-store
if test -e hook-running; then
  printf "overlap:%s\n" "$name" >> hook-sequence.log
fi
touch hook-running
printf "%s:start:%s\n" "$name" "$root" >> hook-sequence.log
sleep 0.2
printf "%s:end:%s\n" "$name" "$root" >> hook-sequence.log
rm hook-running
printf "%s" "$name"
SH
    chmod +x hook-sequence.sh

    first_hook_id="$(run_agent_store hook add create title=Sequential -- './hook-sequence.sh first')"
    second_hook_id="$(run_agent_store hook add create title=Sequential -- './hook-sequence.sh second')"

    cd "$tmp/subdir"
    sequential_record_id="$(run_agent_store create task title=Sequential)"
    cd "$tmp"

    test ! -e "$tmp/subdir/hook-sequence.log"
    python3 - "$tmp" "$first_hook_id" "$second_hook_id" "$sequential_record_id" <<'PY'
import pathlib
import sqlite3
import sys

root, first_hook_id, second_hook_id, record_id = sys.argv[1:]
root_path = pathlib.Path(root).resolve()
lines = (root_path / "hook-sequence.log").read_text().splitlines()
assert "overlap:first" not in lines, lines
assert "overlap:second" not in lines, lines
assert len(lines) == 4, lines

for index in (0, 2):
    start_name, start_marker, start_root = lines[index].split(":", 2)
    end_name, end_marker, end_root = lines[index + 1].split(":", 2)
    assert start_marker == "start", lines
    assert end_marker == "end", lines
    assert start_name == end_name, lines
    assert pathlib.Path(start_root).resolve() == root_path, lines
    assert pathlib.Path(end_root).resolve() == root_path, lines

seen = {lines[0].split(":", 1)[0], lines[2].split(":", 1)[0]}
assert seen == {"first", "second"}, lines

con = sqlite3.connect(root_path / ".agent-store/store.sqlite")
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
expected = {
    (first_hook_id, "create", record_id, 0, "first", ""),
    (second_hook_id, "create", record_id, 0, "second", ""),
}
assert set(rows) == expected, rows
PY

    timeout_hook_id="$(run_agent_store hook add create title=Timeout -- 'printf hook-timeout-stderr >&2; while :; do sleep 1; done')"

    cd "$tmp/subdir"
    started_at="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"
    set +e
    timeout 40s "$target_dir/debug/agent-store" create task title=Timeout >/tmp/agent-store-hook-timeout-4as.out 2>/tmp/agent-store-hook-timeout-4as.err
    timeout_status=$?
    set -e
    ended_at="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"
    cd "$tmp"

    test "$timeout_status" -ne 0
    test "$timeout_status" -ne 124
    grep -Fq "timed out after 30 seconds" /tmp/agent-store-hook-timeout-4as.err

    python3 - "$started_at" "$ended_at" ".agent-store/store.sqlite" "$timeout_hook_id" <<'PY'
import sqlite3
import sys

started_at, ended_at, db, timeout_hook_id = sys.argv[1:]
elapsed = float(ended_at) - float(started_at)
assert 28 <= elapsed <= 38, elapsed

con = sqlite3.connect(db)
timeout_record = con.execute(
    """
    select records.id
    from records
    join record_fields on record_fields.record_id = records.id
    where records.kind = 'task'
      and record_fields.key = 'title'
      and record_fields.raw_value = 'Timeout'
    """
).fetchone()
assert timeout_record is not None
record_id = timeout_record[0]
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id = ?
    order by id
    """,
    (timeout_hook_id,),
).fetchall()
assert len(rows) == 1, rows
hook_id, event_type, run_record_id, exit_status, stdout_summary, stderr_summary = rows[0]
assert hook_id == timeout_hook_id, rows
assert event_type == "create", rows
assert run_record_id == record_id, rows
assert exit_status == -1, rows
assert stdout_summary == "", rows
assert "hook-timeout-stderr" in stderr_summary, rows
assert "timed out after 30 seconds" in stderr_summary, rows
PY
    ;;

  hook_env_vars_for_record_events)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-env-vun-init.out

    cat > hook-env.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
label="$1"
printf "%s:%s:%s:%s\n" "$label" "$AGENT_STORE_EVENT" "$AGENT_STORE_ID" "$AGENT_STORE_KIND" >> hook-env.log
printf "%s" "$label"
SH
    chmod +x hook-env.sh

    create_hook_id="$(run_agent_store hook add create -- './hook-env.sh create')"
    record_id="$(run_agent_store create task title=Env status=new flag=keep)"

    set_hook_id="$(run_agent_store hook add set -- './hook-env.sh set')"
    run_agent_store set "$record_id" status=done >/tmp/agent-store-hook-env-vun-set.out

    unset_hook_id="$(run_agent_store hook add unset -- './hook-env.sh unset')"
    run_agent_store unset "$record_id" flag >/tmp/agent-store-hook-env-vun-unset.out

    rm_hook_id="$(run_agent_store hook add rm -- './hook-env.sh rm')"
    run_agent_store rm "$record_id" >/tmp/agent-store-hook-env-vun-rm.out

    expected_log="$(
      printf "create:create:%s:task\n" "$record_id"
      printf "set:set:%s:task\n" "$record_id"
      printf "unset:unset:%s:task\n" "$record_id"
      printf "rm:rm:%s:task\n" "$record_id"
    )"
    test "$(cat hook-env.log)" = "$expected_log"

    python3 - .agent-store/store.sqlite \
      "$create_hook_id" \
      "$set_hook_id" \
      "$unset_hook_id" \
      "$rm_hook_id" \
      "$record_id" <<'PY'
import sqlite3
import sys

(
    db,
    create_hook_id,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    record_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (create_hook_id, "create", record_id, 0, "create", ""),
    (set_hook_id, "set", record_id, 0, "set", ""),
    (unset_hook_id, "unset", record_id, 0, "unset", ""),
    (rm_hook_id, "rm", record_id, 0, "rm", ""),
], rows
PY
    ;;

  link_hook_query_source_and_relation_env)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-link-env-pxx-init.out

    cat > link-hook-env.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
label="$1"
printf "%s:%s:%s:%s:%s:%s\n" "$label" "$AGENT_STORE_EVENT" "$AGENT_STORE_ID" "$AGENT_STORE_KIND" "$AGENT_STORE_REL" "$AGENT_STORE_TARGET_ID" >> link-hook-env.log
printf "%s" "$label"
SH
    chmod +x link-hook-env.sh

    source_id="$(run_agent_store create task title=Source status=open)"
    target_id="$(run_agent_store create note title=Target status=open)"

    link_hook_id="$(run_agent_store hook add link 'kind=task and status=open' -- './link-hook-env.sh link')"
    link_skip_id="$(run_agent_store hook add link 'kind=note' -- './link-hook-env.sh link-skip')"
    unlink_hook_id="$(run_agent_store hook add unlink 'kind=task and status=open' -- './link-hook-env.sh unlink')"
    unlink_skip_id="$(run_agent_store hook add unlink 'kind=note' -- './link-hook-env.sh unlink-skip')"

    run_agent_store link "$source_id" blocks "$target_id" >/tmp/agent-store-hook-link-env-pxx-link.out
    run_agent_store unlink "$source_id" blocks "$target_id" >/tmp/agent-store-hook-link-env-pxx-unlink.out

    expected_log="$(
      printf "link:link:%s:task:blocks:%s\n" "$source_id" "$target_id"
      printf "unlink:unlink:%s:task:blocks:%s\n" "$source_id" "$target_id"
    )"
    test "$(cat link-hook-env.log)" = "$expected_log"

    python3 - .agent-store/store.sqlite \
      "$link_hook_id" \
      "$link_skip_id" \
      "$unlink_hook_id" \
      "$unlink_skip_id" \
      "$source_id" <<'PY'
import sqlite3
import sys

(
    db,
    link_hook_id,
    link_skip_id,
    unlink_hook_id,
    unlink_skip_id,
    source_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (link_hook_id, "link", source_id, 0, "link", ""),
    (unlink_hook_id, "unlink", source_id, 0, "unlink", ""),
], rows
skipped = {link_skip_id, unlink_skip_id}
assert not any(row[0] in skipped for row in rows), rows
PY
    ;;

  hook_output_capture_caps_and_help)
    cd "$tmp"
    run_agent_store --help >/tmp/agent-store-hook-caps-lc1-help.out
    grep -Fq "Hook stdout and stderr captures are capped at 8192 bytes each." /tmp/agent-store-hook-caps-lc1-help.out

    run_agent_store init >/tmp/agent-store-hook-caps-lc1-init.out

    cat > verbose-hook.py <<'PY'
import sys

sys.stdout.write("O" * 9000)
sys.stderr.write("E" * 9000)
PY

    hook_id="$(run_agent_store hook add create -- 'python3 verbose-hook.py')"
    record_id="$(run_agent_store create task title=Verbose)"
    printf "%s\n" "$record_id" | grep -Eq "^[a-z0-9]{6,8}$"

    python3 - .agent-store/store.sqlite "$hook_id" "$record_id" <<'PY'
import sqlite3
import sys

db, hook_id, record_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
assert rows == [
    (hook_id, "create", record_id, 0, "O" * 8192, "E" * 8192),
], (len(rows[0][4]) if rows else None, len(rows[0][5]) if rows else None, rows[:1])
PY
    ;;

  *)
    echo "usage: $0 {hook_add_stores_metadata|hook_ls_deterministic|hook_rm_deletes_metadata|hooks_run_after_commit|hook_query_filters_records|hook_query_uses_mutation_snapshot|hook_stdin_receives_record_snapshot|hook_failure_reports_details|hook_failure_or_timeout_reports_committed_mutation|json_mutation_hook_failure_or_timeout_reports_committed_without_success_json|json_multiple_matching_hooks_stop_after_failure_or_timeout|hooks_run_sequentially_from_project_root_with_timeout|hook_env_vars_for_record_events|link_hook_query_source_and_relation_env|hook_output_capture_caps_and_help}" >&2
    exit 2
    ;;
esac
