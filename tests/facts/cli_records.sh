#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

case "$case_name" in
  create_alias_matches_create)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-cr-ee0-init.out
    id="$(run_agent_store cr task title=Write status=open)"
    printf "%s\n" "$id" | grep -Eq "^[a-z0-9]{6,8}$"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task status=open title=Write"

    set +e
    run_agent_store create >/tmp/agent-store-cr-ee0-create.out 2>/tmp/agent-store-cr-ee0-create.err
    create_status=$?
    run_agent_store cr >/tmp/agent-store-cr-ee0-cr.out 2>/tmp/agent-store-cr-ee0-cr.err
    cr_status=$?
    set -e
    test "$create_status" -ne 0
    test "$cr_status" -eq "$create_status"
    cmp -s /tmp/agent-store-cr-ee0-create.out /tmp/agent-store-cr-ee0-cr.out
    cmp -s /tmp/agent-store-cr-ee0-create.err /tmp/agent-store-cr-ee0-cr.err
    ;;

  find_alias_matches_find)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-ls-8id-init.out
    open_task="$(run_agent_store create task title=Write status=open priority=high)"
    run_agent_store create task title=Ship status=done priority=low >/tmp/agent-store-ls-8id-done.out
    run_agent_store create note title=Write status=open priority=high >/tmp/agent-store-ls-8id-note.out

    expected="$open_task task priority=high status=open title=Write"
    find_out="$(run_agent_store find 'kind=task and status=open')"
    test "$find_out" = "$expected"
    ls_out="$(run_agent_store ls kind=task and status=open)"
    test "$ls_out" = "$find_out"

    set +e
    run_agent_store find >/tmp/agent-store-ls-8id-find.out 2>/tmp/agent-store-ls-8id-find.err
    find_status=$?
    run_agent_store ls >/tmp/agent-store-ls-8id-ls.out 2>/tmp/agent-store-ls-8id-ls.err
    ls_status=$?
    set -e
    test "$find_status" -ne 0
    test "$ls_status" -eq "$find_status"
    cmp -s /tmp/agent-store-ls-8id-find.out /tmp/agent-store-ls-8id-ls.out
    cmp -s /tmp/agent-store-ls-8id-find.err /tmp/agent-store-ls-8id-ls.err
    ;;

  set_updates_fields)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-set-1b1-init.out
    id="$(run_agent_store create task title=Write status=open note=keep missing=old)"
    prefix="$(printf "%s" "$id" | cut -c1-4)"

    out="$(run_agent_store set "$prefix" status=done empty= missing=null)"
    test "$out" = "Updated $id"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task empty='' missing=null note=keep status=done title=Write"

    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
con.execute(
    """
    create trigger rollback_set_after_first_field
    before insert on record_fields
    when new.key = 'zzz_fail_after_status'
    begin
        select raise(abort, 'forced set rollback');
    end
    """
)
con.commit()
PY

    if run_agent_store set "$id" status=partial zzz_fail_after_status=bad >/tmp/agent-store-set-1b1-rollback.out 2>/tmp/agent-store-set-1b1-rollback.err; then
      exit 1
    fi
    grep -Fq "failed to set record" /tmp/agent-store-set-1b1-rollback.err
    grep -Fq "forced set rollback" /tmp/agent-store-set-1b1-rollback.err
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task empty='' missing=null note=keep status=done title=Write"

    python3 - .agent-store/store.sqlite "$id" <<'PY'
import sqlite3
import sys

db, record_id = sys.argv[1:]
con = sqlite3.connect(db)
fields = {
    row[0]: row[1]
    for row in con.execute(
        "select key, raw_value from record_fields where record_id = ?",
        (record_id,),
    )
}
assert fields == {
    "empty": "",
    "missing": "null",
    "note": "keep",
    "status": "done",
    "title": "Write",
}, fields
PY
    ;;

  unset_removes_fields)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-unset-d77-init.out
    id="$(run_agent_store create task title=Write status=open note=keep missing=null empty=)"
    prefix="$(printf "%s" "$id" | cut -c1-4)"

    out="$(run_agent_store unset "$prefix" status missing)"
    test "$out" = "Updated $id"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task empty='' note=keep title=Write"

    python3 - .agent-store/store.sqlite "$id" <<'PY'
