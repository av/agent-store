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
    echo "usage: $0 {set_updates_fields|unset_removes_fields|find_filters_records|field_empty_null_unset_semantics}" >&2
    exit 2
    ;;
esac
