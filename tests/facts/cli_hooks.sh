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

  hook_command_launch_or_execution_failure_reports_committed_mutation)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-exec-7r8-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    json_record="$("$agent_store_bin" create task title=InvalidHookCommand status=pending)"
    missing_command='./definitely-missing-hook-executable'
    invalid_command='if then'

    missing_hook_id="$("$agent_store_bin" hook add create title=MissingHookExecutable -- "$missing_command")"
    invalid_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=InvalidHookCommand and status=done' -- "$invalid_command")"

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

    set +e
    "$agent_store_bin" create task title=MissingHookExecutable >"$tmp/hook-exec-missing.out" 2>"$tmp/hook-exec-missing.err"
    missing_status="$?"
    "$agent_store_bin" --json set "$json_record" status=done >"$tmp/hook-exec-json-invalid.out" 2>"$tmp/hook-exec-json-invalid.err"
    invalid_status="$?"
    set -e
    printf "%s" "$missing_status" >"$tmp/hook-exec-missing.status"
    printf "%s" "$invalid_status" >"$tmp/hook-exec-json-invalid.status"

    test "$missing_status" -ne 0
    test ! -s "$tmp/hook-exec-missing.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-exec-missing.err"
    grep -Fq "hook $missing_hook_id" "$tmp/hook-exec-missing.err"
    grep -Fq "$missing_command" "$tmp/hook-exec-missing.err"
    grep -Fq "exit status 127" "$tmp/hook-exec-missing.err"
    grep -Fq "definitely-missing-hook-executable" "$tmp/hook-exec-missing.err"

    test "$invalid_status" -ne 0
    test ! -s "$tmp/hook-exec-json-invalid.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-exec-json-invalid.err"
    grep -Fq "hook $invalid_hook_id" "$tmp/hook-exec-json-invalid.err"
    grep -Fq "$invalid_command" "$tmp/hook-exec-json-invalid.err"
    grep -Fq "exit status 2" "$tmp/hook-exec-json-invalid.err"
    grep -Fq "syntax error" "$tmp/hook-exec-json-invalid.err"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$json_record" \
      "$missing_hook_id" \
      "$invalid_hook_id" <<'PY'
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    event_marker_s,
    hook_marker_s,
    json_record,
    missing_hook_id,
    invalid_hook_id,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)
con = sqlite3.connect(db)

for name, expected in [
    ("missing", "definitely-missing-hook-executable"),
    ("json-invalid", "syntax error"),
]:
    stdout = (tmp / f"hook-exec-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"hook-exec-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"hook-exec-{name}.status").read_text(encoding="utf-8"))
    assert stdout == "", (name, stdout)
    assert status != 0, (name, status)
    assert "Store mutation already committed" in stderr, (name, stderr)
    assert expected in stderr, (name, stderr)

plain_record_row = con.execute(
    """
    select records.id
    from records
    join record_fields on record_fields.record_id = records.id
    where records.kind = 'task'
      and record_fields.key = 'title'
      and record_fields.raw_value = 'MissingHookExecutable'
    """
).fetchone()
assert plain_record_row is not None
plain_record = plain_record_row[0]