import sqlite3
import sys

db, record_id = sys.argv[1:]
con = sqlite3.connect(db)
fields = {
    row[0]: row[1]
    for row in con.execute(
        "select key, raw_value from record_fields where record_id = ?",
        (record_id,),
    )
}
assert fields == {
    "empty": "",
    "note": "keep",
    "title": "Write",
}, fields
assert con.execute("select count(*) from records where id = ?", (record_id,)).fetchone()[0] == 1
PY

    run_agent_store set "$id" note=keep zzz_fail_after_note=bad >/tmp/agent-store-unset-d77-set.out
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
con.execute(
    """
    create trigger rollback_unset_after_first_field
    before delete on record_fields
    when old.key = 'zzz_fail_after_note'
    begin
        select raise(abort, 'forced unset rollback');
    end
    """
)
con.commit()
PY

    if run_agent_store unset "$id" note zzz_fail_after_note >/tmp/agent-store-unset-d77-rollback.out 2>/tmp/agent-store-unset-d77-rollback.err; then
      exit 1
    fi
    grep -Fq "failed to unset record" /tmp/agent-store-unset-d77-rollback.err
    grep -Fq "forced unset rollback" /tmp/agent-store-unset-d77-rollback.err
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task empty='' note=keep title=Write zzz_fail_after_note=bad"
    ;;

  find_filters_records)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-find-m2b-init.out
    open_task="$(run_agent_store create task title=Write status=open priority=high)"
    run_agent_store create task title=Ship status=done priority=low >/tmp/agent-store-find-m2b-done.out
    run_agent_store create note title=Write status=open priority=high >/tmp/agent-store-find-m2b-note.out

    expected="$open_task task priority=high status=open title=Write"
    quoted="$(run_agent_store find 'kind=task and status=open')"
    test "$quoted" = "$expected"

    multi="$(run_agent_store find kind=task and status=open)"
    test "$multi" = "$quoted"

    not_done="$(run_agent_store find kind=task and status!=done)"
    test "$not_done" = "$expected"

    field_and_kind="$(run_agent_store find priority=high and kind!=note)"
    test "$field_and_kind" = "$expected"

    none="$(run_agent_store find kind=task and status=missing)"
    test -z "$none"

    if run_agent_store find >/tmp/agent-store-find-m2b-empty.out 2>/tmp/agent-store-find-m2b-empty.err; then
      exit 1
    fi
    grep -Fq "find requires a query" /tmp/agent-store-find-m2b-empty.err
    ;;

  arbitrary_field_queries)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-find-41k-init.out
    first="$(run_agent_store create artifact title=Alpha custom_41k=blue)"
    second="$(run_agent_store create artifact title=Beta other_41k=blue)"
    run_agent_store create note title=Gamma custom_41k=red >/tmp/agent-store-find-41k-note.out

    first_line="$first artifact custom_41k=blue title=Alpha"
    got="$(run_agent_store find custom_41k=blue)"
    test "$got" = "$first_line"

    out="$(run_agent_store set "$second" later_41k=green score_41k=42)"
    test "$out" = "Updated $second"
    second_line="$second artifact later_41k=green other_41k=blue score_41k=42 title=Beta"

    got="$(run_agent_store find later_41k=green)"
    test "$got" = "$second_line"

    got="$(run_agent_store find 'score_41k>40')"
    test "$got" = "$second_line"

    test -z "$(run_agent_store find missing_41k=green)"
    ;;

  query_boolean_syntax)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-query-s5i-init.out
    open_task="$(run_agent_store create task title=Write status=open priority=high lane=beta)"
    done_task="$(run_agent_store create task title=Ship status=done priority=low lane=alpha)"
    note="$(run_agent_store create note title=Note status=open priority=high lane=gamma)"
    bug="$(run_agent_store create bug title=Bug status=open priority=medium lane=delta)"

    expected="$open_task task lane=beta priority=high status=open title=Write
