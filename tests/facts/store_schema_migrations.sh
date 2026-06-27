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
  run_agent_store init >/dev/null
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
assert [(row[0], row[1]) for row in rows] == [
    (1, "initial_schema"),
    (2, "preserve_hook_runs_after_hook_delete"),
], rows
for row in rows:
    assert row[2] == 16, row
    assert row[3], row
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

  hard_delete_store_event_snapshot)
    cd "$tmp"
    victim="$(create_record task title=victim status=open note="hello world")"
    run_agent_store rm "$victim" >/tmp/agent-store-rm-vju.out
    grep -Fxq "Removed $victim" /tmp/agent-store-rm-vju.out
    if run_agent_store get "$victim" >/tmp/agent-store-rm-vju-get.out 2>/tmp/agent-store-rm-vju-get.err; then
      exit 1
    fi
    grep -Fq "was not found" /tmp/agent-store-rm-vju-get.err
    python3 - .agent-store/store.sqlite "$victim" <<'PY'
import json
import sqlite3
import sys

db, victim = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select event_type, record_id, record_snapshot, created_at
    from store_events
    where event_type = 'rm' and record_id = ?
    order by id
    """,
    (victim,),
).fetchall()
assert len(rows) == 1, rows
event_type, record_id, record_snapshot, created_at = rows[0]
assert event_type == "rm", rows[0]
assert record_id == victim, rows[0]
assert created_at, rows[0]

snapshot = json.loads(record_snapshot)
assert snapshot == {
    "id": victim,
    "kind": "task",
    "fields": {
        "note": "hello world",
        "status": "open",
        "title": "victim",
    },
}, snapshot
assert con.execute("select count(*) from records where id = ?", (victim,)).fetchone()[0] == 0
assert con.execute(
    "select count(*) from record_fields where record_id = ?",
    (victim,),
).fetchone()[0] == 0
PY
    ;;

  record_mutations_transactional)
    cd "$tmp"
    seed="$(create_record seed title=existing)"
    python3 - .agent-store/store.sqlite "$seed" <<'PY'
import sqlite3
import sys

db, seed = sys.argv[1:]
con = sqlite3.connect(db)
con.execute(
    """
    create trigger rollback_create_after_record
    before insert on record_fields
    when new.key = 'fail_after_record'
    begin
        select raise(abort, 'forced create rollback');
    end
    """
)
con.commit()
assert con.execute("select count(*) from records where id = ?", (seed,)).fetchone()[0] == 1
PY
    if run_agent_store create task fail_after_record=bad title=partial >/tmp/agent-store-create-0uf.out 2>/tmp/agent-store-create-0uf.err; then
      exit 1
    fi
    grep -Fq "failed to create record" /tmp/agent-store-create-0uf.err
    python3 - .agent-store/store.sqlite "$seed" <<'PY'
import sqlite3
import sys

db, seed = sys.argv[1:]
con = sqlite3.connect(db)
records = con.execute("select id, kind from records order by id").fetchall()
assert records == [(seed, "seed")], records
fields = con.execute("select record_id, key, raw_value from record_fields order by record_id, key").fetchall()
assert fields == [(seed, "title", "existing")], fields
events = con.execute("select event_type, record_id from store_events order by id").fetchall()
assert events == [("create", seed)], events
con.execute("drop trigger rollback_create_after_record")
con.commit()
PY

    victim="$(create_record task title=victim status=open)"
    python3 - .agent-store/store.sqlite "$victim" <<'PY'
import sqlite3
import sys

db, victim = sys.argv[1:]
con = sqlite3.connect(db)
assert victim.replace("'", "") == victim
con.execute(
    f"""
    create trigger rollback_rm_after_event
    before delete on records
    when old.id = '{victim}'
    begin
        select raise(abort, 'forced rm rollback');
    end
    """
)
con.commit()
PY
    if run_agent_store rm "$victim" >/tmp/agent-store-rm-0uf.out 2>/tmp/agent-store-rm-0uf.err; then
      exit 1
    fi
    grep -Fq "forced rm rollback" /tmp/agent-store-rm-0uf.err
    out="$(run_agent_store get "$victim")"
    test "$out" = "$victim task status=open title=victim"
    python3 - .agent-store/store.sqlite "$victim" <<'PY'
import sqlite3
import sys

db, victim = sys.argv[1:]
con = sqlite3.connect(db)
assert con.execute("select count(*) from records where id = ?", (victim,)).fetchone()[0] == 1
assert con.execute(
    "select count(*) from store_events where event_type = 'rm' and record_id = ?",
    (victim,),
).fetchone()[0] == 0
PY
    ;;

  persistence_open_errors_actionable)
    cd "$tmp"
    mkdir .agent-store
    printf 'not a sqlite database\n' > .agent-store/store.sqlite

    if run_agent_store find kind=task >"$tmp/persistence-open.out" 2>"$tmp/persistence-open.err"; then
      exit 1
    fi
    test ! -s "$tmp/persistence-open.out"
    grep -Fq "failed to open store" "$tmp/persistence-open.err"
    grep -Fq ".agent-store/store.sqlite" "$tmp/persistence-open.err"
    grep -Eiq "not a database|malformed|file is not a database" "$tmp/persistence-open.err"
    if grep -Eiq "panicked at|thread 'main' panicked" "$tmp/persistence-open.err"; then
      exit 1
    fi
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

  concurrent_process_writers)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-concurrent-init.out

    ready_dir="$tmp/ready"
    start_file="$tmp/start"
    mkdir "$ready_dir"
    writers=(alpha beta gamma delta)
    per_writer=10

    writer() {
      local name="$1"
      local count="$2"
      touch "$ready_dir/$name"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done
      for i in $(seq 1 "$count"); do
        "$agent_store_bin" create event writer="$name" seq="$i" batch=concurrent
      done
    }

    pids=()
    for name in "${writers[@]}"; do
      (writer "$name" "$per_writer") >"$tmp/writer-$name.out" 2>"$tmp/writer-$name.err" &
      pids+=("$!")
    done

    while [ "$(find "$ready_dir" -type f | wc -l | tr -d ' ')" -lt "${#writers[@]}" ]; do
      sleep 0.01
    done
    touch "$start_file"

    status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        status=1
      fi
    done
    if [ "$status" -ne 0 ]; then
      cat "$tmp"/writer-*.err >&2
      exit 1
    fi
    if grep -R "database is locked" "$tmp"/writer-*.err; then
      exit 1
    fi

    expected=$((${#writers[@]} * per_writer))
    total="$("$agent_store_bin" find 'kind=event and batch=concurrent' | sed '/^$/d' | wc -l | tr -d ' ')"
    test "$total" = "$expected"
    for name in "${writers[@]}"; do
      count="$("$agent_store_bin" find "kind=event and writer=$name" | sed '/^$/d' | wc -l | tr -d ' ')"
      test "$count" = "$per_writer"
    done
    ;;

  concurrent_process_writers_with_hooks)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-concurrent-hooks-init.out
    hook_side_effects="$tmp/hook-side-effects.log"
    "$agent_store_bin" hook add create -- \
      "sleep 0.03; printf '%s\n' \"\$AGENT_STORE_ID\" >> \"$hook_side_effects\"" \
      >/tmp/agent-store-concurrent-hooks-hook.out

    ready_dir="$tmp/ready"
    start_file="$tmp/start"
    mkdir "$ready_dir"
    writers=(alpha beta gamma delta epsilon zeta eta theta)
    per_writer=8

    writer() {
      local name="$1"
      local count="$2"
      touch "$ready_dir/$name"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done
      for i in $(seq 1 "$count"); do
        "$agent_store_bin" create event writer="$name" seq="$i" batch=hook-concurrent
      done
    }

    pids=()
    for name in "${writers[@]}"; do
      (writer "$name" "$per_writer") >"$tmp/writer-$name.out" 2>"$tmp/writer-$name.err" &
      pids+=("$!")
    done

    while [ "$(find "$ready_dir" -type f | wc -l | tr -d ' ')" -lt "${#writers[@]}" ]; do
      sleep 0.01
    done
    touch "$start_file"

    status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        status=1
      fi
    done
    if [ "$status" -ne 0 ]; then
      cat "$tmp"/writer-*.err >&2
      exit 1
    fi
    if grep -R "database is locked" "$tmp"/writer-*.err; then
      exit 1
    fi

    expected=$((${#writers[@]} * per_writer))
    total="$("$agent_store_bin" find 'kind=event and batch=hook-concurrent' | sed '/^$/d' | wc -l | tr -d ' ')"
    test "$total" = "$expected"
    test "$(wc -l < "$hook_side_effects" | tr -d ' ')" = "$expected"
    python3 - .agent-store/store.sqlite "$expected" <<'PY'
import sqlite3
import sys

db, expected_s = sys.argv[1:]
expected = int(expected_s)
con = sqlite3.connect(db)
hook_runs = con.execute(
    "select count(*) from hook_runs where event_type = 'create'"
).fetchone()[0]
assert hook_runs == expected, (hook_runs, expected)
PY
    ;;

  concurrent_process_mutations_with_hooks)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-concurrent-mutations-init.out

    hook_side_effects="$tmp/hook-side-effects"
    mkdir "$hook_side_effects"
    cat > hook-touch.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$1"
sleep 0.02
rel="${AGENT_STORE_REL:-none}"
target="${AGENT_STORE_TARGET_ID:-none}"
touch "$dir/${AGENT_STORE_EVENT}-${AGENT_STORE_ID}-${rel}-${target}"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x hook-touch.sh

    "$agent_store_bin" hook add set 'kind=task and status=done' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-concurrent-mutations-set-hook.out
    "$agent_store_bin" hook add link 'kind=task and status=done' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-concurrent-mutations-link-hook.out
    "$agent_store_bin" hook add unlink 'kind=task and status=done' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-concurrent-mutations-unlink-hook.out
    "$agent_store_bin" hook add rm 'kind=note and batch=mutation-hook-concurrent' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-concurrent-mutations-rm-hook.out

    ready_dir="$tmp/ready"
    start_file="$tmp/start"
    mkdir "$ready_dir"
    workers=(alpha beta gamma delta epsilon zeta eta theta)
    declare -A source_ids
    declare -A target_ids

    for name in "${workers[@]}"; do
      source_ids[$name]="$("$agent_store_bin" create task title="source-$name" worker="$name" status=pending batch=mutation-hook-concurrent)"
      target_ids[$name]="$("$agent_store_bin" create note title="target-$name" worker="$name" batch=mutation-hook-concurrent)"
    done

    mutator() {
      local name="$1"
      local source_id="$2"
      local target_id="$3"
      touch "$ready_dir/$name"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done
      "$agent_store_bin" set "$source_id" status=done phase="$name"
      "$agent_store_bin" link "$source_id" blocks "$target_id"
      "$agent_store_bin" unlink "$source_id" blocks "$target_id"
      "$agent_store_bin" rm "$target_id"
    }

    pids=()
    for name in "${workers[@]}"; do
      (mutator "$name" "${source_ids[$name]}" "${target_ids[$name]}") >"$tmp/mutator-$name.out" 2>"$tmp/mutator-$name.err" &
      pids+=("$!")
    done

    while [ "$(find "$ready_dir" -type f | wc -l | tr -d ' ')" -lt "${#workers[@]}" ]; do
      sleep 0.01
    done
    touch "$start_file"

    status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        status=1
      fi
    done
    if [ "$status" -ne 0 ]; then
      cat "$tmp"/mutator-*.err >&2
      exit 1
    fi
    if grep -R "database is locked" "$tmp"/mutator-*.err; then
      exit 1
    fi

    expected_workers="${#workers[@]}"
    expected_hook_runs=$((expected_workers * 4))
    updated_total="$("$agent_store_bin" find 'kind=task and batch=mutation-hook-concurrent and status=done' | sed '/^$/d' | wc -l | tr -d ' ')"
    test "$updated_total" = "$expected_workers"
    remaining_targets="$("$agent_store_bin" find 'kind=note and batch=mutation-hook-concurrent' | sed '/^$/d' | wc -l | tr -d ' ')"
    test "$remaining_targets" = "0"
    test "$(find "$hook_side_effects" -type f | wc -l | tr -d ' ')" = "$expected_hook_runs"

    python3 - .agent-store/store.sqlite "$expected_workers" "$expected_hook_runs" <<'PY'
import sqlite3
import sys

db, expected_workers_s, expected_hook_runs_s = sys.argv[1:]
expected_workers = int(expected_workers_s)
expected_hook_runs = int(expected_hook_runs_s)
con = sqlite3.connect(db)

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where event_type in ('set', 'link', 'unlink', 'rm')
        group by event_type
        """
    ).fetchall()
)
assert event_counts == {
    "set": expected_workers,
    "link": expected_workers,
    "unlink": expected_workers,
    "rm": expected_workers,
}, event_counts

hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where event_type in ('set', 'link', 'unlink', 'rm')
        group by event_type
        """
    ).fetchall()
)
assert hook_counts == event_counts, (hook_counts, event_counts)

total_hook_runs = con.execute(
    "select count(*) from hook_runs where event_type in ('set', 'link', 'unlink', 'rm')"
).fetchone()[0]
assert total_hook_runs == expected_hook_runs, (total_hook_runs, expected_hook_runs)

remaining_links = con.execute(
    "select count(*) from record_links where rel = 'blocks'"
).fetchone()[0]
assert remaining_links == 0, remaining_links

remaining_targets = con.execute(
    """
    select count(*)
    from records
    join record_fields on record_fields.record_id = records.id
    where records.kind = 'note'
      and record_fields.key = 'batch'
      and record_fields.raw_value = 'mutation-hook-concurrent'
    """
).fetchone()[0]
assert remaining_targets == 0, remaining_targets
PY
    ;;

  concurrent_hook_lifecycle_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-hook-lifecycle-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    side_effects="$tmp/hook-side-effects"
    mkdir "$side_effects"

    cat > slow-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
started_dir="$2"
release_file="$3"
side_effects="$4"
touch "$started_dir/$name-$AGENT_STORE_ID"
while [ ! -f "$release_file" ]; do
  sleep 0.01
done
touch "$side_effects/$name-$AGENT_STORE_ID"
printf "%s" "$name"
SH
    chmod +x slow-hook.sh

    cat > quick-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
side_effects="$2"
touch "$side_effects/$name-$AGENT_STORE_ID"
printf "%s" "$name"
SH
    chmod +x quick-hook.sh

    wait_for_file_count() {
      local dir="$1"
      local expected="$2"
      local attempts=500
      while [ "$(find "$dir" -type f | wc -l | tr -d ' ')" -lt "$expected" ]; do
        attempts=$((attempts - 1))
        if [ "$attempts" -le 0 ]; then
          find "$dir" -type f -print >&2
          return 1
        fi
        sleep 0.01
      done
    }

    remove_started="$tmp/remove-started"
    mkdir "$remove_started"
    remove_release="$tmp/remove-release"
    removed_hook_id="$("$agent_store_bin" hook add create 'kind=task and batch=hook-lifecycle-remove' -- "./slow-hook.sh removed-hook $remove_started $remove_release $side_effects")"

    "$agent_store_bin" create task title=remove-race batch=hook-lifecycle-remove >"$tmp/remove-create.out" 2>"$tmp/remove-create.err" &
    remove_pid="$!"
    wait_for_file_count "$remove_started" 1

    "$agent_store_bin" hook rm "$removed_hook_id" >"$tmp/remove-hook.out" 2>"$tmp/remove-hook.err"
    grep -Fxq "Removed $removed_hook_id" "$tmp/remove-hook.out"
    touch "$remove_release"

    set +e
    wait "$remove_pid"
    remove_create_code="$?"
    set -e
    printf "%s" "$remove_create_code" >"$tmp/remove-create.status"
    if [ "$remove_create_code" != "0" ]; then
      cat "$tmp/remove-create.err" >&2
      exit 1
    fi
    remove_record="$(cat "$tmp/remove-create.out")"
    test -f "$side_effects/removed-hook-$remove_record"

    add_started="$tmp/add-started"
    mkdir "$add_started"
    add_release="$tmp/add-release"
    holding_hook_id="$("$agent_store_bin" hook add create 'kind=task and batch=hook-lifecycle-add' -- "./slow-hook.sh holding-hook $add_started $add_release $side_effects")"

    add_workers=6
    add_pids=()
    for index in $(seq 1 "$add_workers"); do
      "$agent_store_bin" create task title="add-race-$index" batch=hook-lifecycle-add >"$tmp/add-create-$index.out" 2>"$tmp/add-create-$index.err" &
      add_pids+=("$!")
    done
    wait_for_file_count "$add_started" "$add_workers"

    add_hook_pids=()
    add_hook_count=3
    for index in $(seq 1 "$add_hook_count"); do
      "$agent_store_bin" hook add create 'kind=task and batch=hook-lifecycle-add' -- "./quick-hook.sh added-$index $side_effects" >"$tmp/add-hook-$index.out" 2>"$tmp/add-hook-$index.err" &
      add_hook_pids+=("$!")
    done
    for pid in "${add_hook_pids[@]}"; do
      wait "$pid"
    done

    added_hook_ids=()
    for index in $(seq 1 "$add_hook_count"); do
      added_hook_ids+=("$(cat "$tmp/add-hook-$index.out")")
    done

    touch "$add_release"
    add_status=0
    for pid in "${add_pids[@]}"; do
      if ! wait "$pid"; then
        add_status=1
      fi
    done
    if [ "$add_status" -ne 0 ]; then
      cat "$tmp"/add-create-*.err >&2
      exit 1
    fi

    post_add_record="$("$agent_store_bin" create task title=post-add batch=hook-lifecycle-add)"

    if grep -R "database is locked" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "failed to run hooks after Store mutation already committed" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "panicked at" "$tmp"/*.err; then
      exit 1
    fi

    "$agent_store_bin" hook ls >"$tmp/hook-ls.out" 2>"$tmp/hook-ls.err"
    if grep -Fq "$removed_hook_id " "$tmp/hook-ls.out"; then
      exit 1
    fi
    grep -Fq "$holding_hook_id " "$tmp/hook-ls.out"
    for hook_id in "${added_hook_ids[@]}"; do
      grep -Fq "$hook_id " "$tmp/hook-ls.out"
    done

    for index in $(seq 1 "$add_workers"); do
      record_id="$(cat "$tmp/add-create-$index.out")"
      test -f "$side_effects/holding-hook-$record_id"
      if compgen -G "$side_effects/added-*-$record_id" >/dev/null; then
        exit 1
      fi
    done
    test -f "$side_effects/holding-hook-$post_add_record"
    for index in $(seq 1 "$add_hook_count"); do
      test -f "$side_effects/added-$index-$post_add_record"
    done

    added_ids_arg="$(IFS=,; printf "%s" "${added_hook_ids[*]}")"
    summary="$(python3 - .agent-store/store.sqlite "$removed_hook_id" "$holding_hook_id" "$added_ids_arg" "$remove_record" "$post_add_record" "$add_workers" "$add_hook_count" <<'PY'
import sqlite3
import sys

(
    db,
    removed_hook_id,
    holding_hook_id,
    added_ids_arg,
    remove_record,
    post_add_record,
    add_workers_s,
    add_hook_count_s,
) = sys.argv[1:]
add_workers = int(add_workers_s)
add_hook_count = int(add_hook_count_s)
added_hook_ids = [item for item in added_ids_arg.split(",") if item]
assert len(added_hook_ids) == add_hook_count, added_hook_ids

con = sqlite3.connect(db)

removed_hook_rows = con.execute(
    "select count(*) from hooks where id = ?",
    (removed_hook_id,),
).fetchone()[0]
assert removed_hook_rows == 0, removed_hook_rows

present_hooks = {
    row[0]
    for row in con.execute(
        "select id from hooks where id in ({})".format(",".join("?" for _ in [holding_hook_id, *added_hook_ids])),
        [holding_hook_id, *added_hook_ids],
    )
}
expected_present = {holding_hook_id, *added_hook_ids}
assert present_hooks == expected_present, (present_hooks, expected_present)

removed_runs = con.execute(
    """
    select record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id = ?
    """,
    (removed_hook_id,),
).fetchall()
assert removed_runs == [(remove_record, 0, "removed-hook", "")], removed_runs

holding_runs = con.execute(
    "select count(*) from hook_runs where hook_id = ?",
    (holding_hook_id,),
).fetchone()[0]
assert holding_runs == add_workers + 1, holding_runs

for hook_id in added_hook_ids:
    rows = con.execute(
        "select record_id, exit_status from hook_runs where hook_id = ?",
        (hook_id,),
    ).fetchall()
    assert rows == [(post_add_record, 0)], (hook_id, rows)

record_counts = dict(
    con.execute(
        """
        select rf.raw_value, count(*)
        from records r
        join record_fields rf on rf.record_id = r.id
        where rf.key = 'batch'
          and rf.raw_value in ('hook-lifecycle-remove', 'hook-lifecycle-add')
        group by rf.raw_value
        """
    ).fetchall()
)
assert record_counts == {
    "hook-lifecycle-remove": 1,
    "hook-lifecycle-add": add_workers + 1,
}, record_counts

total_runs = con.execute(
    "select count(*) from hook_runs where hook_id in ({})".format(",".join("?" for _ in [removed_hook_id, holding_hook_id, *added_hook_ids])),
    [removed_hook_id, holding_hook_id, *added_hook_ids],
).fetchone()[0]
expected_runs = 1 + add_workers + 1 + add_hook_count
assert total_runs == expected_runs, (total_runs, expected_runs)

print(
    "removed_hook_runs={removed} holding_hook_runs={holding} added_hook_runs={added} final_hooks={final_hooks}".format(
        removed=len(removed_runs),
        holding=holding_runs,
        added=add_hook_count,
        final_hooks=len(present_hooks),
    )
)
PY
)"

    expected_side_effects=$((1 + add_workers + 1 + add_hook_count))
    side_effect_count="$(find "$side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "$expected_side_effects"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'remove-*' -o -name 'add-*' -o -name 'hook-ls.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      find "$side_effects" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-hook-lifecycle-races.md" <<EOF
# Concurrent Hook Lifecycle Race Evidence

- removed_hook_id: $removed_hook_id
- holding_hook_id: $holding_hook_id
- added_hook_ids: ${added_hook_ids[*]}
- remove_record: $remove_record
- post_add_record: $post_add_record
- add_workers: $add_workers
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_hook_lifecycle_mutation_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-hook-lifecycle-mutations-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    started_dir="$tmp/hook-started"
    side_effects="$tmp/hook-side-effects"
    release_file="$tmp/hook-release"
    mkdir "$started_dir" "$side_effects"

    cat > slow-mutation-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
started_dir="$2"
release_file="$3"
side_effects="$4"
touch "$started_dir/$name-$AGENT_STORE_ID"
while [ ! -f "$release_file" ]; do
  sleep 0.01
done
touch "$side_effects/$name-$AGENT_STORE_ID"
printf "%s" "$name"
SH
    chmod +x slow-mutation-hook.sh

    wait_for_file_count() {
      local dir="$1"
      local expected="$2"
      local attempts=500
      while [ "$(find "$dir" -type f | wc -l | tr -d ' ')" -lt "$expected" ]; do
        attempts=$((attempts - 1))
        if [ "$attempts" -le 0 ]; then
          find "$dir" -type f -print >&2
          return 1
        fi
        sleep 0.01
      done
    }

    set_record="$("$agent_store_bin" create task title=set-record batch=hook-lifecycle-mutation status=pending)"
    unset_record="$("$agent_store_bin" create task title=unset-record batch=hook-lifecycle-mutation flag=present)"
    rm_record="$("$agent_store_bin" create task title=rm-record batch=hook-lifecycle-mutation action=remove)"
    link_source="$("$agent_store_bin" create task title=link-source batch=hook-lifecycle-mutation)"
    link_target="$("$agent_store_bin" create note title=link-target batch=hook-lifecycle-mutation)"
    unlink_source="$("$agent_store_bin" create task title=unlink-source batch=hook-lifecycle-mutation)"
    unlink_target="$("$agent_store_bin" create note title=unlink-target batch=hook-lifecycle-mutation)"
    "$agent_store_bin" link "$unlink_source" blocks "$unlink_target" >"$tmp/setup-unlink-link.out" 2>"$tmp/setup-unlink-link.err"

    set_hook_id="$("$agent_store_bin" hook add set 'kind=task and batch=hook-lifecycle-mutation and status=done' -- "./slow-mutation-hook.sh set $started_dir $release_file $side_effects")"
    unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and batch=hook-lifecycle-mutation and not flag=present' -- "./slow-mutation-hook.sh unset $started_dir $release_file $side_effects")"
    rm_hook_id="$("$agent_store_bin" hook add rm 'kind=task and batch=hook-lifecycle-mutation and action=remove' -- "./slow-mutation-hook.sh rm $started_dir $release_file $side_effects")"
    link_hook_id="$("$agent_store_bin" hook add link 'kind=task and batch=hook-lifecycle-mutation' -- "./slow-mutation-hook.sh link $started_dir $release_file $side_effects")"
    unlink_hook_id="$("$agent_store_bin" hook add unlink 'kind=task and batch=hook-lifecycle-mutation' -- "./slow-mutation-hook.sh unlink $started_dir $release_file $side_effects")"

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

    run_mutation() {
      local name="$1"
      set +e
      case "$name" in
        set)
          "$agent_store_bin" set "$set_record" status=done >"$tmp/mutation-$name.out" 2>"$tmp/mutation-$name.err"
          ;;
        unset)
          "$agent_store_bin" unset "$unset_record" flag >"$tmp/mutation-$name.out" 2>"$tmp/mutation-$name.err"
          ;;
        rm)
          "$agent_store_bin" rm "$rm_record" >"$tmp/mutation-$name.out" 2>"$tmp/mutation-$name.err"
          ;;
        link)
          "$agent_store_bin" link "$link_source" blocks "$link_target" >"$tmp/mutation-$name.out" 2>"$tmp/mutation-$name.err"
          ;;
        unlink)
          "$agent_store_bin" unlink "$unlink_source" blocks "$unlink_target" >"$tmp/mutation-$name.out" 2>"$tmp/mutation-$name.err"
          ;;
      esac
      code="$?"
      set -e
      printf "%s" "$code" >"$tmp/mutation-$name.status"
    }

    mutation_names=(set unset rm link unlink)
    mutation_pids=()
    for name in "${mutation_names[@]}"; do
      (run_mutation "$name") &
      mutation_pids+=("$!")
    done

    if ! wait_for_file_count "$started_dir" "${#mutation_names[@]}"; then
      cat "$tmp"/mutation-*.err >&2
      exit 1
    fi

    declare -A hook_ids=(
      [set]="$set_hook_id"
      [unset]="$unset_hook_id"
      [rm]="$rm_hook_id"
      [link]="$link_hook_id"
      [unlink]="$unlink_hook_id"
    )

    hook_rm_pids=()
    for name in "${mutation_names[@]}"; do
      "$agent_store_bin" hook rm "${hook_ids[$name]}" >"$tmp/hook-rm-$name.out" 2>"$tmp/hook-rm-$name.err" &
      hook_rm_pids+=("$!")
    done
    hook_rm_status=0
    for pid in "${hook_rm_pids[@]}"; do
      if ! wait "$pid"; then
        hook_rm_status=1
      fi
    done
    if [ "$hook_rm_status" -ne 0 ]; then
      cat "$tmp"/hook-rm-*.err >&2
      exit 1
    fi
    for name in "${mutation_names[@]}"; do
      grep -Fxq "Removed ${hook_ids[$name]}" "$tmp/hook-rm-$name.out"
    done

    touch "$release_file"

    mutation_status=0
    for pid in "${mutation_pids[@]}"; do
      if ! wait "$pid"; then
        mutation_status=1
      fi
    done
    if [ "$mutation_status" -ne 0 ]; then
      cat "$tmp"/mutation-*.err >&2
      exit 1
    fi

    for name in "${mutation_names[@]}"; do
      test "$(cat "$tmp/mutation-$name.status")" = "0"
    done
    grep -Fxq "Updated $set_record" "$tmp/mutation-set.out"
    grep -Fxq "Updated $unset_record" "$tmp/mutation-unset.out"
    grep -Fxq "Removed $rm_record" "$tmp/mutation-rm.out"
    grep -Fxq "Linked $link_source blocks $link_target" "$tmp/mutation-link.out"
    grep -Fxq "Unlinked $unlink_source blocks $unlink_target" "$tmp/mutation-unlink.out"

    if grep -R "database is locked" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "failed to run hooks after Store mutation already committed" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "failed to record hook" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "Query returned no rows" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "panicked at" "$tmp"/*.err; then
      exit 1
    fi

    "$agent_store_bin" hook ls >"$tmp/hook-ls.out" 2>"$tmp/hook-ls.err"
    for name in "${mutation_names[@]}"; do
      if grep -Fq "${hook_ids[$name]} " "$tmp/hook-ls.out"; then
        exit 1
      fi
    done

    summary="$(python3 - \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$set_hook_id" \
      "$unset_hook_id" \
      "$rm_hook_id" \
      "$link_hook_id" \
      "$unlink_hook_id" \
      "$set_record" \
      "$unset_record" \
      "$rm_record" \
      "$link_source" \
      "$link_target" \
      "$unlink_source" \
      "$unlink_target" <<'PY'
import sqlite3
import sys

(
    db,
    event_marker_s,
    hook_marker_s,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    link_hook_id,
    unlink_hook_id,
    set_record,
    unset_record,
    rm_record,
    link_source,
    link_target,
    unlink_source,
    unlink_target,
) = sys.argv[1:]
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)
hook_ids = [set_hook_id, unset_hook_id, rm_hook_id, link_hook_id, unlink_hook_id]
con = sqlite3.connect(db)

placeholders = ",".join("?" for _ in hook_ids)
remaining_hooks = con.execute(
    f"select count(*) from hooks where id in ({placeholders})",
    hook_ids,
).fetchone()[0]
assert remaining_hooks == 0, remaining_hooks

rows = con.execute(
    f"""
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ? and hook_id in ({placeholders})
    """,
    [hook_marker, *hook_ids],
).fetchall()
observed_runs = {row[0]: row[1:] for row in rows}
expected_runs = {
    set_hook_id: ("set", set_record, 0, "set", ""),
    unset_hook_id: ("unset", unset_record, 0, "unset", ""),
    rm_hook_id: ("rm", rm_record, 0, "rm", ""),
    link_hook_id: ("link", link_source, 0, "link", ""),
    unlink_hook_id: ("unlink", unlink_source, 0, "unlink", ""),
}
assert observed_runs == expected_runs, (observed_runs, expected_runs)

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where id > ? and event_type in ('set', 'unset', 'rm', 'link', 'unlink')
        group by event_type
        """,
        (event_marker,),
    ).fetchall()
)
expected_event_counts = {"set": 1, "unset": 1, "rm": 1, "link": 1, "unlink": 1}
assert event_counts == expected_event_counts, event_counts

set_status = con.execute(
    "select raw_value from record_fields where record_id = ? and key = 'status'",
    (set_record,),
).fetchone()
assert set_status == ("done",), set_status
unset_flag_count = con.execute(
    "select count(*) from record_fields where record_id = ? and key = 'flag'",
    (unset_record,),
).fetchone()[0]
assert unset_flag_count == 0, unset_flag_count
rm_remaining = con.execute(
    "select count(*) from records where id = ?",
    (rm_record,),
).fetchone()[0]
assert rm_remaining == 0, rm_remaining
link_rows = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (link_source, link_target),
).fetchone()[0]
assert link_rows == 1, link_rows
unlink_rows = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (unlink_source, unlink_target),
).fetchone()[0]
assert unlink_rows == 0, unlink_rows

print(
    "removed_hooks={removed_hooks} hook_runs={hook_runs} events={events} link_rows={link_rows} unlink_rows={unlink_rows}".format(
        removed_hooks=len(hook_ids),
        hook_runs=len(observed_runs),
        events=sum(event_counts.values()),
        link_rows=link_rows,
        unlink_rows=unlink_rows,
    )
)
PY
)"

    side_effect_count="$(find "$side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "${#mutation_names[@]}"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'mutation-*' -o -name 'hook-rm-*' -o -name 'hook-ls.*' -o -name 'setup-unlink-link.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      find "$side_effects" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-hook-lifecycle-mutation-races.md" <<EOF
# Concurrent Hook Lifecycle Mutation Race Evidence

- set_record: $set_record
- unset_record: $unset_record
- rm_record: $rm_record
- link_source: $link_source
- link_target: $link_target
- unlink_source: $unlink_source
- unlink_target: $unlink_target
- removed_hook_ids: $set_hook_id $unset_hook_id $rm_hook_id $link_hook_id $unlink_hook_id
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_json_mutation_hook_lifecycle_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-json-mutation-hook-lifecycle-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    started_dir="$tmp/hook-started"
    side_effects="$tmp/hook-side-effects"
    release_file="$tmp/hook-release"
    churn_ids="$tmp/churn-hook-ids.txt"
    mkdir "$started_dir" "$side_effects"
    : >"$churn_ids"

    cat > slow-json-mutation-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
started_dir="$2"
release_file="$3"
side_effects="$4"
touch "$started_dir/$name-$AGENT_STORE_ID"
while [ ! -f "$release_file" ]; do
  sleep 0.01