json_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ? and key = 'status'
    """,
    (json_record,),
).fetchone()
assert json_status == ("done",), json_status

event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where id > ?
    order by id
    """,
    (event_marker,),
).fetchall()
assert event_rows == [
    ("create", plain_record),
    ("set", json_record),
], event_rows

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ? and hook_id in (?, ?)
    order by id
    """,
    (hook_marker, missing_hook_id, invalid_hook_id),
).fetchall()
assert len(rows) == 2, rows
assert rows[0][:5] == (
    missing_hook_id,
    "create",
    plain_record,
    127,
    "",
), rows[0]
assert "definitely-missing-hook-executable" in rows[0][5], rows[0]
assert rows[1][:5] == (
    invalid_hook_id,
    "set",
    json_record,
    2,
    "",
), rows[1]
assert "syntax error" in rows[1][5], rows[1]

print(
    "hook_execution_failures=2 plain_record={} json_record={} statuses={}".format(
        plain_record,
        json_record,
        ",".join(str(row[3]) for row in rows),
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      cp "$tmp"/hook-exec-* "$evidence_root/logs/"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/hook-command-execution-failure.md" <<EOF
# Hook Command Execution Failure Evidence

- missing_hook_id: $missing_hook_id
- invalid_hook_id: $invalid_hook_id
- missing_status: $missing_status
- invalid_status: $invalid_status
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
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
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    mkdir -p "$tmp/bin" "$tmp/subdir"
    cat > "$tmp/bin/agent-store" <<SH
#!/usr/bin/env bash
exec "$agent_store_bin" "\$@"
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

    cat > plain-multi-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

scenario="$1"
mode="$2"
state_dir="plain-multi-state"
mkdir -p "$state_dir"
count_file="$state_dir/$scenario.count"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf "%s" "$count" >"$count_file"

test -d .agent-store
printf "%s count=%s event=%s id=%s rel=%s target=%s root=%s\n" \
  "$scenario" \
  "$count" \
  "${AGENT_STORE_EVENT:-}" \
  "${AGENT_STORE_ID:-}" \
  "${AGENT_STORE_REL:-}" \
  "${AGENT_STORE_TARGET_ID:-}" \
  "$(pwd)" >>"$state_dir/invocations.log"

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
    chmod +x plain-multi-hook.sh

    add_plain_multi_hooks() {
      local event="$1"
      local query="$2"
      local scenario="$3"
      local mode="$4"
      local ids=""
      local hook_id

      for _ in 1 2 3 4; do
        hook_id="$("$agent_store_bin" hook add "$event" "$query" -- "./plain-multi-hook.sh $scenario $mode")"
        ids="${ids}${ids:+,}$hook_id"
      done

      printf "%s" "$ids"
    }

    plain_set_record="$("$agent_store_bin" create task op=plain-multi-set status=pending)"
    plain_unset_record="$("$agent_store_bin" create task op=plain-multi-unset flag=present status=pending)"
    plain_rm_record="$("$agent_store_bin" create task op=plain-multi-rm action=remove status=open)"
    plain_link_source="$("$agent_store_bin" create task op=plain-multi-link status=open)"
    plain_link_target="$("$agent_store_bin" create note op=plain-multi-link-target status=open)"
    plain_unlink_source="$("$agent_store_bin" create task op=plain-multi-unlink status=open)"
    plain_unlink_target="$("$agent_store_bin" create note op=plain-multi-unlink-target status=open)"
    "$agent_store_bin" link "$plain_unlink_source" blocks "$plain_unlink_target" >/tmp/agent-store-plain-multi-hook-4as-seed-unlink.out

    plain_create_hook_ids="$(add_plain_multi_hooks create 'kind=task and op=plain-multi-create-fail' create-fail fail)"
    plain_set_hook_ids="$(add_plain_multi_hooks set 'kind=task and op=plain-multi-set and status=done' set-fail fail)"
    plain_unset_hook_ids="$(add_plain_multi_hooks unset 'kind=task and op=plain-multi-unset and not flag=present' unset-fail fail)"
    plain_rm_hook_ids="$(add_plain_multi_hooks rm 'kind=task and op=plain-multi-rm and action=remove' rm-timeout timeout)"
    plain_link_hook_ids="$(add_plain_multi_hooks link 'kind=task and op=plain-multi-link' link-timeout timeout)"
    plain_unlink_hook_ids="$(add_plain_multi_hooks unlink 'kind=task and op=plain-multi-unlink' unlink-fail fail)"

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

    run_plain_multi_failure() {
      local name="$1"
      local expected_stderr="$2"
      shift 2
      set +e
      "$agent_store_bin" "$@" >"$tmp/plain-multi-$name.out" 2>"$tmp/plain-multi-$name.err"
      local status="$?"
      set -e
      printf "%s" "$status" >"$tmp/plain-multi-$name.status"
      test "$status" -ne 0
      test ! -s "$tmp/plain-multi-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/plain-multi-$name.err"
      grep -Fq "exit status 41" "$tmp/plain-multi-$name.err"
      grep -Fq "$expected_stderr" "$tmp/plain-multi-$name.err"
    }

    run_plain_multi_timeout() {
      local name="$1"
      local expected_stderr="$2"
      shift 2
      set +e
      timeout 40s "$agent_store_bin" "$@" >"$tmp/plain-multi-$name.out" 2>"$tmp/plain-multi-$name.err"
      local status="$?"
      set -e
      printf "%s" "$status" >"$tmp/plain-multi-$name.status"
      test "$status" -ne 0
      test "$status" -ne 124
      test ! -s "$tmp/plain-multi-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/plain-multi-$name.err"
      grep -Fq "timed out after 30 seconds" "$tmp/plain-multi-$name.err"
      grep -Fq "$expected_stderr" "$tmp/plain-multi-$name.err"
    }

    run_plain_multi_failure create create-fail-failure-stderr create task op=plain-multi-create-fail status=committed
    run_plain_multi_failure set set-fail-failure-stderr set "$plain_set_record" status=done
    run_plain_multi_failure unset unset-fail-failure-stderr unset "$plain_unset_record" flag
    run_plain_multi_timeout rm-timeout rm-timeout-timeout-stderr rm "$plain_rm_record"
    run_plain_multi_timeout link-timeout link-timeout-timeout-stderr link "$plain_link_source" blocks "$plain_link_target"
    run_plain_multi_failure unlink unlink-fail-failure-stderr unlink "$plain_unlink_source" blocks "$plain_unlink_target"

    plain_multi_summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$plain_set_record" \
      "$plain_unset_record" \
      "$plain_rm_record" \
      "$plain_link_source" \
      "$plain_link_target" \
      "$plain_unlink_source" \
      "$plain_unlink_target" \
      "$plain_create_hook_ids" \
      "$plain_set_hook_ids" \
      "$plain_unset_hook_ids" \
      "$plain_rm_hook_ids" \
      "$plain_link_hook_ids" \
      "$plain_unlink_hook_ids" <<'PY'
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
    stdout = (tmp / f"plain-multi-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"plain-multi-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"plain-multi-{name}.status").read_text(encoding="utf-8"))
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

create_record = record_by_op("plain-multi-create-fail")
assert fields(create_record)["status"] == "committed", fields(create_record)
assert fields(set_record)["status"] == "done", fields(set_record)
assert "flag" not in fields(unset_record), fields(unset_record)
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

    count_text = (tmp / "plain-multi-state" / f"{name}.count").read_text(encoding="utf-8")
    assert count_text == "3", (name, count_text)
    assert not (tmp / "plain-multi-state" / f"{name}.after-failure-ran").exists(), name

log_lines = (tmp / "plain-multi-state" / "invocations.log").read_text(encoding="utf-8").splitlines()
for scenario in scenarios:
    scenario_lines = [line for line in log_lines if line.startswith(f"{scenario['name']} ")]
    assert len(scenario_lines) == 3, (scenario["name"], scenario_lines)

print(
    "plain_multi_hook_cases=6 hook_runs={} skipped_later_hooks=6 events={} create_record={} set_record={} unset_record={} rm_record={} link_source={} unlink_source={}".format(
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
        \( -name 'plain-multi-*' -o -name 'plain-multi-hook.sh' -o -name 'hook-sequence.log' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp -R "$tmp/plain-multi-state" "$evidence_root/logs/"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/plain-multiple-matching-hooks.md" <<EOF
# Plain CLI Multiple Matching Hook Failure/Timeout Evidence

- set_record: $plain_set_record
- unset_record: $plain_unset_record
- rm_record: $plain_rm_record
- link_source: $plain_link_source
- link_target: $plain_link_target
- unlink_source: $plain_unlink_source
- unlink_target: $plain_unlink_target
- create_hook_ids: $plain_create_hook_ids
- set_hook_ids: $plain_set_hook_ids
- unset_hook_ids: $plain_unset_hook_ids
- rm_hook_ids: $plain_rm_hook_ids
- link_hook_ids: $plain_link_hook_ids
- unlink_hook_ids: $plain_unlink_hook_ids
- $plain_multi_summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi

    timeout_hook_id="$(run_agent_store hook add create title=Timeout -- 'printf hook-timeout-stderr >&2; while :; do sleep 1; done')"

    cd "$tmp/subdir"
    started_at="$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)"
    set +e
    timeout 40s "$agent_store_bin" create task title=Timeout >/tmp/agent-store-hook-timeout-4as.out 2>/tmp/agent-store-hook-timeout-4as.err
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

  hook_failure_preserves_link_context_env)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-context-failure-06p-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    cat > fail-context-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
label="$1"
printf "%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n" \
  "$label" \
  "${AGENT_STORE_EVENT:-}" \
  "${AGENT_STORE_ID:-}" \
  "${AGENT_STORE_KIND:-}" \
  "${AGENT_STORE_REL:-}" \
  "${AGENT_STORE_TARGET_ID:-}" \
  "${AGENT_STORE_FIELD:-}" \
  "${AGENT_STORE_KEY:-}" \
  "${AGENT_STORE_VALUE:-}" \
  "${AGENT_STORE_OLD_VALUE:-}" \
  "${AGENT_STORE_NEW_VALUE:-}" >> context-env.log
printf "%s-stdout" "$label"
printf "%s-stderr" "$label" >&2
exit 33
SH
    chmod +x fail-context-hook.sh

    cat > fail-special-context-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
label="$1"
python3 - "$label" <<'PY'
import json
import os
import sys

keys = [
    "AGENT_STORE_EVENT",
    "AGENT_STORE_ID",
    "AGENT_STORE_KIND",
    "AGENT_STORE_REL",
    "AGENT_STORE_TARGET_ID",
    "AGENT_STORE_FIELD",
    "AGENT_STORE_KEY",
    "AGENT_STORE_VALUE",
    "AGENT_STORE_OLD_VALUE",
    "AGENT_STORE_NEW_VALUE",
]
row = {"label": sys.argv[1]}
row.update({key: os.environ.get(key, "") for key in keys})
with open("special-context-env.jsonl", "a", encoding="utf-8") as handle:
    json.dump(row, handle, ensure_ascii=False)
    handle.write("\n")
PY
printf "%s-stdout" "$label"
printf "%s-stderr" "$label" >&2
exit 33
SH
    chmod +x fail-special-context-hook.sh

    plain_special_old=$'old value=alpha "quoted" \\\\path\nline-old'
    plain_special_new=$'new value=beta "quoted" \\\\path\nline-new'
    json_special_old=$'unset value=gamma "quoted" \\\\path\nline-unset'

    plain_source_id="$("$agent_store_bin" create task title=PlainLinkContext status=open)"
    plain_target_id="$("$agent_store_bin" create note title=PlainLinkTarget status=open)"
    json_source_id="$("$agent_store_bin" create task title=JsonUnlinkContext status=open)"
    json_target_id="$("$agent_store_bin" create note title=JsonUnlinkTarget status=open)"
    "$agent_store_bin" link "$json_source_id" relates "$json_target_id" >/tmp/agent-store-hook-context-failure-06p-seed-link.out
    plain_set_id="$("$agent_store_bin" create task title=PlainSetContext status=pending)"
    json_unset_id="$("$agent_store_bin" create task title=JsonUnsetContext flag=remove-me status=open)"
    plain_multi_set_id="$("$agent_store_bin" create task title=PlainMultiSetContext status=pending priority=low)"
    json_multi_unset_id="$("$agent_store_bin" create task title=JsonMultiUnsetContext flag=remove-me extra=remove-too status=open)"
    plain_special_set_id="$("$agent_store_bin" create task title=PlainSpecialSetContext details="$plain_special_old")"
    json_special_unset_id="$("$agent_store_bin" create task title=JsonSpecialUnsetContext details="$json_special_old")"

    plain_hook_id="$("$agent_store_bin" hook add link 'kind=task and title=PlainLinkContext' -- './fail-context-hook.sh plain-link')"
    json_hook_id="$("$agent_store_bin" hook add unlink 'kind=task and title=JsonUnlinkContext' -- './fail-context-hook.sh json-unlink')"
    plain_set_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=PlainSetContext and status=done' -- './fail-context-hook.sh plain-set')"
    json_unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and title=JsonUnsetContext and not flag=remove-me' -- './fail-context-hook.sh json-unset-field')"
    plain_multi_set_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=PlainMultiSetContext and status=done and priority=high' -- './fail-context-hook.sh plain-set-multi')"
    json_multi_unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and title=JsonMultiUnsetContext and not flag=remove-me and not extra=remove-too' -- './fail-context-hook.sh json-unset-multi')"
    plain_special_set_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=PlainSpecialSetContext' -- './fail-special-context-hook.sh plain-set-special')"
    json_special_unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and title=JsonSpecialUnsetContext and not details=anything' -- './fail-special-context-hook.sh json-unset-special')"

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

    set +e
    "$agent_store_bin" link "$plain_source_id" blocks "$plain_target_id" >"$tmp/hook-context-plain-link.out" 2>"$tmp/hook-context-plain-link.err"
    plain_status="$?"
    set -e
    printf "%s" "$plain_status" >"$tmp/hook-context-plain-link.status"
    test "$plain_status" -ne 0
    test ! -s "$tmp/hook-context-plain-link.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-plain-link.err"
    grep -Fq "exit status 33" "$tmp/hook-context-plain-link.err"
    grep -Fq "plain-link-stderr" "$tmp/hook-context-plain-link.err"

    set +e
    "$agent_store_bin" --json unlink "$json_source_id" relates "$json_target_id" >"$tmp/hook-context-json-unlink.out" 2>"$tmp/hook-context-json-unlink.err"
    json_status="$?"
    set -e
    printf "%s" "$json_status" >"$tmp/hook-context-json-unlink.status"
    test "$json_status" -ne 0
    test ! -s "$tmp/hook-context-json-unlink.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-json-unlink.err"
    grep -Fq "exit status 33" "$tmp/hook-context-json-unlink.err"
    grep -Fq "json-unlink-stderr" "$tmp/hook-context-json-unlink.err"

    set +e
    "$agent_store_bin" set "$plain_set_id" status=done >"$tmp/hook-context-plain-set.out" 2>"$tmp/hook-context-plain-set.err"
    plain_set_status="$?"
    set -e
    printf "%s" "$plain_set_status" >"$tmp/hook-context-plain-set.status"
    test "$plain_set_status" -ne 0
    test ! -s "$tmp/hook-context-plain-set.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-plain-set.err"
    grep -Fq "exit status 33" "$tmp/hook-context-plain-set.err"
    grep -Fq "plain-set-stderr" "$tmp/hook-context-plain-set.err"

    set +e
    "$agent_store_bin" --json unset "$json_unset_id" flag >"$tmp/hook-context-json-unset.out" 2>"$tmp/hook-context-json-unset.err"
    json_unset_status="$?"
    set -e
    printf "%s" "$json_unset_status" >"$tmp/hook-context-json-unset.status"
    test "$json_unset_status" -ne 0
    test ! -s "$tmp/hook-context-json-unset.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-json-unset.err"
    grep -Fq "exit status 33" "$tmp/hook-context-json-unset.err"
    grep -Fq "json-unset-field-stderr" "$tmp/hook-context-json-unset.err"

    set +e
    "$agent_store_bin" set "$plain_multi_set_id" status=done priority=high >"$tmp/hook-context-plain-set-multi.out" 2>"$tmp/hook-context-plain-set-multi.err"
    plain_multi_set_status="$?"
    set -e
    printf "%s" "$plain_multi_set_status" >"$tmp/hook-context-plain-set-multi.status"
    test "$plain_multi_set_status" -ne 0
    test ! -s "$tmp/hook-context-plain-set-multi.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-plain-set-multi.err"
    grep -Fq "exit status 33" "$tmp/hook-context-plain-set-multi.err"
    grep -Fq "plain-set-multi-stderr" "$tmp/hook-context-plain-set-multi.err"

    set +e
    "$agent_store_bin" --json unset "$json_multi_unset_id" flag extra >"$tmp/hook-context-json-unset-multi.out" 2>"$tmp/hook-context-json-unset-multi.err"
    json_multi_unset_status="$?"
    set -e
    printf "%s" "$json_multi_unset_status" >"$tmp/hook-context-json-unset-multi.status"
    test "$json_multi_unset_status" -ne 0
    test ! -s "$tmp/hook-context-json-unset-multi.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-json-unset-multi.err"
    grep -Fq "exit status 33" "$tmp/hook-context-json-unset-multi.err"
    grep -Fq "json-unset-multi-stderr" "$tmp/hook-context-json-unset-multi.err"

    set +e
    "$agent_store_bin" set "$plain_special_set_id" details="$plain_special_new" >"$tmp/hook-context-plain-set-special.out" 2>"$tmp/hook-context-plain-set-special.err"
    plain_special_set_status="$?"
    set -e
    printf "%s" "$plain_special_set_status" >"$tmp/hook-context-plain-set-special.status"
    test "$plain_special_set_status" -ne 0
    test ! -s "$tmp/hook-context-plain-set-special.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-plain-set-special.err"
    grep -Fq "exit status 33" "$tmp/hook-context-plain-set-special.err"
    grep -Fq "plain-set-special-stderr" "$tmp/hook-context-plain-set-special.err"

    set +e
    "$agent_store_bin" --json unset "$json_special_unset_id" details >"$tmp/hook-context-json-unset-special.out" 2>"$tmp/hook-context-json-unset-special.err"
    json_special_unset_status="$?"
    set -e
    printf "%s" "$json_special_unset_status" >"$tmp/hook-context-json-unset-special.status"
    test "$json_special_unset_status" -ne 0
    test ! -s "$tmp/hook-context-json-unset-special.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-context-json-unset-special.err"
    grep -Fq "exit status 33" "$tmp/hook-context-json-unset-special.err"
    grep -Fq "json-unset-special-stderr" "$tmp/hook-context-json-unset-special.err"

    summary="$(
      python3 - .agent-store/store.sqlite \
        context-env.log \
        special-context-env.jsonl \
        "$event_marker" \
        "$hook_marker" \
        "$plain_hook_id" \
        "$json_hook_id" \
        "$plain_set_hook_id" \
        "$json_unset_hook_id" \
        "$plain_multi_set_hook_id" \
        "$json_multi_unset_hook_id" \
        "$plain_special_set_hook_id" \
        "$json_special_unset_hook_id" \
        "$plain_source_id" \
        "$plain_target_id" \
        "$json_source_id" \
        "$json_target_id" \
        "$plain_set_id" \
        "$json_unset_id" \
        "$plain_multi_set_id" \
        "$json_multi_unset_id" \
        "$plain_special_set_id" \
        "$json_special_unset_id" \
        "$plain_special_old" \
        "$plain_special_new" \
        "$json_special_old" <<'PY'
import json
import pathlib
import sqlite3
import sys

(
    db,
    env_log,
    special_env_log,
    event_marker,
    hook_marker,
    plain_hook_id,
    json_hook_id,
    plain_set_hook_id,
    json_unset_hook_id,
    plain_multi_set_hook_id,
    json_multi_unset_hook_id,
    plain_special_set_hook_id,
    json_special_unset_hook_id,
    plain_source_id,
    plain_target_id,
    json_source_id,
    json_target_id,
    plain_set_id,
    json_unset_id,
    plain_multi_set_id,
    json_multi_unset_id,
    plain_special_set_id,
    json_special_unset_id,
    plain_special_old,
    plain_special_new,
    json_special_old,
) = sys.argv[1:]

env_lines = pathlib.Path(env_log).read_text().splitlines()
expected_env = [
    f"plain-link:link:{plain_source_id}:task:blocks:{plain_target_id}:::::",
    f"json-unlink:unlink:{json_source_id}:task:relates:{json_target_id}:::::",
    f"plain-set:set:{plain_set_id}:task:::status:status:done:pending:done",
    f"json-unset-field:unset:{json_unset_id}:task:::flag:flag:remove-me:remove-me:",
    f"plain-set-multi:set:{plain_multi_set_id}:task:::::::",
    f"json-unset-multi:unset:{json_multi_unset_id}:task:::::::",
]
assert env_lines == expected_env, env_lines

special_env_rows = [
    json.loads(line)
    for line in pathlib.Path(special_env_log).read_text(encoding="utf-8").splitlines()
]
expected_special_env = [
    {
        "label": "plain-set-special",
        "AGENT_STORE_EVENT": "set",
        "AGENT_STORE_ID": plain_special_set_id,
        "AGENT_STORE_KIND": "task",
        "AGENT_STORE_REL": "",
        "AGENT_STORE_TARGET_ID": "",
        "AGENT_STORE_FIELD": "details",
        "AGENT_STORE_KEY": "details",
        "AGENT_STORE_VALUE": plain_special_new,
        "AGENT_STORE_OLD_VALUE": plain_special_old,
        "AGENT_STORE_NEW_VALUE": plain_special_new,
    },
    {
        "label": "json-unset-special",
        "AGENT_STORE_EVENT": "unset",
        "AGENT_STORE_ID": json_special_unset_id,
        "AGENT_STORE_KIND": "task",
        "AGENT_STORE_REL": "",
        "AGENT_STORE_TARGET_ID": "",
        "AGENT_STORE_FIELD": "details",
        "AGENT_STORE_KEY": "details",
        "AGENT_STORE_VALUE": json_special_old,
        "AGENT_STORE_OLD_VALUE": json_special_old,
        "AGENT_STORE_NEW_VALUE": "",
    },
]
assert special_env_rows == expected_special_env, special_env_rows

con = sqlite3.connect(db)
event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where id > ?
      and event_type in ('link', 'unlink', 'set', 'unset')
    order by id
    """,
    (event_marker,),
).fetchall()
assert event_rows == [
    ("link", plain_source_id),
    ("unlink", json_source_id),
    ("set", plain_set_id),
    ("unset", json_unset_id),
    ("set", plain_multi_set_id),
    ("unset", json_multi_unset_id),
    ("set", plain_special_set_id),
    ("unset", json_special_unset_id),
], event_rows

