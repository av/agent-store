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

  *)
    echo "usage: $0 {set_updates_fields|unset_removes_fields|find_filters_records|query_boolean_syntax|query_argument_parity|query_typed_values|field_empty_null_unset_semantics}" >&2
    exit 2
    ;;
esac