$note note lane=gamma priority=high status=open title=Note"

    got="$(run_agent_store find 'kind=note or kind=task and not status=done')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    got="$(run_agent_store find '(kind=note or kind=task) and priority=high')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    got="$(run_agent_store find 'lane>=beta and lane<gamma and priority!=medium')"
    test "$got" = "$open_task task lane=beta priority=high status=open title=Write"

    got="$(run_agent_store find 'lane<=alpha')"
    test "$got" = "$done_task task lane=alpha priority=low status=done title=Ship"

    got="$(run_agent_store find 'lane>delta')"
    test "$got" = "$note note lane=gamma priority=high status=open title=Note"
    ;;

  query_argument_parity)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-query-ly7-init.out
    run_agent_store create task title=Write status=open priority=high lane=beta >/tmp/agent-store-query-ly7-open.out
    run_agent_store create task title=Ship status=done priority=low lane=alpha >/tmp/agent-store-query-ly7-done.out
    run_agent_store create note title=Note status=open priority=high lane=gamma >/tmp/agent-store-query-ly7-note.out
    run_agent_store create bug title=Bug status=open priority=medium lane=delta >/tmp/agent-store-query-ly7-bug.out

    quoted="$(run_agent_store find '(kind=note or kind=task) and lane>=beta and lane<delta and not status=done')"
    multi="$(run_agent_store find '(' kind=note or kind=task ')' and 'lane>=beta' and 'lane<delta' and not status=done)"
    test "$multi" = "$quoted"
    ;;

  query_typed_values)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-query-t2s-init.out
    high="$(run_agent_store create sample title=High score=10 due=2026-01-02 stamp=2026-01-02T12:00:00Z active=true missing=null lane=beta)"
    low="$(run_agent_store create sample title=Low score=2 due=2026-01-01 stamp=2026-01-02T08:00:00Z active=false missing=value lane=alpha)"
    text="$(run_agent_store create sample title=Textual missing=value lane=gamma)"
    sparse="$(run_agent_store create sample title=Sparse lane=delta)"

    high_line="$high sample active=true due=2026-01-02 lane=beta missing=null score=10 stamp=2026-01-02T12:00:00Z title=High"
    low_line="$low sample active=false due=2026-01-01 lane=alpha missing=value score=2 stamp=2026-01-02T08:00:00Z title=Low"
    text_line="$text sample lane=gamma missing=value title=Textual"

    got="$(run_agent_store find 'score>9')"
    test "$got" = "$high_line"

    got="$(run_agent_store find 'score<3')"
    test "$got" = "$low_line"

    got="$(run_agent_store find 'due>2026-01-01')"
    test "$got" = "$high_line"

    got="$(run_agent_store find 'stamp>=2026-01-02T09:00:00Z')"
    test "$got" = "$high_line"

    got="$(run_agent_store find 'active>false')"
    test "$got" = "$high_line"

    got="$(run_agent_store find 'missing=null')"
    test "$got" = "$high_line"

    expected="$low_line
$text_line"
    got="$(run_agent_store find 'missing!=null')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    expected="$high_line
$text_line"
    got="$(run_agent_store find 'lane>alpha and lane<zeta and title!=Sparse')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    test -z "$(run_agent_store find 'score<zzz')"
    test -z "$(run_agent_store find 'due<zzz')"
    test -z "$(run_agent_store find 'stamp<zzz')"
    test -z "$(run_agent_store find 'active<zzz')"
    test -z "$(run_agent_store find 'missing<zzz and missing=null')"
    test -z "$(run_agent_store find 'absent!=value')"

    sparse_line="$(run_agent_store get "$sparse")"
    test "$sparse_line" = "$sparse sample lane=delta title=Sparse"
    ;;

  field_value_parsing_semantics)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-fields-om5-init.out
    id="$(run_agent_store create sample initial=seed active=true due=2026-06-26 stamp=2026-06-26T12:34:56Z score=001.50 missing=null text=hello empty=)"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id sample active=true due=2026-06-26 empty='' initial=seed missing=null score=001.50 stamp=2026-06-26T12:34:56Z text=hello"

    out="$(run_agent_store set "$id" set_active=false set_due=2026-07-01 set_stamp=2026-07-01T00:00:00Z set_score=0002.75 set_missing=null set_text=world)"
    test "$out" = "Updated $id"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id sample active=true due=2026-06-26 empty='' initial=seed missing=null score=001.50 set_active=false set_due=2026-07-01 set_missing=null set_score=0002.75 set_stamp=2026-07-01T00:00:00Z set_text=world stamp=2026-06-26T12:34:56Z text=hello"

    python3 - .agent-store/store.sqlite "$id" <<'PY'