link_rows = set(
    con.execute(
        """
        select from_record_id, rel, to_record_id
        from record_links
        where from_record_id in (?, ?)
        """,
        (plain_source_id, json_source_id),
    ).fetchall()
)
assert (plain_source_id, "blocks", plain_target_id) in link_rows, link_rows
assert (json_source_id, "relates", json_target_id) not in link_rows, link_rows
plain_set_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'status'
    """,
    (plain_set_id,),
).fetchone()
assert plain_set_status == ("done",), plain_set_status
plain_multi_set_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'status'
    """,
    (plain_multi_set_id,),
).fetchone()
plain_multi_set_priority = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'priority'
    """,
    (plain_multi_set_id,),
).fetchone()
assert plain_multi_set_status == ("done",), plain_multi_set_status
assert plain_multi_set_priority == ("high",), plain_multi_set_priority
plain_special_details = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'details'
    """,
    (plain_special_set_id,),
).fetchone()
assert plain_special_details == (plain_special_new,), plain_special_details
json_unset_flag = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'flag'
    """,
    (json_unset_id,),
).fetchone()
assert json_unset_flag is None, json_unset_flag
json_multi_unset_flag = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'flag'
    """,
    (json_multi_unset_id,),
).fetchone()
json_multi_unset_extra = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'extra'
    """,
    (json_multi_unset_id,),
).fetchone()
assert json_multi_unset_flag is None, json_multi_unset_flag
assert json_multi_unset_extra is None, json_multi_unset_extra
json_special_details = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ?
      and key = 'details'
    """,
    (json_special_unset_id,),
).fetchone()
assert json_special_details is None, json_special_details

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ?
      and hook_id in (?, ?, ?, ?, ?, ?, ?, ?)
    order by id
    """,
    (
        hook_marker,
        plain_hook_id,
        json_hook_id,
        plain_set_hook_id,
        json_unset_hook_id,
        plain_multi_set_hook_id,
        json_multi_unset_hook_id,
        plain_special_set_hook_id,
        json_special_unset_hook_id,
    ),
).fetchall()
expected = {
    plain_hook_id: ("link", plain_source_id, "plain-link-stdout", "plain-link-stderr"),
    json_hook_id: ("unlink", json_source_id, "json-unlink-stdout", "json-unlink-stderr"),
    plain_set_hook_id: ("set", plain_set_id, "plain-set-stdout", "plain-set-stderr"),
    json_unset_hook_id: ("unset", json_unset_id, "json-unset-field-stdout", "json-unset-field-stderr"),
    plain_multi_set_hook_id: ("set", plain_multi_set_id, "plain-set-multi-stdout", "plain-set-multi-stderr"),
    json_multi_unset_hook_id: ("unset", json_multi_unset_id, "json-unset-multi-stdout", "json-unset-multi-stderr"),
    plain_special_set_hook_id: ("set", plain_special_set_id, "plain-set-special-stdout", "plain-set-special-stderr"),
    json_special_unset_hook_id: ("unset", json_special_unset_id, "json-unset-special-stdout", "json-unset-special-stderr"),
}
assert len(rows) == 8, rows
for hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary in rows:
    expected_event, expected_record, expected_stdout, expected_stderr = expected[hook_id]
    assert event_type == expected_event, rows
    assert record_id == expected_record, rows
    assert exit_status == 33, rows
    assert stdout_summary == expected_stdout, rows
    assert expected_stderr in stderr_summary, rows

print(
    "context_failure_hook_runs={} plain_source={} json_source={} plain_set={} json_unset={} plain_multi_set={} json_multi_unset={} plain_special_set={} json_special_unset={} env_lines={} special_env_lines={}".format(
        len(rows),
        plain_source_id,
        json_source_id,
        plain_set_id,
        json_unset_id,
        plain_multi_set_id,
        json_multi_unset_id,
        plain_special_set_id,
        json_special_unset_id,
        len(env_lines),
        len(special_env_rows),
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      cp fail-context-hook.sh "$evidence_root/logs/"
      cp fail-special-context-hook.sh "$evidence_root/logs/"
      cp context-env.log "$evidence_root/logs/"
      cp special-context-env.jsonl "$evidence_root/logs/"
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'hook-context-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/hook-failure-context-env.md" <<EOF
# Hook Failure Context Environment Evidence

- plain_hook_id: $plain_hook_id
- json_hook_id: $json_hook_id
- plain_set_hook_id: $plain_set_hook_id
- json_unset_hook_id: $json_unset_hook_id
- plain_multi_set_hook_id: $plain_multi_set_hook_id
- json_multi_unset_hook_id: $json_multi_unset_hook_id
- plain_special_set_hook_id: $plain_special_set_hook_id
- json_special_unset_hook_id: $json_special_unset_hook_id
- plain_source_id: $plain_source_id
- plain_target_id: $plain_target_id
- json_source_id: $json_source_id
- json_target_id: $json_target_id
- plain_set_id: $plain_set_id
- json_unset_id: $json_unset_id
- plain_multi_set_id: $plain_multi_set_id
- json_multi_unset_id: $json_multi_unset_id
- plain_special_set_id: $plain_special_set_id
- json_special_unset_id: $json_special_unset_id
- plain_status: $plain_status
- json_status: $json_status
- plain_set_status: $plain_set_status
- json_unset_status: $json_unset_status
- plain_multi_set_status: $plain_multi_set_status
- json_multi_unset_status: $json_multi_unset_status
- plain_special_set_status: $plain_special_set_status
- json_special_unset_status: $json_special_unset_status
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  hook_output_capture_caps_and_help)
    cd "$tmp"
    run_agent_store --help >/tmp/agent-store-hook-caps-lc1-help.out
    grep -Fq "Hook stdout and stderr captures are capped at 8192 bytes each." /tmp/agent-store-hook-caps-lc1-help.out

    run_agent_store init >/tmp/agent-store-hook-caps-lc1-init.out

    cat > verbose-hook.py <<'PY'
import sys
import time

label = sys.argv[1]
action = sys.argv[2]
count = int(sys.argv[3])

sys.stdout.write(f"{label}-stdout\n")
sys.stdout.write("O" * count)
sys.stdout.flush()
sys.stderr.write(f"{label}-stderr\n")
sys.stderr.write("E" * count)
sys.stderr.flush()

if action == "fail":
    raise SystemExit(37)
if action == "timeout":
    while True:
        time.sleep(1)
PY

    cat > invalid-utf8-hook.py <<'PY'
import sys

label = sys.argv[1]
sys.stdout.buffer.write(label.encode("utf-8") + b"-stdout:\xff\xfe\n")
sys.stdout.buffer.flush()
sys.stderr.buffer.write(label.encode("utf-8") + b"-stderr:\xfe\xff\n")
sys.stderr.buffer.flush()
raise SystemExit(41)
PY

    success_hook_id="$(run_agent_store hook add create title=VerboseSuccess -- 'python3 verbose-hook.py success ok 9000')"
    record_id="$(run_agent_store create task title=VerboseSuccess)"
    printf "%s\n" "$record_id" | grep -Eq "^[a-z0-9]{6,8}$"

    plain_record_id="$(run_agent_store create task title=PlainLarge status=pending)"
    plain_hook_id="$(run_agent_store hook add set status=large-failure -- 'python3 verbose-hook.py plain-fail fail 131072')"
    plain_out="$tmp/plain-large-failure.out"
    plain_err="$tmp/plain-large-failure.err"
    if run_agent_store set "$plain_record_id" status=large-failure >"$plain_out" 2>"$plain_err"; then
      exit 1
    fi
    test ! -s "$plain_out"
    grep -Fq "Store mutation already committed" "$plain_err"
    grep -Fq "exit status 37" "$plain_err"
    grep -Fq "plain-fail-stderr" "$plain_err"
    run_agent_store get "$plain_record_id" | grep -Fq "status=large-failure"

    json_source_id="$(run_agent_store create task title=JsonLargeSource)"
    json_target_id="$(run_agent_store create task title=JsonLargeTarget)"
    json_hook_id="$(run_agent_store hook add link kind=task -- 'python3 verbose-hook.py json-timeout timeout 131072')"
    json_out="$tmp/json-large-timeout.out"
    json_err="$tmp/json-large-timeout.err"
    if run_agent_store --json link "$json_source_id" relates "$json_target_id" >"$json_out" 2>"$json_err"; then
      exit 1
    fi
    test ! -s "$json_out"
    grep -Fq "Store mutation already committed" "$json_err"
    grep -Fq "timed out after 30 seconds" "$json_err"
    grep -Fq "json-timeout-stderr" "$json_err"
    run_agent_store links "$json_source_id" | grep -Fq "out relates $json_target_id"

    plain_invalid_record_id="$(run_agent_store create task title=PlainInvalidUtf8 status=pending)"
    plain_invalid_hook_id="$(run_agent_store hook add set 'title=PlainInvalidUtf8 and status=invalid-utf8' -- 'python3 invalid-utf8-hook.py plain-invalid')"
    plain_invalid_out="$tmp/plain-invalid-utf8.out"
    plain_invalid_err="$tmp/plain-invalid-utf8.err"
    if run_agent_store set "$plain_invalid_record_id" status=invalid-utf8 >"$plain_invalid_out" 2>"$plain_invalid_err"; then
      exit 1
    fi
    test ! -s "$plain_invalid_out"
    grep -Fq "Store mutation already committed" "$plain_invalid_err"
    grep -Fq "exit status 41" "$plain_invalid_err"
    grep -Fq "plain-invalid-stderr:" "$plain_invalid_err"
    run_agent_store get "$plain_invalid_record_id" | grep -Fq "status=invalid-utf8"

    json_invalid_record_id="$(run_agent_store create task title=JsonInvalidUtf8 status=pending)"
    json_invalid_hook_id="$(run_agent_store hook add set 'title=JsonInvalidUtf8 and status=invalid-utf8' -- 'python3 invalid-utf8-hook.py json-invalid')"
    json_invalid_out="$tmp/json-invalid-utf8.out"
    json_invalid_err="$tmp/json-invalid-utf8.err"
    if run_agent_store --json set "$json_invalid_record_id" status=invalid-utf8 >"$json_invalid_out" 2>"$json_invalid_err"; then
      exit 1
    fi
    test ! -s "$json_invalid_out"
    grep -Fq "Store mutation already committed" "$json_invalid_err"
    grep -Fq "exit status 41" "$json_invalid_err"
    grep -Fq "json-invalid-stderr:" "$json_invalid_err"
    run_agent_store --json get "$json_invalid_record_id" >"$tmp/json-invalid-after-get.out"

    python3 - "$plain_invalid_err" "$json_invalid_err" "$tmp/json-invalid-after-get.out" "$json_invalid_record_id" <<'PY'
import json
import pathlib
import sys

plain_err, json_err, after_get_path, json_invalid_record_id = sys.argv[1:]
for path, label in [
    (plain_err, "plain-invalid-stderr:"),
    (json_err, "json-invalid-stderr:"),
]:
    text = pathlib.Path(path).read_text(encoding="utf-8")
    assert "Store mutation already committed" in text, (path, text)
    assert label in text, (path, text)
    assert "\ufffd" in text, (path, text)
    assert "panicked" not in text.lower(), (path, text)

payload = json.loads(pathlib.Path(after_get_path).read_text(encoding="utf-8"))
assert payload["record"]["id"] == json_invalid_record_id, payload
assert payload["record"]["fields"]["status"] == "invalid-utf8", payload
PY

    python3 - .agent-store/store.sqlite \
      "$success_hook_id" \
      "$plain_hook_id" \
      "$json_hook_id" \
      "$plain_invalid_hook_id" \
      "$json_invalid_hook_id" \
      "$record_id" \
      "$plain_record_id" \
      "$json_source_id" \
      "$plain_invalid_record_id" \
      "$json_invalid_record_id" <<'PY'
import sqlite3
import sys

(
    db,
    success_hook_id,
    plain_hook_id,
    json_hook_id,
    plain_invalid_hook_id,
    json_invalid_hook_id,
    record_id,
    plain_record_id,
    json_source_id,
    plain_invalid_record_id,
    json_invalid_record_id,
) = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    order by id
    """
).fetchall()
by_hook = {row[0]: row[1:] for row in rows}
assert set(by_hook) == {
    success_hook_id,
    plain_hook_id,
    json_hook_id,
    plain_invalid_hook_id,
    json_invalid_hook_id,
}, rows

