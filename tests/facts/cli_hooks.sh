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
    echo "usage: $0 {hook_add_stores_metadata|hook_ls_deterministic|hook_rm_deletes_metadata|hooks_run_after_commit|hook_query_filters_records|hook_query_uses_mutation_snapshot|hook_stdin_receives_record_snapshot|hook_failure_reports_details|hook_failure_or_timeout_reports_committed_mutation|hooks_run_sequentially_from_project_root_with_timeout|hook_env_vars_for_record_events|hook_output_capture_caps_and_help}" >&2
    exit 2
    ;;
esac
