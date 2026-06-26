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

  *)
    echo "usage: $0 {set_updates_fields}" >&2
    exit 2
    ;;
esac