import sqlite3
import sys

db, record_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = {
    row[0]: row[1:]
    for row in con.execute(
        """
        select key, raw_value, text_value, number_value, timestamp_value, boolean_value, is_null
        from record_fields
        where record_id = ?
        """,
        (record_id,),
    )
}

def assert_row(key, raw, text, number, timestamp, boolean, is_null):
    actual = rows[key]
    assert actual[0] == raw, (key, actual)
    assert actual[1] == text, (key, actual)
    if number is None:
        assert actual[2] is None, (key, actual)
    else:
        assert abs(actual[2] - number) < 0.000001, (key, actual)
    assert actual[3] == timestamp, (key, actual)
    assert actual[4] == boolean, (key, actual)
    assert actual[5] == is_null, (key, actual)

assert_row("missing", "null", None, None, None, None, 1)
assert_row("set_missing", "null", None, None, None, None, 1)
assert_row("active", "true", None, None, None, 1, 0)
assert_row("set_active", "false", None, None, None, 0, 0)
assert_row("due", "2026-06-26", None, None, "2026-06-26", None, 0)
assert_row("stamp", "2026-06-26T12:34:56Z", None, None, "2026-06-26T12:34:56Z", None, 0)
assert_row("score", "001.50", None, 1.5, None, None, 0)
assert_row("set_score", "0002.75", None, 2.75, None, None, 0)
assert_row("text", "hello", "hello", None, None, None, 0)
assert_row("empty", "", "", None, None, None, 0)
PY
    ;;

  field_empty_null_unset_semantics)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-fields-6pq-init.out
    id="$(run_agent_store create task title=Write empty= missing=null)"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task empty='' missing=null title=Write"

    out="$(run_agent_store unset "$id" empty missing)"
    test "$out" = "Updated $id"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task title=Write"

    python3 - .agent-store/store.sqlite "$id" <<'PY'
import sqlite3
import sys

db, record_id = sys.argv[1:]
con = sqlite3.connect(db)
fields = {
    row[0]: row[1]
    for row in con.execute(
        "select key, raw_value from record_fields where record_id = ?",
        (record_id,),
    )
}
assert fields == {"title": "Write"}, fields
PY
    ;;

  record_id_generation_contract)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-ids-lbl-init.out
    ids_file="$tmp/record-ids"

    for n in 1 2 3 4 5 6 7 8; do
      id="$(run_agent_store create sample seq="$n")"
      printf "%s\n" "$id" | grep -Eq "^[a-z0-9]{6,8}$"
      run_agent_store get "$id" >/tmp/agent-store-ids-lbl-get.out
      printf "%s\n" "$id" >>"$ids_file"
    done

    unique_count="$(sort -u "$ids_file" | wc -l | tr -d ' ')"
    test "$unique_count" = "8"
    ;;

  record_id_resolution_errors)
    cd "$tmp"
    run_agent_store init >"$tmp/init.out"
    run_agent_store create seed title=seed >"$tmp/seed.out"

    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
for table in ("record_links", "record_fields", "records", "store_events"):
    con.execute(f"delete from {table}")
