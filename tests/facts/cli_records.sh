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

    run_agent_store find >/tmp/agent-store-ls-8id-find.out 2>/tmp/agent-store-ls-8id-find.err
    run_agent_store ls >/tmp/agent-store-ls-8id-ls.out 2>/tmp/agent-store-ls-8id-ls.err
    test "$(wc -l </tmp/agent-store-ls-8id-find.out)" -eq 3
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

    all="$(run_agent_store find)"
    test "$(printf "%s\n" "$all" | wc -l)" -eq 3
    printf "%s\n" "$all" | grep -Fq "$expected"
    printf "%s\n" "$all" | grep -Fq "title=Ship"
    printf "%s\n" "$all" | grep -Fq " note "
    ;;

  query_quoted_values)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-quoted-q7v-init.out
    spaced="$(run_agent_store create task note='hello world' status=open)"
    other="$(run_agent_store create task note=hello status=open)"
    blank="$(run_agent_store create task note= status=open)"

    spaced_line="$(run_agent_store get "$spaced")"
    got="$(run_agent_store find "note='hello world'")"
    test "$got" = "$spaced_line"
    got="$(run_agent_store find 'note="hello world"')"
    test "$got" = "$spaced_line"
    got="$(run_agent_store find kind=task and "note='hello world'")"
    test "$got" = "$spaced_line"

    quoteful="$(run_agent_store create task note="it's done" status=open)"
    got="$(run_agent_store find "note='it\\'s done'")"
    test "$got" = "$(run_agent_store get "$quoteful")"

    got="$(run_agent_store find "note=''")"
    test "$got" = "$(run_agent_store get "$blank")"
    not_blank="$(run_agent_store find "note!=''")"
    printf "%s\n" "$not_blank" | grep -Fq "$spaced"
    printf "%s\n" "$not_blank" | grep -Fq "$other"
    if printf "%s\n" "$not_blank" | grep -Fq "$blank"; then
      exit 1
    fi

    unquoted="$(run_agent_store find note=hello)"
    test "$unquoted" = "$other task note=hello status=open"

    if run_agent_store find "note='oops" >/tmp/agent-store-quoted-q7v-bad.out 2>/tmp/agent-store-quoted-q7v-bad.err; then
      exit 1
    fi
    grep -Fq "unterminated" /tmp/agent-store-quoted-q7v-bad.err
    ;;

  find_lists_all_records)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-listall-b4f-init.out
    first="$(run_agent_store create task title=Write)"
    second="$(run_agent_store create note title=Read)"

    all="$(run_agent_store find)"
    test "$(printf "%s\n" "$all" | wc -l)" -eq 2
    printf "%s\n" "$all" | grep -Fq "$first task title=Write"
    printf "%s\n" "$all" | grep -Fq "$second note title=Read"

    ls_all="$(run_agent_store ls)"
    test "$ls_all" = "$all"

    json_count="$(run_agent_store --json find | jq -r '.records | length')"
    test "$json_count" -eq 2
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

  query_contains_operator)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-query-ooj-init.out
    login="$(run_agent_store create task title='Fix Login Page' status=open)"
    docs="$(run_agent_store create task title='update docs' status=open)"
    note="$(run_agent_store create note title='Login notes')"

    expected_login="$login task status=open title='Fix Login Page'"
    expected_docs="$docs task status=open title='update docs'"

    # Case-insensitive substring match, in either direction.
    test "$(run_agent_store find "title~='login'")" = "$expected_login
$note note title='Login notes'"
    test "$(run_agent_store find 'kind=task and title~=LOGIN')" = "$expected_login"
    test "$(run_agent_store find "title~='fix login'")" = "$expected_login"

    # ~= applies to kind as well.
    test "$(run_agent_store find 'kind~=OTE')" = "$note note title='Login notes'"

    # No match when the substring is absent; missing fields never match.
    test -z "$(run_agent_store find 'title~=logout')"
    test -z "$(run_agent_store find 'absent~=login')"

    # Composes with not, and, or, and parentheses.
    test "$(run_agent_store find 'kind=task and not title~=login')" = "$expected_docs"
    test "$(run_agent_store find '(title~=docs or title~=logout) and kind=task')" = "$expected_docs"

    # Bare '~' without '=' is rejected.
    set +e
    run_agent_store find 'title~login' >/tmp/agent-store-query-ooj.out 2>/tmp/agent-store-query-ooj.err
    status=$?
    set -e
    test "$status" -ne 0
    grep -q "expected '=' after '~'" /tmp/agent-store-query-ooj.err
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

    got="$(run_agent_store find 'due>=2026-01-01T00:00:00Z and due<2026-01-03T00:00:00Z')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$high_line