done
touch "$side_effects/$name-$AGENT_STORE_ID"
printf "%s" "$name"
SH
    chmod +x slow-json-mutation-hook.sh

    wait_for_file_count() {
      local dir="$1"
      local expected="$2"
      local attempts=500
      while [ "$(find "$dir" -type f | wc -l | tr -d ' ')" -lt "$expected" ]; do
        attempts=$((attempts - 1))
        if [ "$attempts" -le 0 ]; then
          find "$dir" -type f -print >&2
          return 1
        fi
        sleep 0.01
      done
    }

    set_record="$("$agent_store_bin" create task title=json-set-record batch=json-mutation-hook-lifecycle status=pending)"
    unset_record="$("$agent_store_bin" create task title=json-unset-record batch=json-mutation-hook-lifecycle flag=present)"
    rm_record="$("$agent_store_bin" create task title=json-rm-record batch=json-mutation-hook-lifecycle action=remove)"

    set_hook_id="$("$agent_store_bin" hook add set 'kind=task and batch=json-mutation-hook-lifecycle and status=done' -- "./slow-json-mutation-hook.sh set $started_dir $release_file $side_effects")"
    unset_hook_id="$("$agent_store_bin" hook add unset 'kind=task and batch=json-mutation-hook-lifecycle and not flag=present' -- "./slow-json-mutation-hook.sh unset $started_dir $release_file $side_effects")"
    rm_hook_id="$("$agent_store_bin" hook add rm 'kind=task and batch=json-mutation-hook-lifecycle and action=remove' -- "./slow-json-mutation-hook.sh rm $started_dir $release_file $side_effects")"

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

    run_json_mutation() {
      local name="$1"
      set +e
      case "$name" in
        set)
          "$agent_store_bin" --json set "$set_record" status=done marker=json-set >"$tmp/json-mutation-$name.out" 2>"$tmp/json-mutation-$name.err"
          ;;
        unset)
          "$agent_store_bin" --json unset "$unset_record" flag >"$tmp/json-mutation-$name.out" 2>"$tmp/json-mutation-$name.err"
          ;;
        rm)
          "$agent_store_bin" --json rm "$rm_record" >"$tmp/json-mutation-$name.out" 2>"$tmp/json-mutation-$name.err"
          ;;
      esac
      code="$?"
      set -e
      printf "%s" "$code" >"$tmp/json-mutation-$name.status"
    }

    mutation_names=(set unset rm)
    mutation_pids=()
    for name in "${mutation_names[@]}"; do
      (run_json_mutation "$name") &
      mutation_pids+=("$!")
    done

    if ! wait_for_file_count "$started_dir" "${#mutation_names[@]}"; then
      cat "$tmp"/json-mutation-*.err >&2
      exit 1
    fi

    declare -A hook_ids=(
      [set]="$set_hook_id"
      [unset]="$unset_hook_id"
      [rm]="$rm_hook_id"
    )

    hook_rm_pids=()
    for name in "${mutation_names[@]}"; do
      "$agent_store_bin" hook rm "${hook_ids[$name]}" >"$tmp/hook-rm-$name.out" 2>"$tmp/hook-rm-$name.err" &
      hook_rm_pids+=("$!")
    done

    churn_hook() {
      local op="$1"
      local index="$2"
      local hook_id
      hook_id="$("$agent_store_bin" hook add "$op" 'kind=task and batch=json-mutation-hook-lifecycle' -- 'true')"
      printf "%s\n" "$hook_id" >>"$churn_ids"
      "$agent_store_bin" hook rm "$hook_id"
    }

    churn_pids=()
    for name in "${mutation_names[@]}"; do
      for index in 1 2 3; do
        (churn_hook "$name" "$index") >"$tmp/hook-churn-$name-$index.out" 2>"$tmp/hook-churn-$name-$index.err" &
        churn_pids+=("$!")
      done
    done

    hook_rm_status=0
    for pid in "${hook_rm_pids[@]}"; do
      if ! wait "$pid"; then
        hook_rm_status=1
      fi
    done
    if [ "$hook_rm_status" -ne 0 ]; then
      cat "$tmp"/hook-rm-*.err >&2
      exit 1
    fi
    for name in "${mutation_names[@]}"; do
      grep -Fxq "Removed ${hook_ids[$name]}" "$tmp/hook-rm-$name.out"
    done

    churn_status=0
    for pid in "${churn_pids[@]}"; do
      if ! wait "$pid"; then
        churn_status=1
      fi
    done
    if [ "$churn_status" -ne 0 ]; then
      cat "$tmp"/hook-churn-*.err >&2
      exit 1
    fi

    touch "$release_file"

    mutation_status=0
    for pid in "${mutation_pids[@]}"; do
      if ! wait "$pid"; then
        mutation_status=1
      fi
    done
    if [ "$mutation_status" -ne 0 ]; then
      cat "$tmp"/json-mutation-*.err >&2
      exit 1
    fi

    for name in "${mutation_names[@]}"; do
      test "$(cat "$tmp/json-mutation-$name.status")" = "0"
    done

    if grep -R "database is locked" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "failed to run hooks after Store mutation already committed" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "failed to record hook" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "Query returned no rows" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "panicked at" "$tmp"/*.err; then
      exit 1
    fi
    if grep -R "constraint" "$tmp"/*.err; then
      exit 1
    fi

    "$agent_store_bin" hook ls >"$tmp/hook-ls.out" 2>"$tmp/hook-ls.err"
    for name in "${mutation_names[@]}"; do
      if grep -Fq "${hook_ids[$name]} " "$tmp/hook-ls.out"; then
        exit 1
      fi
    done

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$event_marker" \
      "$hook_marker" \
      "$set_hook_id" \
      "$unset_hook_id" \
      "$rm_hook_id" \
      "$set_record" \
      "$unset_record" \
      "$rm_record" <<'PY'
from collections import Counter
import json
import pathlib
import sqlite3
import sys

(
    tmp_s,
    db,
    event_marker_s,
    hook_marker_s,
    set_hook_id,
    unset_hook_id,
    rm_hook_id,
    set_record,
    unset_record,
    rm_record,
) = sys.argv[1:]
tmp = pathlib.Path(tmp_s)
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)
hook_ids = [set_hook_id, unset_hook_id, rm_hook_id]
record_ids = {
    "set": set_record,
    "unset": unset_record,
    "rm": rm_record,
}

payloads = {}
for op in ["set", "unset", "rm"]:
    out = (tmp / f"json-mutation-{op}.out").read_text(encoding="utf-8")
    err = (tmp / f"json-mutation-{op}.err").read_text(encoding="utf-8")
    assert err == "", (op, err)
    payload = json.loads(out)
    expected_status = "removed" if op == "rm" else "updated"
    assert payload["status"] == expected_status, payload
    record = payload["record"]
    assert record["id"] == record_ids[op], payload
    assert record["kind"] == "task", payload
    fields = record["fields"]
    assert fields["batch"] == "json-mutation-hook-lifecycle", payload
    if op == "set":
        assert fields["status"] == "done", payload
        assert fields["marker"] == "json-set", payload
    elif op == "unset":
        assert "flag" not in fields, payload
    elif op == "rm":
        assert fields["action"] == "remove", payload
    payloads[op] = payload

con = sqlite3.connect(db)
placeholders = ",".join("?" for _ in hook_ids)
remaining_hooks = con.execute(
    f"select count(*) from hooks where id in ({placeholders})",
    hook_ids,
).fetchone()[0]
assert remaining_hooks == 0, remaining_hooks

churn_hook_ids = [
    line.strip()
    for line in (tmp / "churn-hook-ids.txt").read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert len(churn_hook_ids) == 9, churn_hook_ids
churn_placeholders = ",".join("?" for _ in churn_hook_ids)
remaining_churn_hooks = con.execute(
    f"select count(*) from hooks where id in ({churn_placeholders})",
    churn_hook_ids,
).fetchone()[0]
assert remaining_churn_hooks == 0, remaining_churn_hooks

rows = con.execute(
    f"""
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where id > ? and hook_id in ({placeholders})
    """,
    [hook_marker, *hook_ids],
).fetchall()
observed_runs = {row[0]: row[1:] for row in rows}
expected_runs = {
    set_hook_id: ("set", set_record, 0, "set", ""),
    unset_hook_id: ("unset", unset_record, 0, "unset", ""),
    rm_hook_id: ("rm", rm_record, 0, "rm", ""),
}
assert len(rows) == len(expected_runs), rows
assert observed_runs == expected_runs, (observed_runs, expected_runs)

churn_run_count = con.execute(
    f"select count(*) from hook_runs where id > ? and hook_id in ({churn_placeholders})",
    [hook_marker, *churn_hook_ids],
).fetchone()[0]
assert churn_run_count == 0, churn_run_count

event_rows = con.execute(
    """
    select event_type, record_id, record_snapshot
    from store_events
    where id > ? and event_type in ('set', 'unset', 'rm')
    order by id
    """,
    (event_marker,),
).fetchall()
event_counts = Counter(row[0] for row in event_rows)
assert event_counts == {"set": 1, "unset": 1, "rm": 1}, event_counts
for event_type, record_id, snapshot_raw in event_rows:
    assert record_id == record_ids[event_type], (event_type, record_id)
    snapshot = json.loads(snapshot_raw)
    assert snapshot == payloads[event_type]["record"], (snapshot, payloads[event_type])

set_fields = dict(
    con.execute(
        "select key, raw_value from record_fields where record_id = ?",
        (set_record,),
    ).fetchall()
)
assert set_fields["status"] == "done", set_fields
assert set_fields["marker"] == "json-set", set_fields
unset_flag_count = con.execute(
    "select count(*) from record_fields where record_id = ? and key = 'flag'",
    (unset_record,),
).fetchone()[0]
assert unset_flag_count == 0, unset_flag_count
rm_remaining = con.execute(
    "select count(*) from records where id = ?",
    (rm_record,),
).fetchone()[0]
assert rm_remaining == 0, rm_remaining

print(
    "json_mutations=3 removed_hooks=3 churned_hooks={} hook_runs={} events={}".format(
        len(churn_hook_ids),
        len(observed_runs),
        sum(event_counts.values()),
    )
)
PY
)"

    side_effect_count="$(find "$side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "${#mutation_names[@]}"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'json-mutation-*' -o -name 'hook-rm-*' -o -name 'hook-churn-*' -o -name 'hook-ls.*' -o -name 'churn-hook-ids.txt' \) \
        -exec cp {} "$evidence_root/logs/" \;
      find "$side_effects" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-json-mutation-hook-lifecycle-races.md" <<EOF
# Concurrent JSON Mutation Hook Lifecycle Race Evidence

- set_record: $set_record
- unset_record: $unset_record
- rm_record: $rm_record
- removed_hook_ids: $set_hook_id $unset_hook_id $rm_hook_id
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_hook_churn_reads)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-hook-churn-reads-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    seed_task="$("$agent_store_bin" create task title=ChurnSeed status=open due=2026-07-01)"
    seed_bug="$("$agent_store_bin" create bug title=ChurnBug status=open)"
    "$agent_store_bin" link "$seed_task" blocks "$seed_bug" >"$tmp/seed-link.out" 2>"$tmp/seed-link.err"

    stable_hook_count=3
    stable_hook_ids=()
    for index in $(seq 1 "$stable_hook_count"); do
      stable_hook_ids+=("$("$agent_store_bin" hook add create "kind=task and phase=stable-$index" -- true)")
    done

    removable_hook_count=24
    removable_hook_ids=()
    for index in $(seq 1 "$removable_hook_count"); do
      removable_hook_ids+=("$("$agent_store_bin" hook add rm "kind=task and phase=remove-$index" -- true)")
    done

    start_file="$tmp/churn-start"
    wait_for_start() {
      while [ ! -f "$start_file" ]; do
        sleep 0.005
      done
    }

    add_workers=6
    adds_per_worker=8
    add_worker() {
      local worker="$1"
      wait_for_start
      for index in $(seq 1 "$adds_per_worker"); do
        set +e
        "$agent_store_bin" hook add create "kind=task and batch=churn-read-$worker-$index" -- true >"$tmp/add-$worker-$index.out" 2>"$tmp/add-$worker-$index.err"
        local code="$?"
        set -e
        printf "%s" "$code" >"$tmp/add-$worker-$index.status"
      done
    }

    reader_workers=4
    reader_iterations=15
    reader_worker() {
      local worker="$1"
      wait_for_start
      for index in $(seq 1 "$reader_iterations"); do
        set +e
        "$agent_store_bin" hook ls >"$tmp/hook-ls-$worker-$index.out" 2>"$tmp/hook-ls-$worker-$index.err"
        local hook_code="$?"
        "$agent_store_bin" ctx >"$tmp/ctx-$worker-$index.out" 2>"$tmp/ctx-$worker-$index.err"
        local ctx_code="$?"
        set -e
        printf "%s" "$hook_code" >"$tmp/hook-ls-$worker-$index.status"
        printf "%s" "$ctx_code" >"$tmp/ctx-$worker-$index.status"
      done
    }

    pids=()
    for worker in $(seq 1 "$add_workers"); do
      add_worker "$worker" &
      pids+=("$!")
    done

    for index in $(seq 1 "$removable_hook_count"); do
      hook_id="${removable_hook_ids[$((index - 1))]}"
      (
        wait_for_start
        set +e
        "$agent_store_bin" hook rm "$hook_id" >"$tmp/rm-$index.out" 2>"$tmp/rm-$index.err"
        code="$?"
        set -e
        printf "%s" "$code" >"$tmp/rm-$index.status"
      ) &
      pids+=("$!")
    done

    for worker in $(seq 1 "$reader_workers"); do
      reader_worker "$worker" &
      pids+=("$!")
    done

    touch "$start_file"
    wait_status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        wait_status=1
      fi
    done
    if [ "$wait_status" -ne 0 ]; then
      find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
      exit 1
    fi

    for status_file in "$tmp"/*.status; do
      if [ "$(cat "$status_file")" != "0" ]; then
        echo "non-zero status in $status_file: $(cat "$status_file")" >&2
        find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
        exit 1
      fi
    done

    if grep -R -E "database is locked|panicked at|thread '.*' panicked|failed to (add hook|remove hook|list hooks|build Quick Context)" "$tmp"/*.err; then
      exit 1
    fi

    added_hook_ids=()
    for worker in $(seq 1 "$add_workers"); do
      for index in $(seq 1 "$adds_per_worker"); do
        hook_id="$(cat "$tmp/add-$worker-$index.out")"
        case "$hook_id" in
          ??????) ;;
          *) echo "invalid added hook id: $hook_id" >&2; exit 1 ;;
        esac
        added_hook_ids+=("$hook_id")
      done
    done
    expected_added_count=$((add_workers * adds_per_worker))
    test "${#added_hook_ids[@]}" = "$expected_added_count"

    for index in $(seq 1 "$removable_hook_count"); do
      hook_id="${removable_hook_ids[$((index - 1))]}"
      grep -Fxq "Removed $hook_id" "$tmp/rm-$index.out"
    done

    "$agent_store_bin" hook ls >"$tmp/final-hook-ls.out" 2>"$tmp/final-hook-ls.err"
    "$agent_store_bin" ctx >"$tmp/final-ctx.out" 2>"$tmp/final-ctx.err"

    stable_ids_arg="$(IFS=,; printf "%s" "${stable_hook_ids[*]}")"
    removable_ids_arg="$(IFS=,; printf "%s" "${removable_hook_ids[*]}")"
    added_ids_arg="$(IFS=,; printf "%s" "${added_hook_ids[*]}")"
    expected_final_hooks=$((stable_hook_count + expected_added_count))
    max_observable_hooks=$((stable_hook_count + removable_hook_count + expected_added_count))

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$stable_ids_arg" \
      "$removable_ids_arg" \
      "$added_ids_arg" \
      "$seed_task" \
      "$seed_bug" \
      "$stable_hook_count" \
      "$expected_final_hooks" \
      "$max_observable_hooks" <<'PY'
import glob
import re
import sqlite3
import sys
from pathlib import Path

(
    tmp_dir,
    db,
    stable_ids_arg,
    removable_ids_arg,
    added_ids_arg,
    seed_task,
    seed_bug,
    stable_hook_count_s,
    expected_final_hooks_s,
    max_observable_hooks_s,
) = sys.argv[1:]
tmp = Path(tmp_dir)
stable_ids = [item for item in stable_ids_arg.split(",") if item]
removable_ids = [item for item in removable_ids_arg.split(",") if item]
added_ids = [item for item in added_ids_arg.split(",") if item]
stable_hook_count = int(stable_hook_count_s)
expected_final_hooks = int(expected_final_hooks_s)
max_observable_hooks = int(max_observable_hooks_s)

hook_line = re.compile(
    r"^([a-z0-9]{6}) (create|set|unset|rm|link|unlink)( query=(('[^']*')|[^ ]+))? -- .+$"
)
hook_samples = sorted(glob.glob(str(tmp / "hook-ls-*.out"))) + [str(tmp / "final-hook-ls.out")]
assert hook_samples, "no hook ls samples"
for path in hook_samples:
    lines = Path(path).read_text().splitlines()
    assert lines, path
    ids = []
    for line in lines:
        match = hook_line.match(line)
        assert match, (path, line)
        ids.append(match.group(1))
    assert ids == sorted(ids), (path, ids)
    assert len(ids) == len(set(ids)), (path, ids)

ctx_samples = sorted(glob.glob(str(tmp / "ctx-*.out"))) + [str(tmp / "final-ctx.out")]
assert ctx_samples, "no ctx samples"
for path in ctx_samples:
    data = Path(path).read_bytes()
    assert len(data) <= 8192, (path, len(data))
    text = data.decode()
    assert text.startswith("Quick Context\n"), path
    assert "\nRecords: 2\n" in text, (path, text)
    assert "Record kinds:" in text, (path, text)
    hook_count_match = re.search(r"^Hooks: ([0-9]+)$", text, re.MULTILINE)
    assert hook_count_match, (path, text)
    hook_count = int(hook_count_match.group(1))
    assert stable_hook_count <= hook_count <= max_observable_hooks, (path, hook_count)
    assert "Latest activity: " in text, (path, text)
    assert "query=" not in text, (path, text)
    assert " -- " not in text, (path, text)

final_hook_lines = Path(tmp / "final-hook-ls.out").read_text().splitlines()
final_ids = {line.split(" ", 1)[0] for line in final_hook_lines}
expected_present = set(stable_ids) | set(added_ids)
assert final_ids == expected_present, (final_ids, expected_present)
assert not (set(removable_ids) & final_ids), set(removable_ids) & final_ids

final_ctx = Path(tmp / "final-ctx.out").read_text()
assert re.search(rf"^Hooks: {expected_final_hooks}$", final_ctx, re.MULTILINE), final_ctx

con = sqlite3.connect(db)
hook_count = con.execute("select count(*) from hooks").fetchone()[0]
assert hook_count == expected_final_hooks, hook_count
placeholders = ",".join("?" for _ in stable_ids + added_ids)
present = {
    row[0]
    for row in con.execute(
        f"select id from hooks where id in ({placeholders})",
        stable_ids + added_ids,
    )
}
assert present == expected_present, (present, expected_present)
placeholders = ",".join("?" for _ in removable_ids)
removed_count = con.execute(
    f"select count(*) from hooks where id in ({placeholders})",
    removable_ids,
).fetchone()[0]
assert removed_count == 0, removed_count
record_ids = {
    row[0] for row in con.execute("select id from records")
}
assert record_ids == {seed_task, seed_bug}, record_ids
link_count = con.execute(
    "select count(*) from record_links where from_record_id = ? and rel = 'blocks' and to_record_id = ?",
    (seed_task, seed_bug),
).fetchone()[0]
assert link_count == 1, link_count

print(
    "reader_hook_ls_samples={hook_samples} reader_ctx_samples={ctx_samples} added_hooks={added} removed_hooks={removed} final_hooks={final}".format(
        hook_samples=len(hook_samples),
        ctx_samples=len(ctx_samples),
        added=len(added_ids),
        removed=len(removable_ids),
        final=hook_count,
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'add-*' -o -name 'rm-*' -o -name 'hook-ls-*' -o -name 'ctx-*' -o -name 'final-*' -o -name 'seed-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-hook-churn-reads.md" <<EOF
# Concurrent Hook Churn Read Evidence

- seed_task: $seed_task
- seed_bug: $seed_bug
- stable_hook_ids: ${stable_hook_ids[*]}
- removable_hook_ids: ${removable_hook_ids[*]}
- added_hook_count: ${#added_hook_ids[@]}
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_record_readers_with_hooked_mutations)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-record-readers-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    side_effects="$tmp/hook-side-effects"
    mkdir "$side_effects"

    cat > slow-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
side_effects="$1"
sleep 0.02
rel="${AGENT_STORE_REL:-none}"
target="${AGENT_STORE_TARGET_ID:-none}"
touch "$side_effects/${AGENT_STORE_EVENT}-${AGENT_STORE_ID}-${rel}-${target}"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x slow-hook.sh

    stable_source="$("$agent_store_bin" create task title=StableSource status=open phase=stable)"
    stable_target="$("$agent_store_bin" create task title=StableTarget status=open phase=stable)"
    "$agent_store_bin" link "$stable_source" blocks "$stable_target" >"$tmp/stable-link.out" 2>"$tmp/stable-link.err"

    "$agent_store_bin" hook add create 'kind=task and phase=volatile' -- './slow-hook.sh hook-side-effects' >"$tmp/hook-create.out"
    "$agent_store_bin" hook add link 'kind=task and phase=volatile' -- './slow-hook.sh hook-side-effects' >"$tmp/hook-link.out"
    "$agent_store_bin" hook add unlink 'kind=task and phase=volatile' -- './slow-hook.sh hook-side-effects' >"$tmp/hook-unlink.out"
    "$agent_store_bin" hook add rm 'kind=task and phase=volatile' -- './slow-hook.sh hook-side-effects' >"$tmp/hook-rm.out"

    start_file="$tmp/readers-start"
    wait_for_start() {
      while [ ! -f "$start_file" ]; do
        sleep 0.005
      done
    }

    run_mutator() {
      local worker="$1"
      local iterations="$2"
      wait_for_start
      for index in $(seq 1 "$iterations"); do
        set +e
        "$agent_store_bin" create task title="Volatile-$worker-$index" status=open phase=volatile >"$tmp/create-$worker-$index.out" 2>"$tmp/create-$worker-$index.err"
        local create_code="$?"
        set -e
        printf "%s" "$create_code" >"$tmp/create-$worker-$index.status"
        if [ "$create_code" != "0" ]; then
          continue
        fi

        local record_id
        record_id="$(cat "$tmp/create-$worker-$index.out")"

        set +e
        "$agent_store_bin" link "$record_id" observes "$stable_target" >"$tmp/link-$worker-$index.out" 2>"$tmp/link-$worker-$index.err"
        local link_code="$?"
        "$agent_store_bin" unlink "$record_id" observes "$stable_target" >"$tmp/unlink-$worker-$index.out" 2>"$tmp/unlink-$worker-$index.err"
        local unlink_code="$?"
        "$agent_store_bin" rm "$record_id" >"$tmp/rm-$worker-$index.out" 2>"$tmp/rm-$worker-$index.err"
        local rm_code="$?"
        set -e
        printf "%s" "$link_code" >"$tmp/link-$worker-$index.status"
        printf "%s" "$unlink_code" >"$tmp/unlink-$worker-$index.status"
        printf "%s" "$rm_code" >"$tmp/rm-$worker-$index.status"
      done
    }

    run_reader() {
      local worker="$1"
      local iterations="$2"
      wait_for_start
      for index in $(seq 1 "$iterations"); do
        set +e
        "$agent_store_bin" find 'kind=task and phase=stable' >"$tmp/find-$worker-$index.out" 2>"$tmp/find-$worker-$index.err"
        local find_code="$?"
        "$agent_store_bin" get "$stable_source" >"$tmp/get-$worker-$index.out" 2>"$tmp/get-$worker-$index.err"
        local get_code="$?"
        "$agent_store_bin" links "$stable_source" >"$tmp/links-$worker-$index.out" 2>"$tmp/links-$worker-$index.err"
        local links_code="$?"
        set -e
        printf "%s" "$find_code" >"$tmp/find-$worker-$index.status"
        printf "%s" "$get_code" >"$tmp/get-$worker-$index.status"
        printf "%s" "$links_code" >"$tmp/links-$worker-$index.status"
      done
    }

    mutator_workers=4
    mutator_iterations=8
    reader_workers=3
    reader_iterations=25
    pids=()
    for worker in $(seq 1 "$mutator_workers"); do
      run_mutator "$worker" "$mutator_iterations" &
      pids+=("$!")
    done
    for worker in $(seq 1 "$reader_workers"); do
      run_reader "$worker" "$reader_iterations" &
      pids+=("$!")
    done

    touch "$start_file"
    wait_status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        wait_status=1
      fi
    done
    if [ "$wait_status" -ne 0 ]; then
      find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
      exit 1
    fi

    "$agent_store_bin" find 'kind=task and phase=stable' >"$tmp/final-find.out" 2>"$tmp/final-find.err"
    printf "%s" "$?" >"$tmp/final-find.status"
    "$agent_store_bin" get "$stable_source" >"$tmp/final-get.out" 2>"$tmp/final-get.err"
    printf "%s" "$?" >"$tmp/final-get.status"
    "$agent_store_bin" links "$stable_source" >"$tmp/final-links.out" 2>"$tmp/final-links.err"
    printf "%s" "$?" >"$tmp/final-links.status"

    for status_file in "$tmp"/*.status; do
      if [ "$(cat "$status_file")" != "0" ]; then
        echo "non-zero status in $status_file: $(cat "$status_file")" >&2
        find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
        exit 1
      fi
    done

    if grep -R -E "database is locked|panicked at|thread '.*' panicked|Query returned no rows|failed to (create record|link records|unlink records|remove record|find records|get record|list links)|failed to run hooks after Store mutation already committed|failed to record hook" "$tmp"/*.err; then
      exit 1
    fi

    expected_mutations=$((mutator_workers * mutator_iterations))
    expected_hook_runs=$((expected_mutations * 4))
    side_effect_count="$(find "$side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "$expected_hook_runs"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$stable_source" \
      "$stable_target" \
      "$reader_workers" \
      "$reader_iterations" \
      "$expected_mutations" \
      "$expected_hook_runs" <<'PY'
import glob
import re
import sqlite3
import sys
from pathlib import Path

(
    tmp_dir,
    db,
    stable_source,
    stable_target,
    reader_workers_s,
    reader_iterations_s,
    expected_mutations_s,
    expected_hook_runs_s,
) = sys.argv[1:]
tmp = Path(tmp_dir)
reader_workers = int(reader_workers_s)
reader_iterations = int(reader_iterations_s)
expected_mutations = int(expected_mutations_s)
expected_hook_runs = int(expected_hook_runs_s)

record_line = re.compile(r"^[a-z0-9]{6,8} [a-z][a-z0-9_-]*( [a-zA-Z0-9_.:-]+=([^ ']+|'[^']*'))*$")
stable_source_line = f"{stable_source} task phase=stable status=open title=StableSource"
stable_target_line = f"{stable_target} task phase=stable status=open title=StableTarget"
expected_find = sorted([stable_source_line, stable_target_line])
expected_get = stable_source_line
expected_links = f"out blocks {stable_target}"

find_samples = sorted(glob.glob(str(tmp / "find-*.out"))) + [str(tmp / "final-find.out")]
get_samples = sorted(glob.glob(str(tmp / "get-*.out"))) + [str(tmp / "final-get.out")]
links_samples = sorted(glob.glob(str(tmp / "links-*.out"))) + [str(tmp / "final-links.out")]
assert len(find_samples) == reader_workers * reader_iterations + 1, len(find_samples)
assert len(get_samples) == reader_workers * reader_iterations + 1, len(get_samples)
assert len(links_samples) == reader_workers * reader_iterations + 1, len(links_samples)

for path in find_samples:
    lines = Path(path).read_text().splitlines()
    assert lines == expected_find, (path, lines, expected_find)
    assert all(record_line.match(line) for line in lines), (path, lines)

for path in get_samples:
    lines = Path(path).read_text().splitlines()
    assert lines == [expected_get], (path, lines, expected_get)
    assert record_line.match(lines[0]), (path, lines[0])

for path in links_samples:
    lines = Path(path).read_text().splitlines()
    assert lines == [expected_links], (path, lines, expected_links)

con = sqlite3.connect(db)
hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where event_type in ('create', 'link', 'unlink', 'rm')
        group by event_type
        """
    ).fetchall()
)
expected_counts = {
    "create": expected_mutations,
    "link": expected_mutations,
    "unlink": expected_mutations,
    "rm": expected_mutations,
}
assert hook_counts == expected_counts, (hook_counts, expected_counts)
total_hook_runs = con.execute(
    "select count(*) from hook_runs where event_type in ('create', 'link', 'unlink', 'rm')"
).fetchone()[0]
assert total_hook_runs == expected_hook_runs, (total_hook_runs, expected_hook_runs)

volatile_records = con.execute(
    """
    select count(*)
    from records
    join record_fields on record_fields.record_id = records.id
    where record_fields.key = 'phase'
      and record_fields.raw_value = 'volatile'
    """
).fetchone()[0]
assert volatile_records == 0, volatile_records
volatile_links = con.execute(
    "select count(*) from record_links where rel = 'observes'"
).fetchone()[0]
assert volatile_links == 0, volatile_links
stable_link = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (stable_source, stable_target),
).fetchone()[0]
assert stable_link == 1, stable_link

print(
    "find_samples={find_samples} get_samples={get_samples} links_samples={links_samples} hooked_mutations={mutations} hook_runs={hook_runs}".format(
        find_samples=len(find_samples),
        get_samples=len(get_samples),
        links_samples=len(links_samples),
        mutations=expected_mutations,
        hook_runs=total_hook_runs,
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'create-*' -o -name 'link-*' -o -name 'unlink-*' -o -name 'rm-*' -o -name 'find-*' -o -name 'get-*' -o -name 'links-*' -o -name 'final-*' -o -name 'stable-*' -o -name 'hook-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      find "$side_effects" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-record-readers-with-hooked-mutations.md" <<EOF
# Concurrent Record Readers With Hooked Mutations Evidence

- stable_source: $stable_source
- stable_target: $stable_target
- mutator_workers: $mutator_workers
- mutator_iterations: $mutator_iterations
- reader_workers: $reader_workers
- reader_iterations: $reader_iterations
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_json_record_readers_with_hooked_mutations)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-json-record-readers-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    side_effects="$tmp/hook-side-effects"
    ids_dir="$tmp/reader-candidates"
    mkdir "$side_effects" "$ids_dir"

    cat > slow-json-hook.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
side_effects="$1"
sleep 0.03
rel="${AGENT_STORE_REL:-none}"
target="${AGENT_STORE_TARGET_ID:-none}"
touch "$side_effects/${AGENT_STORE_EVENT}-${AGENT_STORE_ID}-${rel}-${target}-$$-${RANDOM:-0}"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x slow-json-hook.sh

    stable_source="$("$agent_store_bin" create task title=JsonStableSource status=open batch=json-stable)"
    stable_target="$("$agent_store_bin" create note title=JsonStableTarget status=open batch=json-stable)"
    "$agent_store_bin" link "$stable_source" blocks "$stable_target" >"$tmp/stable-link.out" 2>"$tmp/stable-link.err"

    "$agent_store_bin" hook add create 'kind=task and batch=json-volatile' -- './slow-json-hook.sh hook-side-effects' >"$tmp/hook-create.out"
    "$agent_store_bin" hook add link 'kind=task and batch=json-volatile' -- './slow-json-hook.sh hook-side-effects' >"$tmp/hook-link.out"
    "$agent_store_bin" hook add unlink 'kind=task and batch=json-volatile' -- './slow-json-hook.sh hook-side-effects' >"$tmp/hook-unlink.out"
    "$agent_store_bin" hook add rm 'kind=task and batch=json-volatile' -- './slow-json-hook.sh hook-side-effects' >"$tmp/hook-rm.out"

    start_file="$tmp/json-readers-start"
    wait_for_start() {
      while [ ! -f "$start_file" ]; do
        sleep 0.005
      done
    }

    latest_candidate_id() {
      local latest
      latest="$(find "$ids_dir" -maxdepth 1 -type f | sort | tail -n 1 || true)"
      if [ -n "$latest" ]; then
        cat "$latest"
      else
        printf "%s\n" "$stable_source"
      fi
    }

    run_json_mutator() {
      local worker="$1"
      local iterations="$2"
      wait_for_start
      for index in $(seq 1 "$iterations"); do
        set +e
        "$agent_store_bin" create task title="JsonVolatile-$worker-$index" status=open batch=json-volatile >"$tmp/create-$worker-$index.out" 2>"$tmp/create-$worker-$index.err"
        local create_code="$?"
        set -e
        printf "%s" "$create_code" >"$tmp/create-$worker-$index.status"
        if [ "$create_code" != "0" ]; then
          continue
        fi

        local record_id
        record_id="$(cat "$tmp/create-$worker-$index.out")"
        printf "%s\n" "$record_id" >"$tmp/candidate-$worker-$index.tmp"
        mv "$tmp/candidate-$worker-$index.tmp" "$ids_dir/candidate-$worker-$index.id"
        sleep 0.005

        set +e
        "$agent_store_bin" link "$record_id" observes "$stable_target" >"$tmp/link-$worker-$index.out" 2>"$tmp/link-$worker-$index.err"
        local link_code="$?"
        "$agent_store_bin" unlink "$record_id" observes "$stable_target" >"$tmp/unlink-$worker-$index.out" 2>"$tmp/unlink-$worker-$index.err"
        local unlink_code="$?"
        "$agent_store_bin" rm "$record_id" >"$tmp/rm-$worker-$index.out" 2>"$tmp/rm-$worker-$index.err"
        local rm_code="$?"
        set -e
        printf "%s" "$link_code" >"$tmp/link-$worker-$index.status"
        printf "%s" "$unlink_code" >"$tmp/unlink-$worker-$index.status"
        printf "%s" "$rm_code" >"$tmp/rm-$worker-$index.status"
      done
    }

    run_json_reader() {
      local worker="$1"
      local iterations="$2"
      wait_for_start
      for index in $(seq 1 "$iterations"); do
        local candidate
        candidate="$(latest_candidate_id)"
        printf "%s\n" "$candidate" >"$tmp/candidate-$worker-$index.id"

        set +e
        "$agent_store_bin" --json find 'kind=task and batch=json-volatile' >"$tmp/find-$worker-$index.out" 2>"$tmp/find-$worker-$index.err"
        local find_code="$?"
        "$agent_store_bin" --json get "$candidate" >"$tmp/get-$worker-$index.out" 2>"$tmp/get-$worker-$index.err"
        local get_code="$?"
        "$agent_store_bin" --json links "$candidate" >"$tmp/links-$worker-$index.out" 2>"$tmp/links-$worker-$index.err"
        local links_code="$?"
        set -e

        printf "%s" "$find_code" >"$tmp/find-$worker-$index.status"
        printf "%s" "$get_code" >"$tmp/get-$worker-$index.status"
        printf "%s" "$links_code" >"$tmp/links-$worker-$index.status"
        sleep 0.002
      done
    }

    mutator_workers=4
    mutator_iterations=8
    reader_workers=4
    reader_iterations=30
    pids=()
    for worker in $(seq 1 "$mutator_workers"); do
      run_json_mutator "$worker" "$mutator_iterations" &
      pids+=("$!")
    done
    for worker in $(seq 1 "$reader_workers"); do
      run_json_reader "$worker" "$reader_iterations" &
      pids+=("$!")
    done

    touch "$start_file"
    wait_status=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        wait_status=1
      fi
    done
    if [ "$wait_status" -ne 0 ]; then
      find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
      exit 1
    fi

    "$agent_store_bin" --json find 'kind=task and batch=json-volatile' >"$tmp/final-find.out" 2>"$tmp/final-find.err"
    printf "%s" "$?" >"$tmp/final-find.status"
    "$agent_store_bin" --json get "$stable_source" >"$tmp/final-get.out" 2>"$tmp/final-get.err"
    printf "%s" "$?" >"$tmp/final-get.status"
    "$agent_store_bin" --json links "$stable_source" >"$tmp/final-links.out" 2>"$tmp/final-links.err"
    printf "%s" "$?" >"$tmp/final-links.status"

    for status_file in "$tmp"/create-*.status "$tmp"/link-*.status "$tmp"/unlink-*.status "$tmp"/rm-*.status "$tmp"/find-*.status "$tmp"/final-find.status "$tmp"/final-get.status "$tmp"/final-links.status; do
      if [ "$(cat "$status_file")" != "0" ]; then
        echo "non-zero status in $status_file: $(cat "$status_file")" >&2
        find "$tmp" -maxdepth 1 -type f -name '*.err' -print -exec cat {} \; >&2
        exit 1
      fi
    done

    if grep -R -E "database is locked|panicked at|thread '.*' panicked|Query returned no rows|failed to (create record|link records|unlink records|remove record|find records)|failed to run hooks after Store mutation already committed|failed to record hook" "$tmp"/*.err; then
      exit 1
    fi

    expected_mutations=$((mutator_workers * mutator_iterations))
    expected_hook_runs=$((expected_mutations * 4))
    side_effect_count="$(find "$side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "$expected_hook_runs"

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$stable_source" \
      "$stable_target" \
      "$reader_workers" \
      "$reader_iterations" \
      "$expected_mutations" \
      "$expected_hook_runs" <<'PY'
import glob
import json
import re
import sqlite3
import sys
from pathlib import Path

(
    tmp_dir,
    db,
    stable_source,
    stable_target,
    reader_workers_s,
    reader_iterations_s,
    expected_mutations_s,
    expected_hook_runs_s,
) = sys.argv[1:]
tmp = Path(tmp_dir)
reader_workers = int(reader_workers_s)
reader_iterations = int(reader_iterations_s)
expected_mutations = int(expected_mutations_s)
expected_hook_runs = int(expected_hook_runs_s)
id_re = re.compile(r"^[a-z0-9]{6,8}$")


def read_status(path):
    return Path(path).read_text().strip()


def load_json(path):
    text = Path(path).read_text()
    assert text.strip(), path
    return json.loads(text)


def assert_record_shape(record):
    assert set(record) == {"id", "kind", "fields"}, record
    assert id_re.fullmatch(record["id"]), record
    assert isinstance(record["kind"], str), record
    assert isinstance(record["fields"], dict), record


def assert_volatile_record(record):
    assert_record_shape(record)
    assert record["kind"] == "task", record
    assert record["fields"].get("batch") == "json-volatile", record
    assert record["fields"].get("status") == "open", record
    assert record["fields"].get("title", "").startswith("JsonVolatile-"), record


def assert_stable_record(record):
    assert_record_shape(record)
    assert record == {
        "id": stable_source,
        "kind": "task",
        "fields": {
            "batch": "json-stable",
            "status": "open",
            "title": "JsonStableSource",
        },
    }, record


def assert_edge_shape(edge):
    assert set(edge) == {"direction", "rel", "record_id"}, edge
    assert edge["direction"] in {"out", "in"}, edge
    assert isinstance(edge["rel"], str), edge
    assert id_re.fullmatch(edge["record_id"]), edge


find_samples = sorted(glob.glob(str(tmp / "find-*.out"))) + [str(tmp / "final-find.out")]
get_samples = sorted(glob.glob(str(tmp / "get-*.out")))
links_samples = sorted(glob.glob(str(tmp / "links-*.out")))
assert len(find_samples) == reader_workers * reader_iterations + 1, len(find_samples)
assert len(get_samples) == reader_workers * reader_iterations, len(get_samples)
assert len(links_samples) == reader_workers * reader_iterations, len(links_samples)

for path in find_samples:
    status_path = path[:-4] + ".status"
    err_path = path[:-4] + ".err"
    assert read_status(status_path) == "0", (path, Path(err_path).read_text())
    assert Path(err_path).read_text() == "", (path, Path(err_path).read_text())
    data = load_json(path)
    assert set(data) == {"records"}, data
    assert isinstance(data["records"], list), data
    for record in data["records"]:
        assert_volatile_record(record)

get_success = 0
get_not_found = 0
volatile_get_samples = 0
for path in get_samples:
    name = Path(path).name
    suffix = name[len("get-") : -len(".out")]
    candidate = (tmp / f"candidate-{suffix}.id").read_text().strip()
    status = read_status(path[:-4] + ".status")
    stderr = Path(path[:-4] + ".err").read_text()
    stdout = Path(path).read_text()
    if candidate != stable_source:
        volatile_get_samples += 1

    if status == "0":
        assert stderr == "", (path, stderr)
        data = json.loads(stdout)
        assert set(data) == {"record"}, data
        record = data["record"]
        assert record["id"] == candidate, (path, record, candidate)
        if candidate == stable_source:
            assert_stable_record(record)
        else:
            assert_volatile_record(record)
        get_success += 1
    else:
        assert candidate != stable_source, (path, candidate, stderr)
        assert stdout == "", (path, stdout)
        assert "was not found" in stderr, (path, stderr)
        get_not_found += 1

links_success = 0
links_not_found = 0
for path in links_samples:
    name = Path(path).name
    suffix = name[len("links-") : -len(".out")]
    candidate = (tmp / f"candidate-{suffix}.id").read_text().strip()
    status = read_status(path[:-4] + ".status")
    stderr = Path(path[:-4] + ".err").read_text()
    stdout = Path(path).read_text()

    if status == "0":
        assert stderr == "", (path, stderr)
        data = json.loads(stdout)
        assert set(data) == {"record_id", "links"}, data
        assert data["record_id"] == candidate, (path, data, candidate)
        assert isinstance(data["links"], list), data
        for edge in data["links"]:
            assert_edge_shape(edge)
        if candidate == stable_source:
            assert data["links"] == [
                {"direction": "out", "rel": "blocks", "record_id": stable_target}
            ], data
        else:
            assert all(
                edge == {"direction": "out", "rel": "observes", "record_id": stable_target}
                for edge in data["links"]
            ), data
        links_success += 1
    else:
        assert candidate != stable_source, (path, candidate, stderr)
        assert stdout == "", (path, stdout)
        assert "was not found" in stderr, (path, stderr)
        links_not_found += 1

assert volatile_get_samples > 0, volatile_get_samples
assert get_success > 0, get_success
assert get_not_found > 0, get_not_found
assert links_success > 0, links_success
assert links_not_found > 0, links_not_found

final_get = load_json(tmp / "final-get.out")
assert set(final_get) == {"record"}, final_get
assert_stable_record(final_get["record"])
final_links = load_json(tmp / "final-links.out")
assert final_links == {
    "record_id": stable_source,
    "links": [{"direction": "out", "rel": "blocks", "record_id": stable_target}],
}, final_links
final_find = load_json(tmp / "final-find.out")
assert final_find == {"records": []}, final_find

con = sqlite3.connect(db)
hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where event_type in ('create', 'link', 'unlink', 'rm')
        group by event_type
        """
    ).fetchall()
)
expected_counts = {
    "create": expected_mutations,
    "link": expected_mutations,
    "unlink": expected_mutations,
    "rm": expected_mutations,
}
assert hook_counts == expected_counts, (hook_counts, expected_counts)
total_hook_runs = con.execute(
    "select count(*) from hook_runs where event_type in ('create', 'link', 'unlink', 'rm')"
).fetchone()[0]
assert total_hook_runs == expected_hook_runs, (total_hook_runs, expected_hook_runs)

volatile_records = con.execute(
    """
    select count(*)
    from records
    join record_fields on record_fields.record_id = records.id
    where record_fields.key = 'batch'
      and record_fields.raw_value = 'json-volatile'
    """
).fetchone()[0]
assert volatile_records == 0, volatile_records
volatile_links = con.execute(
    "select count(*) from record_links where rel = 'observes'"
).fetchone()[0]
assert volatile_links == 0, volatile_links
stable_link = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (stable_source, stable_target),
).fetchone()[0]
assert stable_link == 1, stable_link

print(
    "json_find_samples={find_samples} json_get_success={get_success} json_get_not_found={get_not_found} json_links_success={links_success} json_links_not_found={links_not_found} hooked_mutations={mutations} hook_runs={hook_runs}".format(
        find_samples=len(find_samples),
        get_success=get_success,
        get_not_found=get_not_found,
        links_success=links_success,
        links_not_found=links_not_found,
        mutations=expected_mutations,
        hook_runs=total_hook_runs,
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'create-*' -o -name 'link-*' -o -name 'unlink-*' -o -name 'rm-*' -o -name 'find-*' -o -name 'get-*' -o -name 'links-*' -o -name 'candidate-*' -o -name 'final-*' -o -name 'stable-*' -o -name 'hook-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      find "$ids_dir" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      find "$side_effects" -maxdepth 1 -type f -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-json-record-readers-with-hooked-mutations.md" <<EOF
# Concurrent JSON Record Readers With Hooked Mutations Evidence

- stable_source: $stable_source
- stable_target: $stable_target
- mutator_workers: $mutator_workers
- mutator_iterations: $mutator_iterations
- reader_workers: $reader_workers
- reader_iterations: $reader_iterations
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_link_record_disappearance_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-link-rm-race-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    hook_side_effects="$tmp/hook-side-effects"
    mkdir "$hook_side_effects"
    cat > hook-touch.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$1"
printf "%s:%s:%s:%s\n" "$AGENT_STORE_EVENT" "$AGENT_STORE_ID" "${AGENT_STORE_REL:-none}" "${AGENT_STORE_TARGET_ID:-none}" >> "$dir/hook.log"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x hook-touch.sh

    pair_count=12
    for index in $(seq 1 "$pair_count"); do
      source_id="$("$agent_store_bin" create task title="source-$index" batch=disappear-race status=open)"
      target_id="$("$agent_store_bin" create note title="target-$index" batch=disappear-race)"
      printf "%s" "$source_id" >"$tmp/source-$index.id"
      printf "%s" "$target_id" >"$tmp/target-$index.id"
      "$agent_store_bin" link "$source_id" blocks "$target_id" >"$tmp/setup-link-$index.out" 2>"$tmp/setup-link-$index.err"
    done

    "$agent_store_bin" hook add link 'kind=task and batch=disappear-race and link.out=blocks' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-link-rm-race-link-hook.out
    "$agent_store_bin" hook add unlink 'kind=task and batch=disappear-race' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-link-rm-race-unlink-hook.out

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

    ready_dir="$tmp/race-ready"
    start_file="$tmp/race-start"
    mkdir "$ready_dir"

    run_pair_worker() {
      local op="$1"
      local index="$2"
      local source_id
      local target_id
      source_id="$(cat "$tmp/source-$index.id")"
      target_id="$(cat "$tmp/target-$index.id")"

      touch "$ready_dir/$op-$index"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done

      set +e
      case "$op" in
        link)
          "$agent_store_bin" link "$source_id" blocks "$target_id" >"$tmp/race-$op-$index.out" 2>"$tmp/race-$op-$index.err"
          ;;
        unlink)
          "$agent_store_bin" unlink "$source_id" blocks "$target_id" >"$tmp/race-$op-$index.out" 2>"$tmp/race-$op-$index.err"
          ;;
        rm-source)
          "$agent_store_bin" rm "$source_id" >"$tmp/race-$op-$index.out" 2>"$tmp/race-$op-$index.err"
          ;;
        rm-target)
          "$agent_store_bin" rm "$target_id" >"$tmp/race-$op-$index.out" 2>"$tmp/race-$op-$index.err"
          ;;
      esac
      code="$?"
      set -e
      printf "%s" "$code" >"$tmp/race-$op-$index.status"
    }

    pids=()
    for index in $(seq 1 "$pair_count"); do
      for op in link unlink rm-source rm-target; do
        (run_pair_worker "$op" "$index") &
        pids+=("$!")
      done
    done

    expected_workers=$((pair_count * 4))
    while [ "$(find "$ready_dir" -type f | wc -l | tr -d ' ')" -lt "$expected_workers" ]; do
      sleep 0.01
    done
    touch "$start_file"

    for pid in "${pids[@]}"; do
      wait "$pid"
    done

    if grep -R "database is locked" "$tmp"/race-*.err; then
      exit 1
    fi
    if grep -R -E "failed to load (link|unlink) hook record" "$tmp"/race-*.err; then
      exit 1
    fi

    for index in $(seq 1 "$pair_count"); do
      source_id="$(cat "$tmp/source-$index.id")"
      target_id="$(cat "$tmp/target-$index.id")"

      for op in link unlink; do
        code="$(cat "$tmp/race-$op-$index.status")"
        if [ "$code" = "0" ]; then
          case "$op" in
            link) grep -Fxq "Linked $source_id blocks $target_id" "$tmp/race-$op-$index.out" ;;
            unlink) grep -Fxq "Unlinked $source_id blocks $target_id" "$tmp/race-$op-$index.out" ;;
          esac
        else
          grep -Fq "was not found" "$tmp/race-$op-$index.err"
        fi
      done

      for op in rm-source rm-target; do
        code="$(cat "$tmp/race-$op-$index.status")"
        record_id="$source_id"
        if [ "$op" = "rm-target" ]; then
          record_id="$target_id"
        fi
        if [ "$code" = "0" ]; then
          grep -Fxq "Removed $record_id" "$tmp/race-$op-$index.out"
        else
          grep -Fq "was not found" "$tmp/race-$op-$index.err"
        fi
      done
    done

    trigger_link_source="$("$agent_store_bin" create task title=trigger-link-source batch=disappear-race status=open)"
    trigger_link_target="$("$agent_store_bin" create note title=trigger-link-target batch=disappear-race)"
    python3 - .agent-store/store.sqlite "$trigger_link_source" <<'PY'
import sqlite3
import sys

db, source_id = sys.argv[1:]
assert source_id.isalnum(), source_id
con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys = ON")
con.executescript(
    f"""
    create trigger delete_link_source_after_event
    after insert on store_events
    when new.event_type = 'link' and new.record_id = '{source_id}'
    begin
      delete from records where id = new.record_id;
    end
    """
)
con.commit()
PY
    set +e
    "$agent_store_bin" link "$trigger_link_source" blocks "$trigger_link_target" >"$tmp/trigger-link.out" 2>"$tmp/trigger-link.err"
    trigger_link_code="$?"
    set -e
    printf "%s" "$trigger_link_code" >"$tmp/trigger-link.status"
    if [ "$trigger_link_code" != "0" ]; then
      cat "$tmp/trigger-link.err" >&2
      exit 1
    fi
    grep -Fxq "Linked $trigger_link_source blocks $trigger_link_target" "$tmp/trigger-link.out"

    trigger_unlink_source="$("$agent_store_bin" create task title=trigger-unlink-source batch=disappear-race status=open)"
    trigger_unlink_target="$("$agent_store_bin" create note title=trigger-unlink-target batch=disappear-race)"
    "$agent_store_bin" link "$trigger_unlink_source" blocks "$trigger_unlink_target" >"$tmp/trigger-unlink-setup.out" 2>"$tmp/trigger-unlink-setup.err"
    python3 - .agent-store/store.sqlite "$trigger_unlink_source" <<'PY'
import sqlite3
import sys

db, source_id = sys.argv[1:]
assert source_id.isalnum(), source_id
con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys = ON")
con.executescript(
    f"""
    create trigger delete_unlink_source_after_event
    after insert on store_events
    when new.event_type = 'unlink' and new.record_id = '{source_id}'
    begin
      delete from records where id = new.record_id;
    end
    """
)
con.commit()
PY
    set +e
    "$agent_store_bin" unlink "$trigger_unlink_source" blocks "$trigger_unlink_target" >"$tmp/trigger-unlink.out" 2>"$tmp/trigger-unlink.err"
    trigger_unlink_code="$?"
    set -e
    printf "%s" "$trigger_unlink_code" >"$tmp/trigger-unlink.status"
    if [ "$trigger_unlink_code" != "0" ]; then
      cat "$tmp/trigger-unlink.err" >&2
      exit 1
    fi
    grep -Fxq "Unlinked $trigger_unlink_source blocks $trigger_unlink_target" "$tmp/trigger-unlink.out"

    if grep -R "database is locked" "$tmp"/trigger-*.err; then
      exit 1
    fi
    if grep -R -E "failed to load (link|unlink) hook record" "$tmp"/trigger-*.err; then
      exit 1
    fi

    summary="$(python3 - .agent-store/store.sqlite "$event_marker" "$hook_marker" <<'PY'
import sqlite3
import sys

db, event_marker_s, hook_marker_s = sys.argv[1:]
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)
con = sqlite3.connect(db)

dangling_links = con.execute(
    """
    select count(*)
    from record_links l
    left join records source on source.id = l.from_record_id
    left join records target on target.id = l.to_record_id
    where source.id is null or target.id is null
    """
).fetchone()[0]
assert dangling_links == 0, dangling_links

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where id > ? and event_type in ('link', 'unlink')
        group by event_type
        """,
        (event_marker,),
    ).fetchall()
)
hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where id > ? and event_type in ('link', 'unlink')
        group by event_type
        """,
        (hook_marker,),
    ).fetchall()
)
assert event_counts == hook_counts, (event_counts, hook_counts)
print(
    "link_events={link} unlink_events={unlink} hook_runs={hooks} dangling_links={dangling}".format(
        link=event_counts.get("link", 0),
        unlink=event_counts.get("unlink", 0),
        hooks=sum(hook_counts.values()),
        dangling=dangling_links,
    )
)
PY
)"

    side_effect_count="0"
    if [ -f "$hook_side_effects/hook.log" ]; then
      side_effect_count="$(wc -l < "$hook_side_effects/hook.log" | tr -d ' ')"
    fi

    hook_run_count="$(printf "%s\n" "$summary" | sed -E 's/.*hook_runs=([0-9]+).*/\1/')"
    test "$side_effect_count" = "$hook_run_count"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'race-*' -o -name 'trigger-*' -o -name 'setup-link-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      if [ -f "$hook_side_effects/hook.log" ]; then
        cp "$hook_side_effects/hook.log" "$evidence_root/logs/hook.log"
      fi
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-link-record-disappearance-races.md" <<EOF
# Concurrent Link/Record Disappearance Race Evidence