def assert_capped(value, prefix):
    assert len(value) == 8192, (prefix, len(value), value[:80], value[-80:])
    assert value.startswith(prefix), (prefix, value[:80])

success = by_hook[success_hook_id]
assert success[:3] == ("create", record_id, 0), success
assert_capped(success[3], "success-stdout\n")
assert_capped(success[4], "success-stderr\n")

plain = by_hook[plain_hook_id]
assert plain[:3] == ("set", plain_record_id, 37), plain
assert_capped(plain[3], "plain-fail-stdout\n")
assert_capped(plain[4], "plain-fail-stderr\n")

json_timeout = by_hook[json_hook_id]
assert json_timeout[:3] == ("link", json_source_id, -1), json_timeout
assert_capped(json_timeout[3], "json-timeout-stdout\n")
assert json_timeout[4].startswith("json-timeout-stderr\n"), json_timeout
assert json_timeout[4][8192:] == "; timed out after 30 seconds", (
    len(json_timeout[4]),
    json_timeout[4][:80],
    json_timeout[4][-80:],
)

plain_invalid = by_hook[plain_invalid_hook_id]
assert plain_invalid[:3] == ("set", plain_invalid_record_id, 41), plain_invalid
assert plain_invalid[3].startswith("plain-invalid-stdout:"), plain_invalid
assert plain_invalid[4].startswith("plain-invalid-stderr:"), plain_invalid
assert "\ufffd" in plain_invalid[3], plain_invalid
assert "\ufffd" in plain_invalid[4], plain_invalid

