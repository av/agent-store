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

create_record() {
  local kind="$1"
  shift
  run_agent_store create "$kind" "$@"
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

  record_links_cardinality_shape)
    cd "$tmp"
    first="$(create_record task title=first)"
    second="$(create_record decision title=second)"
    third="$(create_record note title=third)"
    fourth="$(create_record milestone title=fourth)"
    python3 - .agent-store/store.sqlite "$first" "$second" "$third" "$fourth" <<'PY'
import sqlite3
import sys

db, first, second, third, fourth = sys.argv[1:]
con = sqlite3.connect(db)
con.execute("pragma foreign_keys = on")
columns = [row[1] for row in con.execute("pragma table_info(record_links)")]
assert columns == ["from_record_id", "rel", "to_record_id", "created_at"], columns
assert all("kind" not in column for column in columns), columns

links = [
    (first, "one_to_one", second),
    (first, "one_to_many", third),
    (first, "one_to_many", fourth),
    (second, "many_to_many", third),
    (second, "many_to_many", fourth),
    (third, "many_to_many", first),
]
con.executemany(
    "insert into record_links (from_record_id, rel, to_record_id) values (?, ?, ?)",
    links,
)

assert con.execute("select count(*) from record_links where rel = 'one_to_one'").fetchone()[0] == 1
assert con.execute(
    "select count(*) from record_links where rel = 'one_to_many' and from_record_id = ?",
    (first,),
).fetchone()[0] == 2
assert con.execute(
    "select count(distinct from_record_id), count(distinct to_record_id) from record_links where rel = 'many_to_many'"
).fetchone() == (2, 3)
kind_pairs = {
    row
    for row in con.execute(
        """
        select from_records.kind, to_records.kind
        from record_links
        join records as from_records on from_records.id = record_links.from_record_id
        join records as to_records on to_records.id = record_links.to_record_id
        """
    )
}
assert ("task", "decision") in kind_pairs, kind_pairs
assert ("decision", "note") in kind_pairs, kind_pairs
assert ("note", "task") in kind_pairs, kind_pairs
PY
    ;;

  record_links_columns_unique)
    cd "$tmp"
    from_id="$(create_record task title=from)"
    to_id="$(create_record task title=to)"
    python3 - .agent-store/store.sqlite "$from_id" "$to_id" <<'PY'
import sqlite3
import sys

db, from_id, to_id = sys.argv[1:]
con = sqlite3.connect(db)
con.execute("pragma foreign_keys = on")
table_info = list(con.execute("pragma table_info(record_links)"))
columns = [row[1] for row in table_info]
assert columns == ["from_record_id", "rel", "to_record_id", "created_at"], columns
primary_key = [row[1] for row in sorted((row for row in table_info if row[5]), key=lambda row: row[5])]
assert primary_key == ["from_record_id", "rel", "to_record_id"], primary_key

foreign_keys = {
    (row[3], row[2], row[4], row[6])
    for row in con.execute("pragma foreign_key_list(record_links)")
}
assert ("from_record_id", "records", "id", "CASCADE") in foreign_keys, foreign_keys
assert ("to_record_id", "records", "id", "CASCADE") in foreign_keys, foreign_keys

con.execute(
    "insert into record_links (from_record_id, rel, to_record_id) values (?, 'blocks', ?)",
    (from_id, to_id),
)
created_at = con.execute(
    "select created_at from record_links where from_record_id = ? and rel = 'blocks' and to_record_id = ?",
    (from_id, to_id),
).fetchone()[0]
assert created_at, created_at
try:
    con.execute(
        "insert into record_links (from_record_id, rel, to_record_id) values (?, 'blocks', ?)",
        (from_id, to_id),
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("duplicate link was accepted")
PY
    ;;

  record_delete_cascades_links)
    cd "$tmp"
    victim="$(create_record task title=victim status=open)"
    source="$(create_record note title=source)"
    target="$(create_record decision title=target)"
    unrelated="$(create_record task title=unrelated)"
    python3 - .agent-store/store.sqlite "$victim" "$source" "$target" "$unrelated" <<'PY'
import sqlite3
import sys

db, victim, source, target, unrelated = sys.argv[1:]
con = sqlite3.connect(db)
con.execute("pragma foreign_keys = on")
con.executemany(
    "insert into record_links (from_record_id, rel, to_record_id) values (?, ?, ?)",
    [
        (victim, "blocks", target),
        (source, "depends_on", victim),
        (source, "mentions", target),
    ],
)

con.execute("delete from records where id = ?", (victim,))

assert con.execute("select count(*) from records where id = ?", (victim,)).fetchone()[0] == 0
assert con.execute("select count(*) from record_fields where record_id = ?", (victim,)).fetchone()[0] == 0
assert con.execute(
    "select count(*) from record_links where from_record_id = ? or to_record_id = ?",
    (victim, victim),
).fetchone()[0] == 0
remaining = {
    row[0]
    for row in con.execute("select id from records where id in (?, ?, ?)", (source, target, unrelated))
}
assert remaining == {source, target, unrelated}, remaining
assert con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'mentions' and to_record_id = ?
    """,
    (source, target),
).fetchone()[0] == 1
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
    echo "usage: $0 {store_is_project_local|migrations_apply_on_open|initial_schema_tables|records_columns|record_fields_typed_columns|record_links_cardinality_shape|record_links_columns_unique|record_delete_cascades_links|migration_checksum_mismatch}" >&2
    exit 2
    ;;
esac