$low_line" | sort)"

    got="$(run_agent_store find 'stamp>2026-01-02 and stamp<2026-01-03')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$high_line
$low_line" | sort)"

    got="$(run_agent_store find 'due=2026-01-02T00:00:00Z')"
    test "$got" = "$high_line"

    test -z "$(run_agent_store find 'stamp=2026-01-02')"
    test -z "$(run_agent_store find 'title>=2026-01-01')"

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
assert set(data) == {"status", "store_dir", "skills_installed", "instructions"}, data
assert data["status"] == "initialized", data
assert data["store_dir"] == ".agent-store", data
skills = data["skills_installed"]
assert isinstance(skills, list) and skills, data
assert all(path.endswith("/SKILL.md") for path in skills), skills
instructions = data["instructions"]
assert isinstance(instructions, list), data
for entry in instructions:
    assert set(entry) == {"path", "status"}, entry
    assert entry["path"] in ("AGENTS.md", "CLAUDE.md"), entry
    assert entry["status"] in ("added", "present", "missing"), entry
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
import re
import sys

record_id = sys.argv[1]
get_data, find_data, ls_data, set_data, unset_data, rm_data = [
    json.loads(raw) for raw in sys.argv[2:]
]

UTC_RFC3339 = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z")


def strip_timestamps(record):
    record = dict(record)
    for key in ("created_at", "updated_at"):
        assert UTC_RFC3339.fullmatch(record.pop(key)), record
    return record


for data in (get_data, set_data, unset_data, rm_data):
    data["record"] = strip_timestamps(data["record"])
for data in (find_data, ls_data):
    data["records"] = [strip_timestamps(record) for record in data["records"]]

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

  json_error_envelope)
    cd "$tmp"

    # Before init: runtime error is a JSON object on stderr, exit 1.
    set +e
    run_agent_store --json get abcdef >/tmp/agent-store-jerr-out 2>/tmp/agent-store-jerr-err
    status=$?
    set -e
    test "$status" -eq 1
    test ! -s /tmp/agent-store-jerr-out
    python3 - /tmp/agent-store-jerr-err <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
