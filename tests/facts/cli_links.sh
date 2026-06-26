#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-links-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_agent_store() {
  CARGO_TARGET_DIR="$target_dir" cargo run --quiet --manifest-path "$repo/Cargo.toml" -- "$@"
}

case "$case_name" in
  link_adds_idempotently)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-link-q59-init.out
    from_id="$(run_agent_store create task title=source)"
    to_id="$(run_agent_store create task title=target)"
    from_prefix="$(printf "%s" "$from_id" | cut -c1-4)"
    to_prefix="$(printf "%s" "$to_id" | cut -c1-4)"

    out="$(run_agent_store link "$from_prefix" blocks "$to_prefix")"
    test "$out" = "Linked $from_id blocks $to_id"
    repeated="$(run_agent_store link "$from_prefix" blocks "$to_prefix")"
    test "$repeated" = "$out"
    links="$(run_agent_store links "$from_id")"
    test "$links" = "out blocks $to_id"

    python3 - .agent-store/store.sqlite "$from_id" "$to_id" <<'PY'
import sqlite3
import sys

db, from_id, to_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select from_record_id, rel, to_record_id
    from record_links
    order by from_record_id, rel, to_record_id
    """
).fetchall()
assert rows == [(from_id, "blocks", to_id)], rows
PY
    ;;

  unlink_removes_idempotently)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-unlink-80k-init.out
    from_id="$(run_agent_store create task title=source)"
    to_id="$(run_agent_store create task title=target)"
    other_id="$(run_agent_store create note title=other)"
    from_prefix="$(printf "%s" "$from_id" | cut -c1-4)"
    to_prefix="$(printf "%s" "$to_id" | cut -c1-4)"

    run_agent_store link "$from_id" blocks "$to_id" >/tmp/agent-store-unlink-80k-link.out
    run_agent_store link "$from_id" mentions "$other_id" >/tmp/agent-store-unlink-80k-other.out

    out="$(run_agent_store unlink "$from_prefix" blocks "$to_prefix")"
    test "$out" = "Unlinked $from_id blocks $to_id"
    repeated="$(run_agent_store unlink "$from_prefix" blocks "$to_prefix")"
    test "$repeated" = "$out"
    links="$(run_agent_store links "$from_id")"
    test "$links" = "out mentions $other_id"

    python3 - .agent-store/store.sqlite "$from_id" "$to_id" "$other_id" <<'PY'
import sqlite3
import sys

db, from_id, to_id, other_id = sys.argv[1:]
con = sqlite3.connect(db)
rows = con.execute(
    """
    select from_record_id, rel, to_record_id
    from record_links
    order by from_record_id, rel, to_record_id
    """
).fetchall()
assert rows == [(from_id, "mentions", other_id)], rows
assert con.execute(
    """
    select count(*)
    from record_links
    where from_record_id = ? and rel = 'blocks' and to_record_id = ?
    """,
    (from_id, to_id),
).fetchone()[0] == 0
PY
    ;;

  links_lists_deterministically)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-links-cav-init.out
    source_id="$(run_agent_store create task title=source)"
    target_a="$(run_agent_store create note title=target-a)"
    target_b="$(run_agent_store create note title=target-b)"
    incoming_a="$(run_agent_store create decision title=incoming-a)"
    incoming_b="$(run_agent_store create decision title=incoming-b)"
    source_prefix="$(printf "%s" "$source_id" | cut -c1-4)"

    run_agent_store link "$source_id" depends_on "$target_b" >/tmp/agent-store-links-cav-out-2.out
    run_agent_store link "$source_id" blocks "$target_a" >/tmp/agent-store-links-cav-out-1.out
    run_agent_store link "$incoming_b" blocks "$source_id" >/tmp/agent-store-links-cav-in-1.out
    run_agent_store link "$incoming_a" relates "$source_id" >/tmp/agent-store-links-cav-in-2.out

    expected="out blocks $target_a
out depends_on $target_b
in blocks $incoming_b
in relates $incoming_a"
    got="$(run_agent_store links "$source_prefix")"
    test "$got" = "$expected"
    ;;

  *)
    echo "usage: $0 {link_adds_idempotently|unlink_removes_idempotently|links_lists_deterministically}" >&2
    exit 2
    ;;
esac