json_invalid = by_hook[json_invalid_hook_id]
assert json_invalid[:3] == ("set", json_invalid_record_id, 41), json_invalid
assert json_invalid[3].startswith("json-invalid-stdout:"), json_invalid
assert json_invalid[4].startswith("json-invalid-stderr:"), json_invalid
assert "\ufffd" in json_invalid[3], json_invalid
assert "\ufffd" in json_invalid[4], json_invalid

events = con.execute(
    """
    select event_type, record_id
    from store_events
    where record_id in (?, ?, ?, ?, ?)
    order by id
    """,
    (
        record_id,
        plain_record_id,
        json_source_id,
        plain_invalid_record_id,
        json_invalid_record_id,
    ),
).fetchall()
assert ("create", record_id) in events, events
assert ("set", plain_record_id) in events, events
assert ("link", json_source_id) in events, events
assert ("set", plain_invalid_record_id) in events, events
assert ("set", json_invalid_record_id) in events, events
PY

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
      cp "$plain_out" "$evidence_root/logs/plain-large-failure.out"
      cp "$plain_err" "$evidence_root/logs/plain-large-failure.err"
      cp "$json_out" "$evidence_root/logs/json-large-timeout.out"
      cp "$json_err" "$evidence_root/logs/json-large-timeout.err"
      cp "$plain_invalid_out" "$evidence_root/logs/plain-invalid-utf8.out"
      cp "$plain_invalid_err" "$evidence_root/logs/plain-invalid-utf8.err"
      cp "$json_invalid_out" "$evidence_root/logs/json-invalid-utf8.out"
      cp "$json_invalid_err" "$evidence_root/logs/json-invalid-utf8.err"
      cp "$tmp/json-invalid-after-get.out" "$evidence_root/logs/json-invalid-after-get.out"
      cat > "$evidence_root/reports/hook-output-capture-caps.md" <<EOF