con.executemany(
    "insert into records (id, kind) values (?, ?)",
    [
        ("abc123", "task"),
        ("abc456", "task"),
        ("def789", "note"),
    ],
)
con.commit()
PY

    expect_failure() {
      local expected="$1"
      shift
      local label
      label="$(printf "%s" "$*" | tr -cs '[:alnum:]' '-')"
      set +e
      run_agent_store "$@" >"$tmp/$label.out" 2>"$tmp/$label.err"
      local status=$?
      set -e
      test "$status" -ne 0
      test ! -s "$tmp/$label.out"
      grep -Fq "$expected" "$tmp/$label.err"
    }

    assert_store_unchanged_after_failures() {
      python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
ids = [row[0] for row in con.execute("select id from records order by id")]
assert ids == ["abc123", "abc456", "def789"], ids
assert con.execute("select count(*) from record_links").fetchone()[0] == 0
PY
    }

    got="$(run_agent_store get abc1)"
    test "$got" = "abc123 task"
    out="$(run_agent_store set abc1 status=done)"
    test "$out" = "Updated abc123"
    out="$(run_agent_store unset abc1 status)"
    test "$out" = "Updated abc123"
    out="$(run_agent_store link abc1 blocks def7)"
    test "$out" = "Linked abc123 blocks def789"
    links="$(run_agent_store links abc1)"
    test "$links" = "out blocks def789"
    out="$(run_agent_store unlink abc1 blocks def7)"
    test "$out" = "Unlinked abc123 blocks def789"

    expect_failure "matches multiple records" get abc
    expect_failure "matches multiple records" set abc status=blocked
    expect_failure "matches multiple records" unset abc status
    expect_failure "matches multiple records" rm abc
    expect_failure "matches multiple records" links abc
    expect_failure "matches multiple records" link abc relates def7
    expect_failure "matches multiple records" link def7 relates abc
    expect_failure "matches multiple records" unlink abc relates def7
    expect_failure "matches multiple records" unlink def7 relates abc

    expect_failure "was not found" get zzzzzz
    expect_failure "was not found" set zzzzzz status=blocked
    expect_failure "was not found" unset zzzzzz status
    expect_failure "was not found" rm zzzzzz
    expect_failure "was not found" links zzzzzz
    expect_failure "was not found" link zzzzzz relates def7
    expect_failure "was not found" link def7 relates zzzzzz
    expect_failure "was not found" unlink zzzzzz relates def7
    expect_failure "was not found" unlink def7 relates zzzzzz

    assert_store_unchanged_after_failures
    ;;

  json_output)
    cd "$tmp"
    init_json="$(run_agent_store --json init)"
    python3 - "$init_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data == {"status": "initialized", "store_dir": ".agent-store"}, data
PY

    create_json="$(run_agent_store create task title=Write status=open empty= --json)"
    id="$(
      python3 - "$create_json" <<'PY'
import json
import re
import sys

data = json.loads(sys.argv[1])
assert data["status"] == "created", data
record = data["record"]
assert re.fullmatch(r"[a-z0-9]{6,8}", record["id"]), record
assert record["kind"] == "task", record
assert record["fields"] == {"empty": "", "status": "open", "title": "Write"}, record
print(record["id"])
PY
    )"

    cr_json="$(run_agent_store --json cr note title=Alias status=open)"
    python3 - "$cr_json" <<'PY'
import json
import re
import sys

data = json.loads(sys.argv[1])
assert data["status"] == "created", data
record = data["record"]
assert re.fullmatch(r"[a-z0-9]{6,8}", record["id"]), record
assert record["kind"] == "note", record
assert record["fields"] == {"status": "open", "title": "Alias"}, record
PY

    get_json="$(run_agent_store get "$id" --json)"
    find_json="$(run_agent_store find kind=task and status=open --json)"
    ls_json="$(run_agent_store --json ls kind=task and status=open)"
    set_json="$(run_agent_store set "$id" status=done --json)"
    unset_json="$(run_agent_store unset "$id" empty --json)"
    rm_json="$(run_agent_store rm "$id" --json)"

    python3 - "$id" "$get_json" "$find_json" "$ls_json" "$set_json" "$unset_json" "$rm_json" <<'PY'
import json
import sys

record_id = sys.argv[1]
get_data, find_data, ls_data, set_data, unset_data, rm_data = [
    json.loads(raw) for raw in sys.argv[2:]
]