- raced_pairs: $pair_count
- cli_workers: $expected_workers
- trigger_link_source: $trigger_link_source
- trigger_unlink_source: $trigger_unlink_source
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_set_unset_link_snapshot_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-set-unset-link-snapshot-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    hook_side_effects="$tmp/hook-side-effects"
    mkdir "$hook_side_effects"
    cat > hook-touch.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$1"
printf "%s:%s:%s\n" "$AGENT_STORE_EVENT" "$AGENT_STORE_ID" "$AGENT_STORE_KIND" >> "$dir/hook.log"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x hook-touch.sh

    set_source="$("$agent_store_bin" create task title=set-source batch=snapshot-set status=open)"
    set_target="$("$agent_store_bin" create note title=set-target batch=snapshot-set)"
    "$agent_store_bin" link "$set_source" blocks "$set_target" >"$tmp/setup-set-link.out" 2>"$tmp/setup-set-link.err"
    "$agent_store_bin" hook add set 'kind=task and batch=snapshot-set and status=done and link.out=blocks' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-set-link-snapshot-hook.out

    unset_source="$("$agent_store_bin" create task title=unset-source batch=snapshot-unset status=open flag=present)"
    unset_target="$("$agent_store_bin" create note title=unset-target batch=snapshot-unset)"
    "$agent_store_bin" link "$unset_source" blocks "$unset_target" >"$tmp/setup-unset-link.out" 2>"$tmp/setup-unset-link.err"
    "$agent_store_bin" hook add unset 'kind=task and batch=snapshot-unset and not flag=present and link.out=blocks' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-unset-link-snapshot-hook.out

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

    python3 - .agent-store/store.sqlite "$set_source" "$unset_source" <<'PY'