# Hook Output Capture Caps

- success_hook_id: $success_hook_id
- plain_failure_hook_id: $plain_hook_id
- json_timeout_hook_id: $json_hook_id
- plain_invalid_utf8_hook_id: $plain_invalid_hook_id
- json_invalid_utf8_hook_id: $json_invalid_hook_id
- substantial_output_bytes_per_stream: 131072
- persisted_capture_limit_bytes: 8192
- plain_failure_stdout_empty: yes
- json_timeout_stdout_empty: yes
- plain_invalid_utf8_stdout_empty: yes
- json_invalid_utf8_stdout_empty: yes
- non_utf8_cli_stderr_valid_utf8: yes
- committed_records: $record_id $plain_record_id $json_source_id $plain_invalid_record_id $json_invalid_record_id
EOF
    fi

    printf "hook_output_capture_caps success=%s plain_failure=%s json_timeout=%s plain_invalid_utf8=%s json_invalid_utf8=%s\n" "$record_id" "$plain_record_id" "$json_source_id" "$plain_invalid_record_id" "$json_invalid_record_id"
    ;;

  hook_signal_termination_reports_committed_mutation)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-signal-yjb-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    cat > signal-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
label="$1"
signal_name="${2:-TERM}"
printf "%s-signal-stdout" "$label"
printf "%s-signal-stderr" "$label" >&2
kill "-$signal_name" "$$"
sleep 1
SH
    chmod +x signal-hook.sh

    assert_signal_failure() {
      local name="$1"
      local expected_stderr="$2"
      local signal_number="$3"
      local signal_name="$4"
      local status
      status="$(cat "$tmp/hook-signal-$name.status")"

      test "$status" -ne 0
      test ! -s "$tmp/hook-signal-$name.out"
      grep -Fq "Store mutation already committed" "$tmp/hook-signal-$name.err"
      grep -Fq "terminated by signal $signal_number" "$tmp/hook-signal-$name.err"
      grep -Fq "$signal_name" "$tmp/hook-signal-$name.err"
      grep -Fq "$expected_stderr" "$tmp/hook-signal-$name.err"
    }

    plain_hook_id="$("$agent_store_bin" hook add create title=SignalPlain -- './signal-hook.sh plain')"
    set +e
    "$agent_store_bin" create task title=SignalPlain >"$tmp/hook-signal-plain.out" 2>"$tmp/hook-signal-plain.err"
    plain_status="$?"
    set -e
    printf "%s" "$plain_status" >"$tmp/hook-signal-plain.status"
    assert_signal_failure plain plain-signal-stderr 15 SIGTERM

    plain_kill_record="$("$agent_store_bin" create task title=SignalKillPlain status=pending)"
    plain_kill_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=SignalKillPlain and status=done' -- './signal-hook.sh plain-kill KILL')"
    set +e
    "$agent_store_bin" set "$plain_kill_record" status=done >"$tmp/hook-signal-plain-kill.out" 2>"$tmp/hook-signal-plain-kill.err"
    plain_kill_status="$?"
    set -e
    printf "%s" "$plain_kill_status" >"$tmp/hook-signal-plain-kill.status"
    assert_signal_failure plain-kill plain-kill-signal-stderr 9 SIGKILL

    json_create_hook_id="$("$agent_store_bin" hook add create title=SignalJsonCreate -- './signal-hook.sh json-create')"
    set +e
    "$agent_store_bin" --json create task title=SignalJsonCreate status=committed >"$tmp/hook-signal-json-create.out" 2>"$tmp/hook-signal-json-create.err"
    json_create_status="$?"
    set -e
    printf "%s" "$json_create_status" >"$tmp/hook-signal-json-create.status"
    assert_signal_failure json-create json-create-signal-stderr 15 SIGTERM

    json_set_record="$("$agent_store_bin" create task title=SignalJsonSet status=pending)"
    json_set_hook_id="$("$agent_store_bin" hook add set 'kind=task and title=SignalJsonSet and status=done' -- './signal-hook.sh json-set')"
    set +e
    "$agent_store_bin" --json set "$json_set_record" status=done >"$tmp/hook-signal-json-set.out" 2>"$tmp/hook-signal-json-set.err"
    json_set_status="$?"
    set -e
    printf "%s" "$json_set_status" >"$tmp/hook-signal-json-set.status"
    assert_signal_failure json-set json-set-signal-stderr 15 SIGTERM

    json_link_source="$("$agent_store_bin" create task title=SignalJsonLinkSource status=open)"
    json_link_target="$("$agent_store_bin" create note title=SignalJsonLinkTarget status=open)"
    json_link_hook_id="$("$agent_store_bin" hook add link 'kind=task and title=SignalJsonLinkSource' -- './signal-hook.sh json-link')"
    set +e
    "$agent_store_bin" --json link "$json_link_source" blocks "$json_link_target" >"$tmp/hook-signal-json-link.out" 2>"$tmp/hook-signal-json-link.err"
    json_link_status="$?"
    set -e
    printf "%s" "$json_link_status" >"$tmp/hook-signal-json-link.status"
    assert_signal_failure json-link json-link-signal-stderr 15 SIGTERM

    json_kill_link_source="$("$agent_store_bin" create task title=SignalKillJsonLinkSource status=open)"
    json_kill_link_target="$("$agent_store_bin" create note title=SignalKillJsonLinkTarget status=open)"
    json_kill_link_hook_id="$("$agent_store_bin" hook add link 'kind=task and title=SignalKillJsonLinkSource' -- './signal-hook.sh json-link-kill KILL')"
    set +e
    "$agent_store_bin" --json link "$json_kill_link_source" blocks "$json_kill_link_target" >"$tmp/hook-signal-json-link-kill.out" 2>"$tmp/hook-signal-json-link-kill.err"
    json_kill_link_status="$?"
    set -e
    printf "%s" "$json_kill_link_status" >"$tmp/hook-signal-json-link-kill.status"
    assert_signal_failure json-link-kill json-link-kill-signal-stderr 9 SIGKILL

    json_unset_record="$("$agent_store_bin" create task title=SignalJsonUnset status=present)"
    json_unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and title=SignalJsonUnset' -- './signal-hook.sh json-unset')"
    set +e
    "$agent_store_bin" --json unset "$json_unset_record" status >"$tmp/hook-signal-json-unset.out" 2>"$tmp/hook-signal-json-unset.err"
    json_unset_status="$?"
    set -e
    printf "%s" "$json_unset_status" >"$tmp/hook-signal-json-unset.status"
    assert_signal_failure json-unset json-unset-signal-stderr 15 SIGTERM

    json_rm_record="$("$agent_store_bin" create task title=SignalJsonRm status=present)"
    json_rm_hook_id="$("$agent_store_bin" hook add rm 'kind=task and title=SignalJsonRm' -- './signal-hook.sh json-rm')"
    set +e
    "$agent_store_bin" --json rm "$json_rm_record" >"$tmp/hook-signal-json-rm.out" 2>"$tmp/hook-signal-json-rm.err"
    json_rm_status="$?"
    set -e
    printf "%s" "$json_rm_status" >"$tmp/hook-signal-json-rm.status"
    assert_signal_failure json-rm json-rm-signal-stderr 15 SIGTERM

    json_unlink_source="$("$agent_store_bin" create task title=SignalJsonUnlinkSource status=open)"
    json_unlink_target="$("$agent_store_bin" create note title=SignalJsonUnlinkTarget status=open)"
    "$agent_store_bin" link "$json_unlink_source" blocks "$json_unlink_target" >/dev/null
    json_unlink_hook_id="$("$agent_store_bin" hook add unlink 'kind=task and title=SignalJsonUnlinkSource' -- './signal-hook.sh json-unlink')"
    set +e
    "$agent_store_bin" --json unlink "$json_unlink_source" blocks "$json_unlink_target" >"$tmp/hook-signal-json-unlink.out" 2>"$tmp/hook-signal-json-unlink.err"
    json_unlink_status="$?"
    set -e
    printf "%s" "$json_unlink_status" >"$tmp/hook-signal-json-unlink.status"
    assert_signal_failure json-unlink json-unlink-signal-stderr 15 SIGTERM

    "$agent_store_bin" --json create task title=SignalAfter status=ok >"$tmp/hook-signal-after.out" 2>"$tmp/hook-signal-after.err"
    later_record="$(python3 - "$tmp/hook-signal-after.out" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
