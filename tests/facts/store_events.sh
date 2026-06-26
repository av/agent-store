#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-store-events-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

case "$case_name" in
  mutation_events)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-events-rc5-init.out

    source_id="$(run_agent_store create task title=source status=open note=keep)"
    target_id="$(run_agent_store create note title=target)"
    run_agent_store set "$source_id" status=active >/tmp/agent-store-events-rc5-set.out
    run_agent_store unset "$source_id" note >/tmp/agent-store-events-rc5-unset.out
    run_agent_store link "$source_id" blocks "$target_id" >/tmp/agent-store-events-rc5-link.out
    run_agent_store unlink "$source_id" blocks "$target_id" >/tmp/agent-store-events-rc5-unlink.out
    run_agent_store rm "$target_id" >/tmp/agent-store-events-rc5-rm.out

    python3 - .agent-store/store.sqlite "$source_id" "$target_id" <<'PY'
import json
import sqlite3
import sys

db, source_id, target_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select event_type, record_id, record_snapshot, created_at
    from store_events
    order by id
    """
).fetchall()

expected = [
    (
        "create",
        source_id,
        {
            "id": source_id,
            "kind": "task",
            "fields": {"note": "keep", "status": "open", "title": "source"},
        },
    ),
    (
        "create",
        target_id,
        {
            "id": target_id,
            "kind": "note",
            "fields": {"title": "target"},
        },
    ),
    (
        "set",
        source_id,
        {
            "id": source_id,
            "kind": "task",
            "fields": {"note": "keep", "status": "active", "title": "source"},
        },
    ),
    (
        "unset",
        source_id,
        {
            "id": source_id,
            "kind": "task",
            "fields": {"status": "active", "title": "source"},
        },
    ),
    (
        "link",
        source_id,
        {
            "id": source_id,
            "kind": "task",
            "fields": {"status": "active", "title": "source"},
        },
    ),
    (
        "unlink",
        source_id,
        {
            "id": source_id,
            "kind": "task",
            "fields": {"status": "active", "title": "source"},
        },
    ),
    (
        "rm",
        target_id,
        {
            "id": target_id,
            "kind": "note",
            "fields": {"title": "target"},
        },
    ),
]

actual = [
    (event_type, record_id, json.loads(snapshot))
    for event_type, record_id, snapshot, created_at in rows
    if created_at
]
assert actual == expected, actual
assert len(actual) == len(rows), rows
assert con.execute("select count(*) from records where id = ?", (source_id,)).fetchone()[0] == 1
assert con.execute("select count(*) from records where id = ?", (target_id,)).fetchone()[0] == 0
assert con.execute("select count(*) from record_links").fetchone()[0] == 0
PY
    ;;

  *)
    echo "usage: $0 {mutation_events}" >&2
    exit 2
    ;;
esac