import sqlite3
import sys

db, set_source, unset_source = sys.argv[1:]
assert set_source.isalnum(), set_source
assert unset_source.isalnum(), unset_source
con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys = ON")
con.executescript(
    f"""
    create trigger delete_set_source_after_event
    after insert on store_events
    when new.event_type = 'set' and new.record_id = '{set_source}'
    begin
      delete from records where id = new.record_id;
    end;

    create trigger delete_unset_source_after_event
    after insert on store_events
    when new.event_type = 'unset' and new.record_id = '{unset_source}'
    begin
      delete from records where id = new.record_id;
    end;
    """
)
con.commit()
PY

    set +e
    "$agent_store_bin" set "$set_source" status=done >"$tmp/trigger-set.out" 2>"$tmp/trigger-set.err"
    set_code="$?"
    "$agent_store_bin" unset "$unset_source" flag >"$tmp/trigger-unset.out" 2>"$tmp/trigger-unset.err"
    unset_code="$?"
    set -e
    printf "%s" "$set_code" >"$tmp/trigger-set.status"
    printf "%s" "$unset_code" >"$tmp/trigger-unset.status"

    if [ "$set_code" != "0" ]; then
      cat "$tmp/trigger-set.err" >&2
      exit 1
    fi
    if [ "$unset_code" != "0" ]; then
      cat "$tmp/trigger-unset.err" >&2
      exit 1
    fi
    grep -Fxq "Updated $set_source" "$tmp/trigger-set.out"
    grep -Fxq "Updated $unset_source" "$tmp/trigger-unset.out"

    if grep -R "database is locked" "$tmp"/trigger-*.err; then
      exit 1
    fi
    if grep -R "failed to load hook" "$tmp"/trigger-*.err; then
      exit 1
    fi

    summary="$(python3 - .agent-store/store.sqlite "$event_marker" "$hook_marker" "$set_source" "$unset_source" <<'PY'
