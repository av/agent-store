#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

create_store() {
  run_agent_store create task \
    title=Write \
    text=hello \
    number=42.5 \
    stamp=2026-06-26 \
    active=true \
    missing=null \
    empty= >/dev/null
}

case "$case_name" in
  store_is_project_local)
    cd "$tmp"
    create_store
    test -f .agent-store/store.sqlite
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
assert con.execute("select name from sqlite_master where type='table' and name='records'").fetchone()
PY
    ;;

  migrations_apply_on_open)
    cd "$tmp"
    create_store
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
rows = con.execute("select version, name, length(checksum), applied_at from schema_migrations").fetchall()
assert len(rows) == 1, rows
assert rows[0][0] == 1, rows
assert rows[0][1] == "initial_schema", rows
assert rows[0][2] == 16, rows
assert rows[0][3], rows
PY
    ;;

  initial_schema_tables)
    cd "$tmp"
    create_store
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
tables = {
    row[0]
    for row in con.execute(
        "select name from sqlite_master where type='table' and name not like 'sqlite_%'"
    )
}
expected = {
    "records",
    "record_fields",
    "record_links",
    "store_events",
    "hooks",
    "hook_runs",
    "schema_migrations",
}
assert expected <= tables, sorted(expected - tables)
PY
    ;;

  records_columns)
    cd "$tmp"
    create_store
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
columns = [row[1] for row in con.execute("pragma table_info(records)")]
assert columns == ["id", "kind", "created_at", "updated_at"], columns
PY
    ;;

  record_fields_typed_columns)
    cd "$tmp"
    create_store
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
columns = [row[1] for row in con.execute("pragma table_info(record_fields)")]
assert columns == [
    "record_id",
    "key",
    "raw_value",
    "text_value",
    "number_value",
    "timestamp_value",
    "boolean_value",
    "is_null",
], columns

rows = {
    row[0]: row[1:]
    for row in con.execute(
        """
        select key, raw_value, text_value, number_value, timestamp_value, boolean_value, is_null
        from record_fields
        """
    )
}
assert rows["text"] == ("hello", "hello", None, None, None, 0), rows["text"]
assert rows["number"] == ("42.5", None, 42.5, None, None, 0), rows["number"]
assert rows["stamp"] == ("2026-06-26", None, None, "2026-06-26", None, 0), rows["stamp"]
assert rows["active"] == ("true", None, None, None, 1, 0), rows["active"]
assert rows["missing"] == ("null", None, None, None, None, 1), rows["missing"]
assert rows["empty"] == ("", "", None, None, None, 0), rows["empty"]
PY
    ;;

  migration_checksum_mismatch)
    cd "$tmp"
    mkdir .agent-store
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
con.execute(
    """
    create table schema_migrations (
        version integer primary key not null,
        name text not null,
        checksum text not null,
        applied_at text not null
    )
    """
)
con.execute(
    "insert into schema_migrations (version, name, checksum, applied_at) values (1, 'initial_schema', 'bad', '2026-01-01T00:00:00Z')"
)
con.commit()
PY
    if run_agent_store create task title=bad >/tmp/agent-store-facts-checksum.out 2>/tmp/agent-store-facts-checksum.err; then
      exit 1
    fi
    grep -Fq "checksum mismatch" /tmp/agent-store-facts-checksum.err
    grep -Fq "expected" /tmp/agent-store-facts-checksum.err
    grep -Fq "found bad" /tmp/agent-store-facts-checksum.err
    ;;

  *)
    echo "usage: $0 {store_is_project_local|migrations_apply_on_open|initial_schema_tables|records_columns|record_fields_typed_columns|migration_checksum_mismatch}" >&2
    exit 2
    ;;
esac