record_id = payload["record"]["id"]
assert isinstance(record_id, str) and record_id
print(record_id)
PY
)"
    "$agent_store_bin" --json get "$later_record" >"$tmp/hook-signal-after-get.out" 2>"$tmp/hook-signal-after-get.err"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$plain_hook_id" \
      "$json_create_hook_id" \
      "$json_set_hook_id" \
      "$json_link_hook_id" \
      "$json_unset_hook_id" \
      "$json_rm_hook_id" \
      "$json_unlink_hook_id" \
      "$json_set_record" \
      "$json_link_source" \
      "$json_link_target" \
      "$json_unset_record" \
      "$json_rm_record" \
      "$json_unlink_source" \
      "$json_unlink_target" \
      "$later_record" <<'PY'
import json
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    plain_hook_id,
    json_create_hook_id,
    json_set_hook_id,
    json_link_hook_id,
    json_unset_hook_id,
    json_rm_hook_id,
    json_unlink_hook_id,
    json_set_record,
    json_link_source,
    json_link_target,
    json_unset_record,
    json_rm_record,
    json_unlink_source,
    json_unlink_target,
    later_record,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
con = sqlite3.connect(db)

for name, expected in [
    ("plain", "plain-signal-stderr"),
    ("json-create", "json-create-signal-stderr"),
    ("json-set", "json-set-signal-stderr"),
    ("json-link", "json-link-signal-stderr"),
    ("json-unset", "json-unset-signal-stderr"),
    ("json-rm", "json-rm-signal-stderr"),
    ("json-unlink", "json-unlink-signal-stderr"),
]:
    stdout = (tmp / f"hook-signal-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"hook-signal-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"hook-signal-{name}.status").read_text(encoding="utf-8"))
    assert stdout == "", (name, stdout)
    assert status != 0, (name, status)
    assert "Store mutation already committed" in stderr, (name, stderr)
    assert "terminated by signal 15" in stderr, (name, stderr)
    assert "SIGTERM" in stderr, (name, stderr)
    assert expected in stderr, (name, stderr)

after_payload = json.loads((tmp / "hook-signal-after.out").read_text(encoding="utf-8"))
after_get_payload = json.loads((tmp / "hook-signal-after-get.out").read_text(encoding="utf-8"))
assert after_payload["record"]["id"] == later_record, after_payload
assert after_get_payload["record"]["id"] == later_record, after_get_payload

def record_by_title(title):
    rows = con.execute(
        """
        select records.id, record_fields.raw_value
        from records
        join record_fields on record_fields.record_id = records.id
        where records.kind = 'task'
          and record_fields.key = 'title'
          and record_fields.raw_value = ?
        order by records.id
        """,
        (title,),
    ).fetchall()
    assert len(rows) == 1, (title, rows)
    return rows[0][0]

plain_record = record_by_title("SignalPlain")
json_create_record = record_by_title("SignalJsonCreate")
assert record_by_title("SignalJsonSet") == json_set_record
assert record_by_title("SignalJsonLinkSource") == json_link_source
assert record_by_title("SignalJsonUnset") == json_unset_record
assert record_by_title("SignalJsonUnlinkSource") == json_unlink_source
assert record_by_title("SignalAfter") == later_record

json_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ? and key = 'status'
    """,
    (json_set_record,),
).fetchone()
assert json_status == ("done",), json_status
json_create_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ? and key = 'status'
    """,
    (json_create_record,),
).fetchone()
assert json_create_status == ("committed",), json_create_status
json_unset_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ? and key = 'status'
    """,
    (json_unset_record,),
).fetchone()
assert json_unset_status is None, json_unset_status
assert con.execute(
    "select count(*) from records where id = ?",
    (json_rm_record,),
).fetchone()[0] == 0
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (json_link_source, json_link_target),
).fetchone()[0] == 1
assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (json_unlink_source, json_unlink_target),
).fetchone()[0] == 0

event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where record_id in (?, ?, ?, ?, ?, ?, ?, ?)
    order by id
    """,
    (
        plain_record,
        json_create_record,
        json_set_record,
        json_link_source,
        json_unset_record,
        json_rm_record,
        json_unlink_source,
        later_record,
    ),
).fetchall()
assert ("create", plain_record) in event_rows, event_rows
assert ("create", json_create_record) in event_rows, event_rows
assert ("set", json_set_record) in event_rows, event_rows
assert ("link", json_link_source) in event_rows, event_rows
assert ("unset", json_unset_record) in event_rows, event_rows
assert ("rm", json_rm_record) in event_rows, event_rows
assert ("unlink", json_unlink_source) in event_rows, event_rows
assert ("create", later_record) in event_rows, event_rows

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id in (?, ?, ?, ?, ?, ?, ?)
    order by id
    """,
    (
        plain_hook_id,
        json_create_hook_id,
        json_set_hook_id,
        json_link_hook_id,
        json_unset_hook_id,
        json_rm_hook_id,
        json_unlink_hook_id,
    ),
).fetchall()
assert rows == [
    (
        plain_hook_id,
        "create",
        plain_record,
        -15,
        "plain-signal-stdout",
        "plain-signal-stderr",
    ),
    (
        json_create_hook_id,
        "create",
        json_create_record,
        -15,
        "json-create-signal-stdout",
        "json-create-signal-stderr",
    ),
    (
        json_set_hook_id,
        "set",
        json_set_record,
        -15,
        "json-set-signal-stdout",
        "json-set-signal-stderr",
    ),
    (
        json_link_hook_id,
        "link",
        json_link_source,
        -15,
        "json-link-signal-stdout",
        "json-link-signal-stderr",
    ),
    (
        json_unset_hook_id,
        "unset",
        json_unset_record,
        -15,
        "json-unset-signal-stdout",
        "json-unset-signal-stderr",
    ),
    (
        json_rm_hook_id,
        "rm",
        json_rm_record,
        -15,
        "json-rm-signal-stdout",
        "json-rm-signal-stderr",
    ),
    (
        json_unlink_hook_id,
        "unlink",
        json_unlink_source,
        -15,
        "json-unlink-signal-stdout",
        "json-unlink-signal-stderr",
    ),
], rows

print(
    "signal_hook_runs={} plain_record={} json_create_record={} json_set_record={} json_link_source={} json_unset_record={} json_rm_record={} json_unlink_source={} later_record={} statuses={}".format(
        len(rows),
        plain_record,
        json_create_record,
        json_set_record,
        json_link_source,
        json_unset_record,
        json_rm_record,
        json_unlink_source,
        later_record,
        ",".join(str(row[3]) for row in rows),
    )
)
PY
)"

    kill_summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$plain_kill_hook_id" \
      "$json_kill_link_hook_id" \
      "$plain_kill_record" \
      "$json_kill_link_source" \
      "$json_kill_link_target" <<'PY'
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    plain_kill_hook_id,
    json_kill_link_hook_id,
    plain_kill_record,
    json_kill_link_source,
    json_kill_link_target,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
con = sqlite3.connect(db)

for name, expected in [
    ("plain-kill", "plain-kill-signal-stderr"),
    ("json-link-kill", "json-link-kill-signal-stderr"),
]:
    stdout = (tmp / f"hook-signal-{name}.out").read_text(encoding="utf-8")
    stderr = (tmp / f"hook-signal-{name}.err").read_text(encoding="utf-8")
    status = int((tmp / f"hook-signal-{name}.status").read_text(encoding="utf-8"))
    assert stdout == "", (name, stdout)
    assert status != 0, (name, status)
    assert "Store mutation already committed" in stderr, (name, stderr)
    assert "terminated by signal 9" in stderr, (name, stderr)
    assert "SIGKILL" in stderr, (name, stderr)
    assert expected in stderr, (name, stderr)

plain_status = con.execute(
    """
    select raw_value
    from record_fields
    where record_id = ? and key = 'status'
    """,
    (plain_kill_record,),
).fetchone()
assert plain_status == ("done",), plain_status

assert con.execute(
    """
    select count(*) from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (json_kill_link_source, json_kill_link_target),
).fetchone()[0] == 1

