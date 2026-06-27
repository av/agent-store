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

  *)
    echo "usage: $0 {store_is_project_local|migrations_apply_on_open|initial_schema_tables|records_columns|record_fields_typed_columns|record_links_cardinality_shape|record_links_columns_unique|record_delete_cascades_links|hard_delete_store_event_snapshot|record_mutations_transactional|persistence_open_errors_actionable|migration_checksum_mismatch|concurrent_process_writers|concurrent_process_writers_with_hooks|concurrent_process_mutations_with_hooks|concurrent_same_record_and_link_races}" >&2
    exit 2
    ;;
esac