assert set(data) == {"error"}, data
assert "no agent-store found" in data["error"], data
PY

    run_agent_store init >/tmp/agent-store-jerr-init.out

    # Unknown record ID: envelope message matches plain mode minus the prefix.
    set +e
    run_agent_store --json get zzzzzz >/tmp/agent-store-jerr-out 2>/tmp/agent-store-jerr-err
    json_status=$?
    run_agent_store get zzzzzz >/tmp/agent-store-jerr-plain-out 2>/tmp/agent-store-jerr-plain-err
    plain_status=$?
    set -e
    test "$json_status" -eq 1
    test "$plain_status" -eq 1
    test ! -s /tmp/agent-store-jerr-out
    plain_msg="$(sed "s/^error: //" /tmp/agent-store-jerr-plain-err)"
    json_msg="$(python3 -c "import json,sys; print(json.load(open(\"/tmp/agent-store-jerr-err\"))[\"error\"])")"
    test "$json_msg" = "$plain_msg"

    # Invalid query keeps exit code 2 with the envelope.
    set +e
    run_agent_store --json find "kind=" >/tmp/agent-store-jerr-out 2>/tmp/agent-store-jerr-err
    status=$?
    set -e
    test "$status" -eq 2
    test ! -s /tmp/agent-store-jerr-out
    grep -Fq "{\"error\":\"invalid query:" /tmp/agent-store-jerr-err

    # Usage/parse errors stay plain text even with --json.
    set +e
    run_agent_store --json definitely-not-a-command >/tmp/agent-store-jerr-out 2>/tmp/agent-store-jerr-err
    status=$?
    set -e
    test "$status" -eq 2
    grep -q "^error: " /tmp/agent-store-jerr-err
    ;;

  uninitialized_store_errors)
    cd "$tmp"
    expected_err="error: no agent-store found; run 'agent-store init' first"
    expected_json_err="{\"error\":\"no agent-store found; run 'agent-store init' first\"}"
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
      case "$cmd" in
        --json*)
          grep -Fxq "$expected_json_err" /tmp/agent-store-noinit-8fz.err
          ;;
        *)
          grep -Fxq "$expected_err" /tmp/agent-store-noinit-8fz.err
          ;;
      esac
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
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    binary="$target_dir/debug/agent-store"
    test -x "$binary"
    cd "$tmp"
    "$binary" init >/tmp/agent-store-pipe-9pe-init.out
    for i in $(seq 1 200); do
      "$binary" create task title="Task $i" status=open >/dev/null
    done
    "$binary" find kind=task >"$tmp/all-records.out"
    id_line="$(head -n 1 "$tmp/all-records.out")"
    id="${id_line%% *}"

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

  identifier_validation_rejects_unsafe_names)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-ident-6vl-init.out

    reject() {
      set +e
      run_agent_store "$@" >/tmp/agent-store-ident-6vl.out 2>/tmp/agent-store-ident-6vl.err
      status=$?
      set -e
      test "$status" -eq 2
      grep -Fq "error: $expected" /tmp/agent-store-ident-6vl.err
      test ! -s /tmp/agent-store-ident-6vl.out
    }

    # Kinds with newline, whitespace, '=', control chars, or quotes are rejected.
    expected="kind contains unsupported characters"
    reject create "$(printf 'k\nd')" x=1
    reject create "a b" x=1
    reject create "k=v"
    reject create "$(printf 'k\033[31m')" x=1
    reject create "k'q" x=1
    reject create 'k"q' x=1
    reject cr "a b" x=1

    # Field keys with whitespace, control chars, or quotes are rejected.
    expected="field name contains unsupported characters"
    reject create note "a b=1"
    reject create note "$(printf 'a\tb')=1"
    reject create note "a'b=1"

    # 'kind' and 'id' are reserved field names on create and set.
    expected="'kind' is a reserved field name"
    reject create note kind=fake
    expected="'id' is a reserved field name"
    reject create note id=fake

    # 'not' is a query keyword: reserved as a kind and field name so records
    # stay queryable.
    expected="'not' is a reserved kind"
    reject create not x=1
    expected="'not' is a reserved field name"
    reject create note not=really

    id="$(run_agent_store create note ok=1)"
    expected="'kind' is a reserved field name"
    reject set "$id" kind=fake
    expected="'not' is a reserved field name"
    reject set "$id" not=really
    expected="field name contains unsupported characters"
    reject set "$id" "a b=1"

    # Previously valid identifiers keep working; values stay unrestricted.
    id2="$(run_agent_store create täsk-2.note über_key=hi dotted.key='a = "b"')"
    got="$(run_agent_store get "$id2")"
    test "$got" = "$id2 täsk-2.note dotted.key='a = \"b\"' über_key=hi"

    # No polluted record leaked into kind= queries.
    test "$(run_agent_store find kind=note)" = "$id note ok=1"
    ;;

  create_stdin_imports_jsonl)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-stdin-2p1-init.out

    # Hooks fire per imported record.
    run_agent_store hook add create 'kind=task' -- 'echo "$AGENT_STORE_ID" >> hook.log' \
      >/tmp/agent-store-stdin-2p1-hook.out

    # Multi-line import with typed values, extra keys, and a blank line.
    printf '%s\n\n%s\n' \
      '{"kind":"task","id":"ignored","created_at":"x","updated_at":"y","fields":{"title":"a","n":3,"done":true,"note":null}}' \
      '{"kind":"task","fields":{"title":"b"}}' \
      | run_agent_store create --stdin >/tmp/agent-store-stdin-2p1-ids.out
    test "$(wc -l </tmp/agent-store-stdin-2p1-ids.out)" -eq 2
    first="$(sed -n 1p /tmp/agent-store-stdin-2p1-ids.out)"
    second="$(sed -n 2p /tmp/agent-store-stdin-2p1-ids.out)"
    got="$(run_agent_store get "$first")"
    test "$got" = "$first task done=true n=3 note=null title=a"
    got="$(run_agent_store get "$second")"
    test "$got" = "$second task title=b"
    cmp -s hook.log /tmp/agent-store-stdin-2p1-ids.out

    # Round-trip: find --json output re-imports into a fresh store.
    run_agent_store find --json >/tmp/agent-store-stdin-2p1-export.json
    mkdir fresh
    (
      cd fresh
      run_agent_store init >/dev/null
      jq -c '.records[]' </tmp/agent-store-stdin-2p1-export.json | run_agent_store create --stdin >/dev/null
      test "$(run_agent_store find --count)" -eq 2
      test "$(run_agent_store find 'kind=task and title=a' --json | jq -r '.records[0].fields.n')" = 3
    )

    # --json output wraps full created record objects in a records array.
    echo '{"kind":"note","fields":{"k":"v"}}' | run_agent_store create --stdin --json \
      >/tmp/agent-store-stdin-2p1-json.out
    test "$(jq -r '.records | length' /tmp/agent-store-stdin-2p1-json.out)" -eq 1
    test "$(jq -r '.records[0].kind' /tmp/agent-store-stdin-2p1-json.out)" = note
    test "$(jq -r '.records[0].fields.k' /tmp/agent-store-stdin-2p1-json.out)" = v
    jq -e '.records[0].id and .records[0].created_at and .records[0].updated_at' \
      /tmp/agent-store-stdin-2p1-json.out >/dev/null

    # Invalid line fails naming the line number and imports nothing.
    before="$(run_agent_store find --count)"
    set +e
    printf '%s\n%s\n' '{"kind":"task","fields":{"title":"ok"}}' 'not json' \
      | run_agent_store create --stdin >/tmp/agent-store-stdin-2p1-bad.out 2>/tmp/agent-store-stdin-2p1-bad.err
    bad_status=$?
    run_agent_store create --stdin task title=x \
      >/tmp/agent-store-stdin-2p1-conflict.out 2>/tmp/agent-store-stdin-2p1-conflict.err
    conflict_status=$?
    set -e
    test "$bad_status" -ne 0
    grep -Fq "stdin line 2" /tmp/agent-store-stdin-2p1-bad.err
    test ! -s /tmp/agent-store-stdin-2p1-bad.out
    test "$(run_agent_store find --count)" = "$before"
    test "$conflict_status" -eq 2
    grep -Fq "does not accept positional argument" /tmp/agent-store-stdin-2p1-conflict.err
    ;;

  init_output_summary)
    cd "$tmp"

    # Fresh init with no AGENTS.md/CLAUDE.md: enumerates installed skills and
    # hints at the missing instructions file.
    run_agent_store init >/tmp/agent-store-init-sum-1.out
    grep -Fxq "Initialized .agent-store/" /tmp/agent-store-init-sum-1.out
    for root in .agents/skills .claude/skills; do
      for skill in agent-store agent-store-patterns agent-store-pipelines; do
        grep -Fxq "Installed $root/$skill/SKILL.md" /tmp/agent-store-init-sum-1.out
      done
    done
    grep -Fq "No AGENTS.md or CLAUDE.md found; create one and re-run \`agent-store init\`" /tmp/agent-store-init-sum-1.out

    # Re-init after AGENTS.md appears: block is added and reported.
    printf "# project\n" > AGENTS.md
    run_agent_store init >/tmp/agent-store-init-sum-2.out
    grep -Fxq "Already initialized .agent-store/" /tmp/agent-store-init-sum-2.out
    grep -Fxq "Skills already installed in .agents/skills/ and .claude/skills/" /tmp/agent-store-init-sum-2.out
    grep -Fxq "Added instructions block to AGENTS.md" /tmp/agent-store-init-sum-2.out
    ! grep -Fq "No AGENTS.md or CLAUDE.md found" /tmp/agent-store-init-sum-2.out

    # Third run is idempotent and reports the block as already present.
    run_agent_store init >/tmp/agent-store-init-sum-3.out
    grep -Fxq "Instructions block already present in AGENTS.md" /tmp/agent-store-init-sum-3.out
    test "$(grep -Fc "<!-- agent-store:start -->" AGENTS.md)" -eq 1

    # JSON envelope reports the same facts.
    run_agent_store --json init >/tmp/agent-store-init-sum-4.out
    grep -Fq "\"status\":\"already-initialized\"" /tmp/agent-store-init-sum-4.out
    grep -Fq "\"skills_installed\":[]" /tmp/agent-store-init-sum-4.out
    grep -Fq "{\"path\":\"AGENTS.md\",\"status\":\"present\"}" /tmp/agent-store-init-sum-4.out
    grep -Fq "{\"path\":\"CLAUDE.md\",\"status\":\"missing\"}" /tmp/agent-store-init-sum-4.out
    ;;

  *)
    echo "usage: $0 {create_alias_matches_create|find_alias_matches_find|set_updates_fields|unset_removes_fields|find_filters_records|arbitrary_field_queries|query_boolean_syntax|query_contains_operator|query_argument_parity|query_typed_values|field_empty_null_unset_semantics|record_id_generation_contract|record_id_resolution_errors|json_output|json_error_envelope|uninitialized_store_errors|broken_pipe_exits_quietly|identifier_validation_rejects_unsafe_names|create_stdin_imports_jsonl|init_output_summary}" >&2
    exit 2
    ;;
esac
