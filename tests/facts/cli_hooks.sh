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

  *)
    echo "usage: $0 {hook_add_stores_metadata|hook_ls_deterministic|hook_rm_deletes_metadata|hooks_run_after_commit|hook_query_filters_records|hook_query_uses_mutation_snapshot}" >&2
    exit 2
    ;;
esac