import sqlite3
import sys

db, event_marker_s, hook_marker_s, set_source, unset_source = sys.argv[1:]
event_marker = int(event_marker_s)
hook_marker = int(hook_marker_s)
con = sqlite3.connect(db)

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where id > ? and event_type in ('set', 'unset')
        group by event_type
        """,
        (event_marker,),
    ).fetchall()
)
hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where id > ? and event_type in ('set', 'unset')
        group by event_type
        """,
        (hook_marker,),
    ).fetchall()
)
assert event_counts == {"set": 1, "unset": 1}, event_counts
assert hook_counts == event_counts, (event_counts, hook_counts)
remaining_sources = con.execute(
    "select count(*) from records where id in (?, ?)",
    (set_source, unset_source),
).fetchone()[0]
assert remaining_sources == 0, remaining_sources
dangling_links = con.execute(
    """
    select count(*)
    from record_links l
    left join records source on source.id = l.from_record_id
    left join records target on target.id = l.to_record_id
    where source.id is null or target.id is null
    """
).fetchone()[0]
assert dangling_links == 0, dangling_links
print(
    "set_events={set_events} unset_events={unset_events} hook_runs={hook_runs} remaining_sources={remaining_sources} dangling_links={dangling_links}".format(
        set_events=event_counts.get("set", 0),
        unset_events=event_counts.get("unset", 0),
        hook_runs=sum(hook_counts.values()),
        remaining_sources=remaining_sources,
        dangling_links=dangling_links,
    )
)
PY
)"

    side_effect_count="0"
    if [ -f "$hook_side_effects/hook.log" ]; then
      side_effect_count="$(wc -l < "$hook_side_effects/hook.log" | tr -d ' ')"
    fi
    test "$side_effect_count" = "2"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'trigger-*' -o -name 'setup-*-link.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp "$hook_side_effects/hook.log" "$evidence_root/logs/hook.log"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-set-unset-link-snapshot-races.md" <<EOF
# Concurrent Set/Unset Link Snapshot Race Evidence

- set_source: $set_source
- unset_source: $unset_source
- $summary
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  create_rm_link_snapshot_hooks)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-create-rm-link-snapshot-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    cat > hook-log.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf "%s:%s:%s\n" "$AGENT_STORE_EVENT" "$AGENT_STORE_ID" "$1" >> hook.log
printf "%s" "$1"
SH
    chmod +x hook-log.sh

    create_target="$("$agent_store_bin" create note title=create-target batch=create-rm-link-snapshot)"
    create_hook_id="$("$agent_store_bin" hook add create 'kind=task and batch=create-rm-link-snapshot and link.out=blocks' -- './hook-log.sh create-link-match')"
    rm_hook_id="$("$agent_store_bin" hook add rm 'kind=task and batch=create-rm-link-snapshot and link.out=blocks' -- './hook-log.sh rm-link-match')"

    python3 - .agent-store/store.sqlite "$create_target" <<'PY'
import sqlite3
import sys

db, create_target = sys.argv[1:]
assert create_target.isalnum(), create_target
con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys = ON")
con.executescript(
    f"""
    create trigger link_created_record_after_event
    after insert on store_events
    when new.event_type = 'create'
    begin
      insert or ignore into record_links (from_record_id, rel, to_record_id)
      values (new.record_id, 'blocks', '{create_target}');
    end;
    """
)
con.commit()
PY

    "$agent_store_bin" create task title=create-source batch=create-rm-link-snapshot >"$tmp/create.out" 2>"$tmp/create.err"
    create_record="$(cat "$tmp/create.out")"
    test -s "$tmp/create.out"

    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("drop trigger link_created_record_after_event")