event_rows = con.execute(
    """
    select event_type, record_id
    from store_events
    where record_id in (?, ?)
    order by id
    """,
    (plain_kill_record, json_kill_link_source),
).fetchall()
assert ("set", plain_kill_record) in event_rows, event_rows
assert ("link", json_kill_link_source) in event_rows, event_rows

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id in (?, ?)
    order by id
    """,
    (plain_kill_hook_id, json_kill_link_hook_id),
).fetchall()
assert rows == [
    (
        plain_kill_hook_id,
        "set",
        plain_kill_record,
        -9,
        "plain-kill-signal-stdout",
        "plain-kill-signal-stderr",
    ),
    (
        json_kill_link_hook_id,
        "link",
        json_kill_link_source,
        -9,
        "json-link-kill-signal-stdout",
        "json-link-kill-signal-stderr",
    ),
], rows

print(
    "sigkill_hook_runs={} plain_kill_record={} json_kill_link_source={} statuses={}".format(
        len(rows),
        plain_kill_record,
        json_kill_link_source,
        ",".join(str(row[3]) for row in rows),
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      cp signal-hook.sh "$evidence_root/logs/"
      cp "$tmp"/hook-signal-* "$evidence_root/logs/"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/hook-signal-termination.md" <<EOF
# Hook Signal Termination Evidence

- plain_hook_id: $plain_hook_id
- plain_kill_hook_id: $plain_kill_hook_id
- json_create_hook_id: $json_create_hook_id
- json_set_hook_id: $json_set_hook_id
- json_link_hook_id: $json_link_hook_id
- json_kill_link_hook_id: $json_kill_link_hook_id
- json_unset_hook_id: $json_unset_hook_id
- json_rm_hook_id: $json_rm_hook_id
- json_unlink_hook_id: $json_unlink_hook_id
- plain_status: $plain_status
- plain_kill_status: $plain_kill_status
- json_create_status: $json_create_status
- json_set_status: $json_set_status
- json_link_status: $json_link_status
- json_kill_link_status: $json_kill_link_status
- json_unset_status: $json_unset_status
- json_rm_status: $json_rm_status
- json_unlink_status: $json_unlink_status
- later_record: $later_record
- $summary
- $kill_summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  hook_timeout_terminates_process_group)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-hook-timeout-pgrp-ecj-init.out
    agent_store_bin="$target_dir/debug/agent-store"

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    side_effect="late-descendant-side-effect.log"
    child_pid_file="timeout-descendant.pid"

    cat > timeout-descendant-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
side_effect="$1"
child_pid_file="$2"
printf "timeout-hook-started" >&2
(
  trap "" TERM INT HUP
  sleep 32
  printf "late-descendant-side-effect\n" >>"$side_effect"
) >/dev/null 2>&1 < /dev/null &
printf "%s" "$!" >"$child_pid_file"
while :; do
  sleep 1
done
SH
    chmod +x timeout-descendant-hook.sh

    hook_id="$("$agent_store_bin" hook add create title=TimeoutProcessGroup -- "./timeout-descendant-hook.sh $side_effect $child_pid_file")"

    set +e
    timeout 40s "$agent_store_bin" create task title=TimeoutProcessGroup >"$tmp/hook-timeout-pgrp.out" 2>"$tmp/hook-timeout-pgrp.err"
    timeout_status="$?"
    set -e
    printf "%s" "$timeout_status" >"$tmp/hook-timeout-pgrp.status"

    test "$timeout_status" -ne 0
    test "$timeout_status" -ne 124
    test ! -s "$tmp/hook-timeout-pgrp.out"
    grep -Fq "Store mutation already committed" "$tmp/hook-timeout-pgrp.err"
    grep -Fq "timed out after 30 seconds" "$tmp/hook-timeout-pgrp.err"
    grep -Fq "timeout-hook-started" "$tmp/hook-timeout-pgrp.err"
    test -s "$child_pid_file"

    for _ in $(seq 1 30); do
      if [ -e "$side_effect" ]; then
        child_pid="$(cat "$child_pid_file")"
        kill -KILL "$child_pid" 2>/dev/null || true
        echo "timed-out hook descendant produced a late side effect" >&2
        exit 1
      fi
      sleep 0.2
    done

    summary="$(python3 - \
      .agent-store/store.sqlite \
      "$hook_id" \
      "$side_effect" <<'PY'
import pathlib
import sqlite3
import sys

db, hook_id, side_effect = sys.argv[1:]
assert not pathlib.Path(side_effect).exists(), side_effect

con = sqlite3.connect(db)
record_row = con.execute(
    """
    select records.id
    from records
    join record_fields on record_fields.record_id = records.id
    where records.kind = 'task'
      and record_fields.key = 'title'
      and record_fields.raw_value = 'TimeoutProcessGroup'
    """
).fetchone()
assert record_row is not None
record_id = record_row[0]

rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id = ?
    order by id
    """,
    (hook_id,),
).fetchall()
assert rows == [
    (
        hook_id,
        "create",
        record_id,
        -1,
        "",
        "timeout-hook-started; timed out after 30 seconds",
    )
], rows

print(f"timeout_hook_runs={len(rows)} record={record_id} late_side_effect=absent")
PY
)"

    child_pid="$(cat "$child_pid_file")"
    kill -KILL "$child_pid" 2>/dev/null || true

    if [ -n "$evidence_root" ]; then
      cp timeout-descendant-hook.sh "$evidence_root/logs/"
      cp "$tmp/hook-timeout-pgrp.out" "$evidence_root/logs/"
      cp "$tmp/hook-timeout-pgrp.err" "$evidence_root/logs/"
      cp "$tmp/hook-timeout-pgrp.status" "$evidence_root/logs/"
      cp "$child_pid_file" "$evidence_root/logs/"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/hook-timeout-process-group.md" <<EOF
# Hook Timeout Process Group Evidence

- hook_id: $hook_id
- child_pid: $child_pid
- timeout_status: $timeout_status
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  *)
    echo "usage: $0 {hook_add_stores_metadata|hook_ls_deterministic|hook_rm_deletes_metadata|hooks_run_after_commit|hook_query_filters_records|hook_query_uses_mutation_snapshot|hook_stdin_receives_record_snapshot|hook_failure_reports_details|hook_failure_or_timeout_reports_committed_mutation|hook_command_launch_or_execution_failure_reports_committed_mutation|json_mutation_hook_failure_or_timeout_reports_committed_without_success_json|json_multiple_matching_hooks_stop_after_failure_or_timeout|hooks_run_sequentially_from_project_root_with_timeout|hook_env_vars_for_record_events|link_hook_query_source_and_relation_env|hook_failure_preserves_link_context_env|hook_output_capture_caps_and_help|hook_signal_termination_reports_committed_mutation|hook_timeout_terminates_process_group}" >&2
    exit 2
    ;;
esac