expected_open = {
    "id": record_id,
    "kind": "task",
    "fields": {"empty": "", "status": "open", "title": "Write"},
}
assert get_data == {"record": expected_open}, get_data
assert find_data == {"records": [expected_open]}, find_data
assert ls_data == find_data, ls_data

expected_set = {
    "id": record_id,
    "kind": "task",
    "fields": {"empty": "", "status": "done", "title": "Write"},
}
assert set_data == {"status": "updated", "record": expected_set}, set_data

expected_unset = {
    "id": record_id,
    "kind": "task",
    "fields": {"status": "done", "title": "Write"},
}
assert unset_data == {"status": "updated", "record": expected_unset}, unset_data
assert rm_data == {"status": "removed", "record": expected_unset}, rm_data
PY
    ;;

  uninitialized_store_errors)
    cd "$tmp"
    expected_err="error: no agent-store found; run 'agent-store init' first"
    baseline="$(find . | sort)"
    for cmd in \
      "create task title=Write" \
      "get abc123" \
      "find kind=task" \
      "ls status=open" \
      "set abc123 status=done" \
      "unset abc123 status" \
      "rm abc123" \
      "link abc123 blocks def456" \
      "unlink abc123 blocks def456" \
      "links abc123" \
      "hook add create -- true" \
      "hook ls" \
      "hook rm abc123" \
      "ctx" \
      "--json ctx" \
      "--json create task title=Write"; do
      set +e
      # shellcheck disable=SC2086
      run_agent_store $cmd >/tmp/agent-store-noinit-8fz.out 2>/tmp/agent-store-noinit-8fz.err
      status=$?
      set -e
      test "$status" -eq 1
      test ! -s /tmp/agent-store-noinit-8fz.out
      grep -Fxq "$expected_err" /tmp/agent-store-noinit-8fz.err
    done
    test "$(find . | sort)" = "$baseline"
    test ! -e .agent-store

    run_agent_store init >/tmp/agent-store-noinit-8fz-init.out
    id="$(run_agent_store create task title=Write)"
    got="$(run_agent_store get "$id")"
    test "$got" = "$id task title=Write"

    mkdir -p nested/deeper
    (
      cd nested/deeper
      got_nested="$(run_agent_store get "$id")"
      test "$got_nested" = "$id task title=Write"
    )
    ;;

  broken_pipe_exits_quietly)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-pipe-9pe-init.out
    for i in $(seq 1 200); do
      run_agent_store create task title="Task $i" status=open >/dev/null
    done
    run_agent_store find kind=task >"$tmp/all-records.out"
    id_line="$(head -n 1 "$tmp/all-records.out")"
    id="${id_line%% *}"

    binary="$target_dir/debug/agent-store"
    test -x "$binary"

    set +e
    "$binary" find kind=task 2>/tmp/agent-store-pipe-9pe-find.err | head -c 1 >/dev/null
    find_status="${PIPESTATUS[0]}"
    "$binary" --json get "$id" 2>/tmp/agent-store-pipe-9pe-get.err | true
    get_status="${PIPESTATUS[0]}"
    set -e

    test "$find_status" -eq 0 -o "$find_status" -eq 141
    test "$get_status" -eq 0 -o "$get_status" -eq 141
    ! grep -q "panicked" /tmp/agent-store-pipe-9pe-find.err
    ! grep -q "panicked" /tmp/agent-store-pipe-9pe-get.err
    test ! -s /tmp/agent-store-pipe-9pe-find.err
    test ! -s /tmp/agent-store-pipe-9pe-get.err
    ;;

  *)
    echo "usage: $0 {create_alias_matches_create|find_alias_matches_find|set_updates_fields|unset_removes_fields|find_filters_records|arbitrary_field_queries|query_boolean_syntax|query_argument_parity|query_typed_values|field_empty_null_unset_semantics|record_id_generation_contract|record_id_resolution_errors|json_output|uninitialized_store_errors|broken_pipe_exits_quietly}" >&2
    exit 2
    ;;
esac