con.commit()
PY

    rm_source="$("$agent_store_bin" create task title=rm-source batch=create-rm-link-snapshot)"
    rm_target="$("$agent_store_bin" create note title=rm-target batch=create-rm-link-snapshot)"
    "$agent_store_bin" link "$rm_source" blocks "$rm_target" >"$tmp/rm-setup-link.out" 2>"$tmp/rm-setup-link.err"

    set +e
    "$agent_store_bin" rm "$rm_source" >"$tmp/rm.out" 2>"$tmp/rm.err"
    rm_code="$?"
    set -e
    printf "%s" "$rm_code" >"$tmp/rm.status"
    if [ "$rm_code" != "0" ]; then
      cat "$tmp/rm.err" >&2
      exit 1
    fi
    grep -Fxq "Removed $rm_source" "$tmp/rm.out"

    if grep -R "failed to load hook" "$tmp"/*.err; then
      exit 1
    fi

    summary="$(python3 - .agent-store/store.sqlite "$create_hook_id" "$rm_hook_id" "$create_record" "$rm_source" <<'PY'
import sqlite3
import sys

db, create_hook_id, rm_hook_id, create_record, rm_source = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary
    from hook_runs
    where hook_id in (?, ?)
    order by id
    """,
    (create_hook_id, rm_hook_id),
).fetchall()
expected = [(rm_hook_id, "rm", rm_source, 0, "rm-link-match", "")]
assert rows == expected, rows
create_links = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks'
    """,
    (create_record,),
).fetchone()[0]
assert create_links == 1, create_links
remaining_rm_links = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? or to_record_id = ?
    """,
    (rm_source, rm_source),
).fetchone()[0]
assert remaining_rm_links == 0, remaining_rm_links
print(
    "create_hook_runs=0 rm_hook_runs=1 create_post_event_links={create_links} remaining_rm_links={remaining_rm_links}".format(
        create_links=create_links,
        remaining_rm_links=remaining_rm_links,
    )
)
PY
)"

    expected_log="$(printf "rm:%s:rm-link-match\n" "$rm_source")"
    test "$(cat hook.log)" = "$expected_log"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'create.*' -o -name 'rm.*' -o -name 'rm-setup-link.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp hook.log "$evidence_root/logs/hook.log"
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/create-rm-link-snapshot-hooks.md" <<EOF
# Create/Rm Link Snapshot Hook Evidence

- create_record: $create_record
- rm_source: $rm_source
- $summary
- hook_side_effects: 1
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_same_record_and_link_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-same-target-races-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    hook_side_effects="$tmp/hook-side-effects"
    mkdir "$hook_side_effects"
    cat > hook-touch.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$1"
sleep 0.02
rel="${AGENT_STORE_REL:-none}"
target="${AGENT_STORE_TARGET_ID:-none}"
touch "$dir/${AGENT_STORE_EVENT}-${AGENT_STORE_ID}-${rel}-${target}-$$-${RANDOM:-0}"
printf "%s" "$AGENT_STORE_EVENT"
SH
    chmod +x hook-touch.sh

    "$agent_store_bin" hook add link 'kind=task and batch=same-target-link' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-same-target-link-hook.out
    "$agent_store_bin" hook add unlink 'kind=task and batch=same-target-link' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-same-target-unlink-hook.out
    "$agent_store_bin" hook add set 'kind=task and batch=same-target-record' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-same-target-set-hook.out
    "$agent_store_bin" hook add unset 'kind=task and batch=same-target-record' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-same-target-unset-hook.out
    "$agent_store_bin" hook add rm 'kind=task and batch=same-target-record' -- './hook-touch.sh hook-side-effects' >/tmp/agent-store-same-target-rm-hook.out

    source_id="$("$agent_store_bin" create task title=source batch=same-target-link status=open)"
    target_id="$("$agent_store_bin" create note title=target batch=same-target-link)"
    record_id="$("$agent_store_bin" create task title=victim batch=same-target-record status=pending flag=present)"

    run_started_workers() {
      local prefix="$1"
      local expected="$2"
      local ready_dir="$tmp/$prefix-ready"
      local start_file="$tmp/$prefix-start"

      while [ "$(find "$ready_dir" -type f | wc -l | tr -d ' ')" -lt "$expected" ]; do
        sleep 0.01
      done
      touch "$start_file"
    }

    run_link_worker() {
      local prefix="$1"
      local name="$2"
      local command_name="$3"
      local ready_dir="$tmp/$prefix-ready"
      local start_file="$tmp/$prefix-start"

      touch "$ready_dir/$name"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done
      set +e
      "$agent_store_bin" "$command_name" "$source_id" blocks "$target_id" >"$tmp/$prefix-$name.out" 2>"$tmp/$prefix-$name.err"
      code="$?"
      set -e
      printf "%s" "$code" >"$tmp/$prefix-$name.status"
    }

    link_workers=(alpha beta gamma delta epsilon zeta eta theta)
    mkdir "$tmp/link-ready"
    pids=()
    for name in "${link_workers[@]}"; do
      (run_link_worker link "$name" link) &
      pids+=("$!")
    done
    run_started_workers link "${#link_workers[@]}"
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    if grep -R "database is locked" "$tmp"/link-*.err; then
      exit 1
    fi
    for name in "${link_workers[@]}"; do
      test "$(cat "$tmp/link-$name.status")" = "0"
      grep -Fxq "Linked $source_id blocks $target_id" "$tmp/link-$name.out"
    done
    python3 - .agent-store/store.sqlite "$source_id" "$target_id" "${#link_workers[@]}" <<'PY'
import sqlite3
import sys

db, source_id, target_id, expected_s = sys.argv[1:]
expected = int(expected_s)
con = sqlite3.connect(db)
link_rows = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (source_id, target_id),
).fetchone()[0]
assert link_rows == 1, link_rows
event_count = con.execute(
    "select count(*) from store_events where event_type = 'link' and record_id = ?",
    (source_id,),
).fetchone()[0]
assert event_count == expected, (event_count, expected)
hook_count = con.execute(
    "select count(*) from hook_runs where event_type = 'link' and record_id = ?",
    (source_id,),
).fetchone()[0]
assert hook_count == expected, (hook_count, expected)
PY

    unlink_workers=(alpha beta gamma delta epsilon zeta eta theta)
    mkdir "$tmp/unlink-ready"
    pids=()
    for name in "${unlink_workers[@]}"; do
      (run_link_worker unlink "$name" unlink) &
      pids+=("$!")
    done
    run_started_workers unlink "${#unlink_workers[@]}"
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    if grep -R "database is locked" "$tmp"/unlink-*.err; then
      exit 1
    fi
    for name in "${unlink_workers[@]}"; do
      test "$(cat "$tmp/unlink-$name.status")" = "0"
      grep -Fxq "Unlinked $source_id blocks $target_id" "$tmp/unlink-$name.out"
    done
    python3 - .agent-store/store.sqlite "$source_id" "$target_id" "${#unlink_workers[@]}" <<'PY'
import sqlite3
import sys

db, source_id, target_id, expected_s = sys.argv[1:]
expected = int(expected_s)
con = sqlite3.connect(db)
link_rows = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (source_id, target_id),
).fetchone()[0]
assert link_rows == 0, link_rows
event_count = con.execute(
    "select count(*) from store_events where event_type = 'unlink' and record_id = ?",
    (source_id,),
).fetchone()[0]
assert event_count == expected, (event_count, expected)
hook_count = con.execute(
    "select count(*) from hook_runs where event_type = 'unlink' and record_id = ?",
    (source_id,),
).fetchone()[0]
assert hook_count == expected, (hook_count, expected)
PY

    run_record_worker() {
      local prefix="$1"
      local name="$2"
      local op="$3"
      local ready_dir="$tmp/$prefix-ready"
      local start_file="$tmp/$prefix-start"

      touch "$ready_dir/$name"
      while [ ! -f "$start_file" ]; do
        sleep 0.01
      done
      set +e
      case "$op" in
        set)
          "$agent_store_bin" set "$record_id" status="$prefix-$name" "worker_$name=done" >"$tmp/$prefix-$name.out" 2>"$tmp/$prefix-$name.err"
          ;;
        unset)
          "$agent_store_bin" unset "$record_id" flag >"$tmp/$prefix-$name.out" 2>"$tmp/$prefix-$name.err"
          ;;
        rm)
          "$agent_store_bin" rm "$record_id" >"$tmp/$prefix-$name.out" 2>"$tmp/$prefix-$name.err"
          ;;
      esac
      code="$?"
      set -e
      printf "%s" "$code" >"$tmp/$prefix-$name.status"
    }

    record_workers=(set_a set_b set_c set_d unset_a unset_b unset_c unset_d)
    mkdir "$tmp/record-ready"
    pids=()
    for name in "${record_workers[@]}"; do
      case "$name" in
        set_*) op=set ;;
        unset_*) op=unset ;;
      esac
      (run_record_worker record "$name" "$op") &
      pids+=("$!")
    done
    run_started_workers record "${#record_workers[@]}"
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    if grep -R "database is locked" "$tmp"/record-*.err; then
      exit 1
    fi
    for name in "${record_workers[@]}"; do
      test "$(cat "$tmp/record-$name.status")" = "0"
      grep -Fxq "Updated $record_id" "$tmp/record-$name.out"
    done

    mixed_workers=(set_e set_f set_g unset_e unset_f unset_g rm_a rm_b rm_c)
    mkdir "$tmp/mixed-ready"
    pids=()
    for name in "${mixed_workers[@]}"; do
      case "$name" in
        set_*) op=set ;;
        unset_*) op=unset ;;
        rm_*) op=rm ;;
      esac
      (run_record_worker mixed "$name" "$op") &
      pids+=("$!")
    done
    run_started_workers mixed "${#mixed_workers[@]}"
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    if grep -R "database is locked" "$tmp"/mixed-*.err; then
      exit 1
    fi

    record_set_successes=4
    record_unset_successes=4
    mixed_set_successes=0
    mixed_unset_successes=0
    rm_successes=0
    for name in "${mixed_workers[@]}"; do
      code="$(cat "$tmp/mixed-$name.status")"
      case "$name" in
        set_*)
          if [ "$code" = "0" ]; then
            grep -Fxq "Updated $record_id" "$tmp/mixed-$name.out"
            mixed_set_successes=$((mixed_set_successes + 1))
          else
            grep -Fq "was not found" "$tmp/mixed-$name.err"
          fi
          ;;
        unset_*)
          if [ "$code" = "0" ]; then
            grep -Fxq "Updated $record_id" "$tmp/mixed-$name.out"
            mixed_unset_successes=$((mixed_unset_successes + 1))
          else
            grep -Fq "was not found" "$tmp/mixed-$name.err"
          fi
          ;;
        rm_*)
          if [ "$code" = "0" ]; then
            grep -Fxq "Removed $record_id" "$tmp/mixed-$name.out"
            rm_successes=$((rm_successes + 1))
          else
            grep -Fq "was not found" "$tmp/mixed-$name.err"
          fi
          ;;
      esac
    done
    test "$rm_successes" = "1"

    expected_set=$((record_set_successes + mixed_set_successes))
    expected_unset=$((record_unset_successes + mixed_unset_successes))
    expected_total_hooks=$((${#link_workers[@]} + ${#unlink_workers[@]} + expected_set + expected_unset + rm_successes))

    python3 - \
      .agent-store/store.sqlite \
      "$source_id" \
      "$target_id" \
      "$record_id" \
      "${#link_workers[@]}" \
      "${#unlink_workers[@]}" \
      "$expected_set" \
      "$expected_unset" \
      "$rm_successes" \
      "$expected_total_hooks" <<'PY'
import sqlite3
import sys

(
    db,
    source_id,
    target_id,
    record_id,
    expected_link_s,
    expected_unlink_s,
    expected_set_s,
    expected_unset_s,
    expected_rm_s,
    expected_total_hooks_s,
) = sys.argv[1:]
expected = {
    "link": int(expected_link_s),
    "unlink": int(expected_unlink_s),
    "set": int(expected_set_s),
    "unset": int(expected_unset_s),
    "rm": int(expected_rm_s),
}
expected_total_hooks = int(expected_total_hooks_s)
con = sqlite3.connect(db)

link_rows = con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (source_id, target_id),
).fetchone()[0]
assert link_rows == 0, link_rows
remaining_record = con.execute(
    "select count(*) from records where id = ?",
    (record_id,),
).fetchone()[0]
assert remaining_record == 0, remaining_record

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where (record_id = ? and event_type in ('link', 'unlink'))
           or (record_id = ? and event_type in ('set', 'unset', 'rm'))
        group by event_type
        """,
        (source_id, record_id),
    ).fetchall()
)
assert event_counts == expected, (event_counts, expected)

hook_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from hook_runs
        where (record_id = ? and event_type in ('link', 'unlink'))
           or (record_id = ? and event_type in ('set', 'unset', 'rm'))
        group by event_type
        """,
        (source_id, record_id),
    ).fetchall()
)
assert hook_counts == expected, (hook_counts, expected)
total_hook_runs = con.execute(
    """
    select count(*)
    from hook_runs
    where (record_id = ? and event_type in ('link', 'unlink'))
       or (record_id = ? and event_type in ('set', 'unset', 'rm'))
    """,
    (source_id, record_id),
).fetchone()[0]
assert total_hook_runs == expected_total_hooks, (total_hook_runs, expected_total_hooks)
PY

    side_effect_count="$(find "$hook_side_effects" -type f | wc -l | tr -d ' ')"
    test "$side_effect_count" = "$expected_total_hooks"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'link-*' -o -name 'unlink-*' -o -name 'record-*' -o -name 'mixed-*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-same-record-link-races.md" <<EOF
# Concurrent Same-Target Race Evidence

- source_record: $source_id
- target_record: $target_id
- raced_record: $record_id
- link_attempts: ${#link_workers[@]}
- unlink_attempts: ${#unlink_workers[@]}
- committed_set_events: $expected_set
- committed_unset_events: $expected_unset
- committed_rm_events: $rm_successes
- hook_side_effects: $side_effect_count
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_id_prefix_resolution_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-id-prefix-race-init.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    source_prefix="aa"
    target_prefix="bb"
    source_one="aa1001"
    source_two="aa2002"
    target_one="bb1001"
    target_two="bb2002"
    worker_count=3
    iterations=10

    stop_file="$tmp/churn.stop"
    python3 - .agent-store/store.sqlite "$source_one" "$source_two" "$target_one" "$target_two" "$tmp/churn.log" "$stop_file" <<'PY' >"$tmp/churn.out" 2>"$tmp/churn.err" &
import os
import sqlite3
import sys
import time

db, source_one, source_two, target_one, target_two, log_path, stop_path = sys.argv[1:]
source_ids = [source_one, source_two]
target_ids = [target_one, target_two]
all_ids = source_ids + target_ids
states = [
    ([], []),
    ([source_one], []),
    ([], [target_one]),
    ([source_one], [target_one]),
    ([source_one, source_two], [target_one]),
    ([source_one], [target_one, target_two]),
    ([source_one, source_two], [target_one, target_two]),
]

con = sqlite3.connect(db, timeout=10.0)
con.execute("PRAGMA foreign_keys = ON")
con.execute("PRAGMA busy_timeout = 10000")

def insert_record(record_id, kind, role, state):
    con.execute(
        "insert into records (id, kind) values (?, ?)",
        (record_id, kind),
    )
    fields = {
        "batch": "prefix-resolution-race",
        "role": role,
        "state": state,
    }
    for key, value in fields.items():
        con.execute(
            "insert into record_fields (record_id, key, raw_value, text_value) values (?, ?, ?, ?)",
            (record_id, key, value, value),
        )

with open(log_path, "w", encoding="utf-8") as log:
    cycle = 0
    while cycle < 1000 and (cycle < 80 or not os.path.exists(stop_path)):
        sources, targets = states[cycle % len(states)]
        state = f"cycle-{cycle}"
        con.execute("begin immediate")
        con.execute(
            "delete from records where id in ({})".format(",".join("?" for _ in all_ids)),
            all_ids,
        )
        for record_id in sources:
            insert_record(record_id, "task", "source", state)
        for record_id in targets:
            insert_record(record_id, "note", "target", state)
        con.commit()
        log.write(
            f"{cycle}:sources={','.join(sources) or '-'} targets={','.join(targets) or '-'}\n"
        )
        log.flush()
        cycle += 1
        time.sleep(0.01)

    con.execute("begin immediate")
    con.execute(
        "delete from records where id in ({})".format(",".join("?" for _ in all_ids)),
        all_ids,
    )
    insert_record(source_one, "task", "source", "final")
    insert_record(target_one, "note", "target", "final")
    con.commit()
PY
    churn_pid="$!"

    run_prefix_worker() {
      local op="$1"
      local worker="$2"
      local index

      for index in $(seq 1 "$iterations"); do
        local prefix="$tmp/prefix-$op-$worker-$index"
        set +e
        case "$op" in
          get)
            "$agent_store_bin" get "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          set)
            "$agent_store_bin" set "$source_prefix" "status=$worker-$index" >"$prefix.out" 2>"$prefix.err"
            ;;
          unset)
            "$agent_store_bin" unset "$source_prefix" status >"$prefix.out" 2>"$prefix.err"
            ;;
          rm)
            "$agent_store_bin" rm "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          link)
            "$agent_store_bin" link "$source_prefix" blocks "$target_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          unlink)
            "$agent_store_bin" unlink "$source_prefix" blocks "$target_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          links)
            "$agent_store_bin" links "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
        esac
        local code="$?"
        set -e
        printf "%s" "$code" >"$prefix.status"
        sleep 0.005
      done
    }

    pids=()
    for op in get set unset rm link unlink links; do
      for worker in $(seq 1 "$worker_count"); do
        (run_prefix_worker "$op" "$worker") &
        pids+=("$!")
      done
    done

    for pid in "${pids[@]}"; do
      wait "$pid"
    done

    touch "$stop_file"
    if ! wait "$churn_pid"; then
      cat "$tmp/churn.err" >&2
      exit 1
    fi

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$worker_count" \
      "$iterations" \
      "$source_one" \
      "$source_two" \
      "$target_one" \
      "$target_two" <<'PY'
import pathlib
import re
import sqlite3
import sys

tmp = pathlib.Path(sys.argv[1])
db = sys.argv[2]
worker_count = int(sys.argv[3])
iterations = int(sys.argv[4])
source_ids = set(sys.argv[5:7])
target_ids = set(sys.argv[7:9])
all_ids = source_ids | target_ids
ops = ["get", "set", "unset", "rm", "link", "unlink", "links"]
bad_fragments = [
    "database is locked",
    "panicked",
    "thread 'main'",
    "foreign key constraint",
    "constraint failed",
]
counts = {
    op: {"success": 0, "ambiguous": 0, "not_found": 0}
    for op in ops
}
link_success_pairs = set()

def read(path):
    return path.read_text(encoding="utf-8") if path.exists() else ""

for op in ops:
    for worker in range(1, worker_count + 1):
        for index in range(1, iterations + 1):
            base = tmp / f"prefix-{op}-{worker}-{index}"
            status = read(base.with_suffix(".status")).strip()
            out = read(base.with_suffix(".out"))
            err = read(base.with_suffix(".err"))
            combined = (out + "\n" + err).lower()
            assert status, base
            assert not any(fragment in combined for fragment in bad_fragments), (op, worker, index, out, err)

            if status == "0":
                assert err == "", (op, worker, index, err)
                counts[op]["success"] += 1
                line = out.strip()
                if op == "get":
                    match = re.match(r"^(aa[0-9]{4}) task(?: |$)", line)
                    assert match and match.group(1) in source_ids, (op, line)
                elif op in {"set", "unset"}:
                    assert line.startswith("Updated "), (op, line)
                    assert line.split(" ", 1)[1] in source_ids, (op, line)
                elif op == "rm":
                    assert line.startswith("Removed "), (op, line)
                    assert line.split(" ", 1)[1] in source_ids, (op, line)
                elif op == "link":
                    parts = line.split()
                    assert len(parts) == 4 and parts[0] == "Linked" and parts[2] == "blocks", (op, line)
                    assert parts[1] in source_ids and parts[3] in target_ids, (op, line)
                    link_success_pairs.add((parts[1], parts[2], parts[3]))
                elif op == "unlink":
                    parts = line.split()
                    assert len(parts) == 4 and parts[0] == "Unlinked" and parts[2] == "blocks", (op, line)
                    assert parts[1] in source_ids and parts[3] in target_ids, (op, line)
                elif op == "links":
                    if line:
                        for link_line in line.splitlines():
                            parts = link_line.split()
                            assert len(parts) == 3, (op, link_line)
                            assert parts[0] in {"out", "in"} and parts[1] == "blocks", (op, link_line)
                            assert parts[2] in all_ids, (op, link_line)
            else:
                assert out == "", (op, worker, index, out)
                if "matches multiple records" in err:
                    counts[op]["ambiguous"] += 1
                elif "was not found" in err:
                    counts[op]["not_found"] += 1
                else:
                    raise AssertionError((op, worker, index, status, err))

for op in ops:
    total = sum(counts[op].values())
    assert total == worker_count * iterations, (op, total, counts[op])

assert sum(item["success"] for item in counts.values()) > 0, counts
assert sum(item["ambiguous"] for item in counts.values()) > 0, counts
assert sum(item["not_found"] for item in counts.values()) > 0, counts

con = sqlite3.connect(db)
record_ids = {
    row[0]
    for row in con.execute("select id from records order by id")
}
assert record_ids <= all_ids, record_ids

event_counts = dict(
    con.execute(
        """
        select event_type, count(*)
        from store_events
        where event_type in ('set', 'unset', 'rm', 'link', 'unlink')
        group by event_type
        """
    ).fetchall()
)
for op in ["set", "unset", "rm", "link", "unlink"]:
    assert event_counts.get(op, 0) == counts[op]["success"], (op, event_counts, counts[op])

dangling_links = con.execute(
    """
    select count(*)
    from record_links l
    left join records source on source.id = l.from_record_id
    left join records target on target.id = l.to_record_id
    where source.id is null or target.id is null
    """
).fetchone()[0]
assert dangling_links == 0, dangling_links

link_rows = set(
    con.execute(
        """
        select from_record_id, rel, to_record_id
        from record_links
        order by from_record_id, rel, to_record_id
        """
    ).fetchall()
)
assert all(row[0] in source_ids and row[1] == "blocks" and row[2] in target_ids for row in link_rows), link_rows
assert link_rows <= link_success_pairs, (link_rows, link_success_pairs)

print(
    " ".join(
        f"{op}=success:{counts[op]['success']},ambiguous:{counts[op]['ambiguous']},not_found:{counts[op]['not_found']}"
        for op in ops
    )
)
print(f"events={event_counts} final_records={sorted(record_ids)} final_links={sorted(link_rows)}")
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'prefix-*' -o -name 'churn.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-id-prefix-resolution-races.md" <<EOF
# Concurrent ID Prefix Resolution Race Evidence

- source_prefix: $source_prefix
- target_prefix: $target_prefix
- source_records: $source_one $source_two
- target_records: $target_one $target_two
- workers_per_command: $worker_count
- iterations_per_worker: $iterations
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_json_prefix_and_hook_rm_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-json-prefix-hook-race-init.out
    "$agent_store_bin" ctx >/tmp/agent-store-json-prefix-hook-race-schema.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    source_prefix="cc"
    target_prefix="dd"
    hook_prefix="hk"
    source_one="cc1001"
    source_two="cc2002"
    target_one="dd1001"
    target_two="dd2002"
    hook_one="hk1001"
    hook_two="hk2002"
    protected_hook="zz9999"
    worker_count=3
    iterations=14

    stop_file="$tmp/churn.stop"
    ready_file="$tmp/churn.ready"
    python3 - \
      .agent-store/store.sqlite \
      "$source_one" \
      "$source_two" \
      "$target_one" \
      "$target_two" \
      "$hook_one" \
      "$hook_two" \
      "$protected_hook" \
      "$tmp/churn.log" \
      "$stop_file" \
      "$ready_file" <<'PY' >"$tmp/churn.out" 2>"$tmp/churn.err" &
import os
import pathlib
import sqlite3
import sys
import time

(
    db,
    source_one,
    source_two,
    target_one,
    target_two,
    hook_one,
    hook_two,
    protected_hook,
    log_path,
    stop_path,
    ready_path,
) = sys.argv[1:]
source_ids = [source_one, source_two]
target_ids = [target_one, target_two]
record_ids = source_ids + target_ids
hook_ids = [hook_one, hook_two]
record_states = [
    ([], []),
    ([source_one], []),
    ([], [target_one]),
    ([source_one], [target_one]),
    ([source_one, source_two], [target_one]),
    ([source_one], [target_one, target_two]),
    ([source_one, source_two], [target_one, target_two]),
]
hook_states = [
    [],
    [hook_one],
    [hook_one, hook_two],
    [hook_two],
]

con = sqlite3.connect(db, timeout=10.0, isolation_level=None)
con.execute("PRAGMA foreign_keys = ON")
con.execute("PRAGMA busy_timeout = 10000")
con.execute("CREATE TABLE hook_delete_audit (hook_id TEXT NOT NULL)")
con.execute("CREATE TABLE hook_churn_expected_deletes (hook_id TEXT NOT NULL)")
con.execute(
    """
    CREATE TRIGGER hook_delete_audit_after_delete
    AFTER DELETE ON hooks
    BEGIN
      INSERT INTO hook_delete_audit (hook_id) VALUES (old.id);
    END
    """
)
con.execute(
    "INSERT INTO hooks (id, event, query, command) VALUES (?, 'create', NULL, 'true')",
    (protected_hook,),
)

def insert_record(record_id, kind, role, state):
    con.execute("INSERT INTO records (id, kind) VALUES (?, ?)", (record_id, kind))
    fields = {
        "batch": "json-prefix-hook-race",
        "role": role,
        "state": state,
    }
    for key, value in fields.items():
        con.execute(
            "INSERT INTO record_fields (record_id, key, raw_value, text_value) VALUES (?, ?, ?, ?)",
            (record_id, key, value, value),
        )

def replace_records(sources, targets, state):
    con.execute(
        "DELETE FROM records WHERE id IN ({})".format(",".join("?" for _ in record_ids)),
        record_ids,
    )
    for record_id in sources:
        insert_record(record_id, "task", "source", state)
    for record_id in targets:
        insert_record(record_id, "note", "target", state)

def replace_hooks(active_hooks):
    existing = [
        row[0]
        for row in con.execute(
            "SELECT id FROM hooks WHERE id IN ({}) ORDER BY id".format(",".join("?" for _ in hook_ids)),
            hook_ids,
        )
    ]
    for hook_id in existing:
        con.execute("INSERT INTO hook_churn_expected_deletes (hook_id) VALUES (?)", (hook_id,))
    con.execute(
        "DELETE FROM hooks WHERE id IN ({})".format(",".join("?" for _ in hook_ids)),
        hook_ids,
    )
    for hook_id in active_hooks:
        con.execute(
            "INSERT INTO hooks (id, event, query, command) VALUES (?, 'create', NULL, 'true')",
            (hook_id,),
        )

pathlib.Path(ready_path).write_text("ready", encoding="utf-8")
with open(log_path, "w", encoding="utf-8") as log:
    cycle = 0
    while cycle < 1000 and (cycle < 100 or not os.path.exists(stop_path)):
        sources, targets = record_states[cycle % len(record_states)]
        active_hooks = hook_states[cycle % len(hook_states)]
        state = f"cycle-{cycle}"
        con.execute("BEGIN IMMEDIATE")
        replace_records(sources, targets, state)
        replace_hooks(active_hooks)
        con.execute("COMMIT")
        log.write(
            f"{cycle}:sources={','.join(sources) or '-'} "
            f"targets={','.join(targets) or '-'} hooks={','.join(active_hooks) or '-'}\n"
        )
        log.flush()
        cycle += 1
        time.sleep(0.008)

    con.execute("BEGIN IMMEDIATE")
    replace_records([source_one], [target_one], "final")
    replace_hooks([hook_one])
    con.execute("COMMIT")
PY
    churn_pid="$!"

    ready_attempts=500
    while [ ! -f "$ready_file" ]; do
      ready_attempts=$((ready_attempts - 1))
      if [ "$ready_attempts" -le 0 ]; then
        cat "$tmp/churn.err" >&2 || true
        exit 1
      fi
      sleep 0.01
    done

    run_json_prefix_worker() {
      local op="$1"
      local worker="$2"
      local index

      for index in $(seq 1 "$iterations"); do
        local prefix="$tmp/jsonprefix-$op-$worker-$index"
        set +e
        case "$op" in
          get)
            "$agent_store_bin" --json get "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          link)
            "$agent_store_bin" --json link "$source_prefix" blocks "$target_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          unlink)
            "$agent_store_bin" --json unlink "$source_prefix" blocks "$target_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
          links)
            "$agent_store_bin" --json links "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
        esac
        local code="$?"
        set -e
        printf "%s" "$code" >"$prefix.status"
        sleep 0.004
      done
    }

    run_hook_prefix_worker() {
      local worker="$1"
      local index

      for index in $(seq 1 "$iterations"); do
        local prefix="$tmp/hookprefix-rm-$worker-$index"
        set +e
        "$agent_store_bin" hook rm "$hook_prefix" >"$prefix.out" 2>"$prefix.err"
        local code="$?"
        set -e
        printf "%s" "$code" >"$prefix.status"
        sleep 0.004
      done
    }

    pids=()
    for op in get link unlink links; do
      for worker in $(seq 1 "$worker_count"); do
        (run_json_prefix_worker "$op" "$worker") &
        pids+=("$!")
      done
    done
    for worker in $(seq 1 "$worker_count"); do
      (run_hook_prefix_worker "$worker") &
      pids+=("$!")
    done

    for pid in "${pids[@]}"; do
      wait "$pid"
    done

    touch "$stop_file"
    if ! wait "$churn_pid"; then
      cat "$tmp/churn.err" >&2
      exit 1
    fi

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$worker_count" \
      "$iterations" \
      "$source_one" \
      "$source_two" \
      "$target_one" \
      "$target_two" \
      "$hook_one" \
      "$hook_two" \
      "$protected_hook" <<'PY'
from collections import Counter
import json
import pathlib
import re
import sqlite3
import sys

tmp = pathlib.Path(sys.argv[1])
db = sys.argv[2]
worker_count = int(sys.argv[3])
iterations = int(sys.argv[4])
source_ids = set(sys.argv[5:7])
target_ids = set(sys.argv[7:9])
hook_ids = set(sys.argv[9:11])
protected_hook = sys.argv[11]
all_record_ids = source_ids | target_ids
json_ops = ["get", "link", "unlink", "links"]
bad_fragments = [
    "database is locked",
    "panicked",
    "thread 'main'",
    "foreign key constraint",
    "constraint failed",
    "query returned no rows",
]
counts = {
    op: {"success": 0, "ambiguous": 0, "not_found": 0}
    for op in json_ops + ["hook_rm"]
}
link_success_pairs = Counter()
hook_success_ids = Counter()

def read(path):
    return path.read_text(encoding="utf-8") if path.exists() else ""

def classify_error(err):
    if "matches multiple records" in err or "matches multiple hooks" in err:
        return "ambiguous"
    if "was not found" in err:
        return "not_found"
    raise AssertionError(err)

for op in json_ops:
    for worker in range(1, worker_count + 1):
        for index in range(1, iterations + 1):
            base = tmp / f"jsonprefix-{op}-{worker}-{index}"
            status = read(base.with_suffix(".status")).strip()
            out = read(base.with_suffix(".out"))
            err = read(base.with_suffix(".err"))
            combined = (out + "\n" + err).lower()
            assert status, base
            assert not any(fragment in combined for fragment in bad_fragments), (op, worker, index, out, err)

            if status == "0":
                assert err == "", (op, worker, index, err)
                payload = json.loads(out)
                counts[op]["success"] += 1
                if op == "get":
                    record = payload["record"]
                    assert record["id"] in source_ids, payload
                    assert record["kind"] == "task", payload
                    assert record["fields"]["role"] == "source", payload
                elif op in {"link", "unlink"}:
                    expected_status = "linked" if op == "link" else "unlinked"
                    assert payload["status"] == expected_status, payload
                    link = payload["link"]
                    assert link["from_record_id"] in source_ids, payload
                    assert link["rel"] == "blocks", payload
                    assert link["to_record_id"] in target_ids, payload
                    if op == "link":
                        link_success_pairs[
                            (link["from_record_id"], link["rel"], link["to_record_id"])
                        ] += 1
                elif op == "links":
                    assert payload["record_id"] in source_ids, payload
                    assert isinstance(payload["links"], list), payload
                    for edge in payload["links"]:
                        assert edge["direction"] in {"out", "in"}, payload
                        assert edge["rel"] == "blocks", payload
                        assert edge["record_id"] in all_record_ids, payload
            else:
                assert out == "", (op, worker, index, out)
                counts[op][classify_error(err)] += 1

for worker in range(1, worker_count + 1):
    for index in range(1, iterations + 1):
        base = tmp / f"hookprefix-rm-{worker}-{index}"
        status = read(base.with_suffix(".status")).strip()
        out = read(base.with_suffix(".out"))
        err = read(base.with_suffix(".err"))
        combined = (out + "\n" + err).lower()
        assert status, base
        assert not any(fragment in combined for fragment in bad_fragments), (worker, index, out, err)

        if status == "0":
            assert err == "", (worker, index, err)
            match = re.fullmatch(r"Removed ([a-z0-9]{6})\n?", out)
            assert match and match.group(1) in hook_ids, (worker, index, out)
            counts["hook_rm"]["success"] += 1
            hook_success_ids[match.group(1)] += 1
        else:
            assert out == "", (worker, index, out)
            counts["hook_rm"][classify_error(err)] += 1

for op in json_ops + ["hook_rm"]:
    total = sum(counts[op].values())
    assert total == worker_count * iterations, (op, total, counts[op])
    assert counts[op]["success"] > 0, (op, counts[op])
    assert counts[op]["ambiguous"] > 0, (op, counts[op])
    assert counts[op]["not_found"] > 0, (op, counts[op])

con = sqlite3.connect(db)
record_ids = {row[0] for row in con.execute("SELECT id FROM records ORDER BY id")}
assert record_ids == {sorted(source_ids)[0], sorted(target_ids)[0]}, record_ids

event_counts = dict(
    con.execute(
        """
        SELECT event_type, count(*)
        FROM store_events
        WHERE event_type in ('link', 'unlink')
        GROUP BY event_type
        """
    ).fetchall()
)
for op in ["link", "unlink"]:
    assert event_counts.get(op, 0) == counts[op]["success"], (op, event_counts, counts[op])

dangling_links = con.execute(
    """
    SELECT count(*)
    FROM record_links l
    LEFT JOIN records source ON source.id = l.from_record_id
    LEFT JOIN records target ON target.id = l.to_record_id
    WHERE source.id IS NULL OR target.id IS NULL
    """
).fetchone()[0]
assert dangling_links == 0, dangling_links

link_rows = set(
    con.execute(
        """
        SELECT from_record_id, rel, to_record_id
        FROM record_links
        ORDER BY from_record_id, rel, to_record_id
        """
    ).fetchall()
)
assert all(row[0] in source_ids and row[1] == "blocks" and row[2] in target_ids for row in link_rows), link_rows
assert all(link_success_pairs[row] > 0 for row in link_rows), (link_rows, link_success_pairs)

actual_hook_deletes = Counter(
    row[0]
    for row in con.execute(
        "SELECT hook_id FROM hook_delete_audit WHERE hook_id IN ({})".format(
            ",".join("?" for _ in hook_ids)
        ),
        tuple(sorted(hook_ids)),
    )
)
expected_hook_deletes = Counter(
    row[0]
    for row in con.execute(
        "SELECT hook_id FROM hook_churn_expected_deletes WHERE hook_id IN ({})".format(
            ",".join("?" for _ in hook_ids)
        ),
        tuple(sorted(hook_ids)),
    )
)
expected_hook_deletes.update(hook_success_ids)
assert actual_hook_deletes == expected_hook_deletes, (
    actual_hook_deletes,
    expected_hook_deletes,
    hook_success_ids,
)

final_hooks = {row[0] for row in con.execute("SELECT id FROM hooks ORDER BY id")}
assert final_hooks == {sorted(hook_ids)[0], protected_hook}, final_hooks

print(
    " ".join(
        f"{op}=success:{counts[op]['success']},ambiguous:{counts[op]['ambiguous']},not_found:{counts[op]['not_found']}"
        for op in json_ops + ["hook_rm"]
    )
)
print(f"events={event_counts} final_records={sorted(record_ids)} final_links={sorted(link_rows)} final_hooks={sorted(final_hooks)}")
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'jsonprefix-*' -o -name 'hookprefix-*' -o -name 'churn.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-json-prefix-and-hook-rm-races.md" <<EOF
# Concurrent JSON Prefix and Hook Remove Race Evidence

- source_prefix: $source_prefix
- target_prefix: $target_prefix
- hook_prefix: $hook_prefix
- source_records: $source_one $source_two
- target_records: $target_one $target_two
- hooks: $hook_one $hook_two
- workers_per_command: $worker_count
- iterations_per_worker: $iterations
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  concurrent_json_mutation_prefix_races)
    CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
    agent_store_bin="$target_dir/debug/agent-store"
    cd "$tmp"
    "$agent_store_bin" init >/tmp/agent-store-json-mutation-prefix-race-init.out
    "$agent_store_bin" ctx >/tmp/agent-store-json-mutation-prefix-race-schema.out

    evidence_root="${AGENT_STORE_E2E_DIR:-}"
    if [ -n "$evidence_root" ]; then
      mkdir -p "$evidence_root/logs" "$evidence_root/reports"
    fi

    source_prefix="ee"
    source_one="ee1001"
    source_two="ee2002"
    worker_count=4
    iterations=16

    stop_file="$tmp/churn.stop"
    ready_file="$tmp/churn.ready"
    python3 - \
      .agent-store/store.sqlite \
      "$source_one" \
      "$source_two" \
      "$tmp/churn.log" \
      "$stop_file" \
      "$ready_file" <<'PY' >"$tmp/churn.out" 2>"$tmp/churn.err" &
import os
import pathlib
import sqlite3
import sys
import time

db, source_one, source_two, log_path, stop_path, ready_path = sys.argv[1:]
source_ids = [source_one, source_two]
states = [
    [],
    [source_one],
    [source_one, source_two],
    [source_one],
    [],
]

con = sqlite3.connect(db, timeout=10.0, isolation_level=None)
con.execute("PRAGMA foreign_keys = ON")
con.execute("PRAGMA busy_timeout = 10000")

def insert_record(record_id, state):
    con.execute("INSERT INTO records (id, kind) VALUES (?, 'task')", (record_id,))
    fields = {
        "batch": "json-mutation-prefix-race",
        "role": "source",
        "state": state,
    }
    for key, value in fields.items():
        con.execute(
            "INSERT INTO record_fields (record_id, key, raw_value, text_value) VALUES (?, ?, ?, ?)",
            (record_id, key, value, value),
        )

def replace_records(active_ids, state):
    con.execute(
        "DELETE FROM records WHERE id IN ({})".format(",".join("?" for _ in source_ids)),
        source_ids,
    )
    for record_id in active_ids:
        insert_record(record_id, state)

pathlib.Path(ready_path).write_text("ready", encoding="utf-8")
with open(log_path, "w", encoding="utf-8") as log:
    cycle = 0
    while cycle < 1000 and (cycle < 100 or not os.path.exists(stop_path)):
        active_ids = states[cycle % len(states)]
        state = f"cycle-{cycle}"
        con.execute("BEGIN IMMEDIATE")
        replace_records(active_ids, state)
        con.execute("COMMIT")
        log.write(f"{cycle}:sources={','.join(active_ids) or '-'}\n")
        log.flush()
        cycle += 1
        time.sleep(0.006)

    con.execute("BEGIN IMMEDIATE")
    replace_records([source_one], "final")
    con.execute("COMMIT")
PY
    churn_pid="$!"

    ready_attempts=500
    while [ ! -f "$ready_file" ]; do
      ready_attempts=$((ready_attempts - 1))
      if [ "$ready_attempts" -le 0 ]; then
        cat "$tmp/churn.err" >&2 || true
        exit 1
      fi
      sleep 0.01
    done

    run_json_mutation_prefix_worker() {
      local op="$1"
      local worker="$2"
      local index

      for index in $(seq 1 "$iterations"); do
        local prefix="$tmp/jsonmutation-$op-$worker-$index"
        set +e
        case "$op" in
          set)
            "$agent_store_bin" --json set "$source_prefix" "race_status=$worker-$index" "race_marker=set-$worker-$index" >"$prefix.out" 2>"$prefix.err"
            ;;
          unset)
            "$agent_store_bin" --json unset "$source_prefix" race_status >"$prefix.out" 2>"$prefix.err"
            ;;
          rm)
            "$agent_store_bin" --json rm "$source_prefix" >"$prefix.out" 2>"$prefix.err"
            ;;
        esac
        local code="$?"
        set -e
        printf "%s" "$code" >"$prefix.status"
        sleep 0.004
      done
    }

    pids=()
    for op in set unset rm; do
      for worker in $(seq 1 "$worker_count"); do
        (run_json_mutation_prefix_worker "$op" "$worker") &
        pids+=("$!")
      done
    done

    for pid in "${pids[@]}"; do
      wait "$pid"
    done

    touch "$stop_file"
    if ! wait "$churn_pid"; then
      cat "$tmp/churn.err" >&2
      exit 1
    fi

    summary="$(python3 - \
      "$tmp" \
      .agent-store/store.sqlite \
      "$worker_count" \
      "$iterations" \
      "$source_one" \
      "$source_two" <<'PY'
from collections import Counter
import json
import pathlib
import sqlite3
import sys

tmp = pathlib.Path(sys.argv[1])
db = sys.argv[2]
worker_count = int(sys.argv[3])
iterations = int(sys.argv[4])
source_ids = set(sys.argv[5:7])
ops = ["set", "unset", "rm"]
bad_fragments = [
    "database is locked",
    "panicked",
    "thread 'main'",
    "foreign key constraint",
    "constraint failed",
    "query returned no rows",
]
counts = {
    op: {"success": 0, "ambiguous": 0, "not_found": 0}
    for op in ops
}
success_ids = {op: Counter() for op in ops}

def read(path):
    return path.read_text(encoding="utf-8") if path.exists() else ""

def classify_error(err):
    if "matches multiple records" in err:
        return "ambiguous"
    if "was not found" in err:
        return "not_found"
    raise AssertionError(err)

for op in ops:
    for worker in range(1, worker_count + 1):
        for index in range(1, iterations + 1):
            base = tmp / f"jsonmutation-{op}-{worker}-{index}"
            status = read(base.with_suffix(".status")).strip()
            out = read(base.with_suffix(".out"))
            err = read(base.with_suffix(".err"))
            combined = (out + "\n" + err).lower()
            assert status, base
            assert not any(fragment in combined for fragment in bad_fragments), (
                op,
                worker,
                index,
                out,
                err,
            )

            if status == "0":
                assert err == "", (op, worker, index, err)
                payload = json.loads(out)
                expected_status = "removed" if op == "rm" else "updated"
                assert payload["status"] == expected_status, payload
                record = payload["record"]
                record_id = record["id"]
                fields = record["fields"]
                assert record_id in source_ids, payload
                assert record["kind"] == "task", payload
                assert fields["batch"] == "json-mutation-prefix-race", payload
                assert fields["role"] == "source", payload
                if op == "set":
                    assert fields["race_status"] == f"{worker}-{index}", payload
                    assert fields["race_marker"] == f"set-{worker}-{index}", payload
                elif op == "unset":
                    assert "race_status" not in fields, payload
                counts[op]["success"] += 1
                success_ids[op][record_id] += 1
            else:
                assert out == "", (op, worker, index, out)
                counts[op][classify_error(err)] += 1

for op in ops:
    total = sum(counts[op].values())
    assert total == worker_count * iterations, (op, total, counts[op])
    assert counts[op]["success"] > 0, (op, counts[op])
    assert counts[op]["ambiguous"] > 0, (op, counts[op])
    assert counts[op]["not_found"] > 0, (op, counts[op])

con = sqlite3.connect(db)
event_rows = con.execute(
    """
    SELECT event_type, record_id, record_snapshot
    FROM store_events
    WHERE event_type IN ('set', 'unset', 'rm')
    ORDER BY id
    """
).fetchall()
event_counts = Counter(row[0] for row in event_rows)
for op in ops:
    assert event_counts[op] == counts[op]["success"], (op, event_counts, counts[op])

for event_type, record_id, snapshot_raw in event_rows:
    assert record_id in source_ids, (event_type, record_id)
    snapshot = json.loads(snapshot_raw)
    assert snapshot["id"] == record_id, snapshot
    assert snapshot["kind"] == "task", snapshot
    fields = snapshot["fields"]
    assert fields["batch"] == "json-mutation-prefix-race", snapshot
    assert fields["role"] == "source", snapshot
    if event_type == "set":
        assert "race_status" in fields, snapshot
        assert "race_marker" in fields, snapshot
    elif event_type == "unset":
        assert "race_status" not in fields, snapshot

record_ids = {row[0] for row in con.execute("SELECT id FROM records ORDER BY id")}
assert record_ids == {sorted(source_ids)[0]}, record_ids
final_fields = dict(
    con.execute(
        "SELECT key, raw_value FROM record_fields WHERE record_id = ?",
        (sorted(source_ids)[0],),
    ).fetchall()
)
assert final_fields == {
    "batch": "json-mutation-prefix-race",
    "role": "source",
    "state": "final",
}, final_fields

print(
    " ".join(
        f"{op}=success:{counts[op]['success']},ambiguous:{counts[op]['ambiguous']},not_found:{counts[op]['not_found']}"
        for op in ops
    )
)
print(
    "events={} success_ids={}".format(
        dict(event_counts),
        {op: dict(success_ids[op]) for op in ops},
    )
)
PY
)"

    if [ -n "$evidence_root" ]; then
      find "$tmp" -maxdepth 1 -type f \
        \( -name 'jsonmutation-*' -o -name 'churn.*' \) \
        -exec cp {} "$evidence_root/logs/" \;
      cp .agent-store/store.sqlite "$evidence_root/store.sqlite"
      cat > "$evidence_root/reports/concurrent-json-mutation-prefix-races.md" <<EOF
# Concurrent JSON Mutation Prefix Race Evidence

- source_prefix: $source_prefix
- source_records: $source_one $source_two
- workers_per_command: $worker_count
- iterations_per_worker: $iterations
- $summary
- database: $evidence_root/store.sqlite
- logs: $evidence_root/logs
EOF
    fi
    ;;

  *)
    echo "usage: $0 {store_is_project_local|migrations_apply_on_open|initial_schema_tables|records_columns|record_fields_typed_columns|record_links_cardinality_shape|record_links_columns_unique|record_delete_cascades_links|hard_delete_store_event_snapshot|record_mutations_transactional|persistence_open_errors_actionable|migration_checksum_mismatch|concurrent_process_writers|concurrent_process_writers_with_hooks|concurrent_process_mutations_with_hooks|concurrent_hook_lifecycle_races|concurrent_hook_lifecycle_mutation_races|concurrent_json_mutation_hook_lifecycle_races|concurrent_hook_churn_reads|concurrent_record_readers_with_hooked_mutations|concurrent_json_record_readers_with_hooked_mutations|concurrent_link_record_disappearance_races|concurrent_set_unset_link_snapshot_races|create_rm_link_snapshot_hooks|concurrent_same_record_and_link_races|concurrent_id_prefix_resolution_races|concurrent_json_prefix_and_hook_rm_races|concurrent_json_mutation_prefix_races}" >&2
    exit 2
    ;;
esac
