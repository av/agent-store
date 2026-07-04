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
    run_agent_store init >"$tmp"/agent-store-link-q59-init.out
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

  unlink_removes_and_missing_fails)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-unlink-80k-init.out
    from_id="$(run_agent_store create task title=source status=open)"
    to_id="$(run_agent_store create task title=target)"
    other_id="$(run_agent_store create note title=other)"
    from_prefix="$(printf "%s" "$from_id" | cut -c1-4)"
    to_prefix="$(printf "%s" "$to_id" | cut -c1-4)"

    run_agent_store link "$from_id" blocks "$to_id" >"$tmp"/agent-store-unlink-80k-link.out
    run_agent_store link "$from_id" mentions "$other_id" >"$tmp"/agent-store-unlink-80k-other.out
    hook_id="$(run_agent_store hook add unlink 'kind=task and status=open' -- 'true')"

    expect_unlink_missing() {
      local json_flag="$1"
      shift
      set +e
      if [ "$json_flag" = "json" ]; then
        run_agent_store --json unlink "$@" >"$tmp/missing.out" 2>"$tmp/missing.err"
      else
        run_agent_store unlink "$@" >"$tmp/missing.out" 2>"$tmp/missing.err"
      fi
      local code="$?"
      set -e
      test "$code" != "0"
      test ! -s "$tmp/missing.out"
      if [ "$json_flag" = "json" ]; then
        grep -Fq "{\"error\":\"no such link" "$tmp/missing.err"
      else
        grep -Fq "error: no such link" "$tmp/missing.err"
      fi
    }

    # Unlink with a relation that never existed fails.
    expect_unlink_missing plain "$from_prefix" neverexisted "$to_prefix"

    out="$(run_agent_store unlink "$from_prefix" blocks "$to_prefix")"
    test "$out" = "Unlinked $from_id blocks $to_id"

    # Second unlink of the same pair fails, plain and --json.
    expect_unlink_missing plain "$from_prefix" blocks "$to_prefix"
    expect_unlink_missing json "$from_prefix" blocks "$to_prefix"

    links="$(run_agent_store links "$from_id")"
    test "$links" = "out mentions $other_id"

    python3 - .agent-store/store.sqlite "$from_id" "$to_id" "$other_id" "$hook_id" <<'PY'
import sqlite3
import sys

db, from_id, to_id, other_id, hook_id = sys.argv[1:]
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
# Only the single successful unlink records a Store Event and Hook Run;
# not-found unlinks are not committed mutations.
unlink_events = con.execute(
    "select count(*) from store_events where event_type = 'unlink'"
).fetchone()[0]
assert unlink_events == 1, unlink_events
unlink_hook_runs = con.execute(
    "select count(*) from hook_runs where event_type = 'unlink'"
).fetchone()[0]
assert unlink_hook_runs == 1, unlink_hook_runs
PY
    ;;

  links_lists_deterministically)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-links-cav-init.out
    source_id="$(run_agent_store create task title=source)"
    target_a="$(run_agent_store create note title=target-a)"
    target_b="$(run_agent_store create note title=target-b)"
    incoming_a="$(run_agent_store create decision title=incoming-a)"
    incoming_b="$(run_agent_store create decision title=incoming-b)"
    source_prefix="$(printf "%s" "$source_id" | cut -c1-4)"

    run_agent_store link "$source_id" depends_on "$target_b" >"$tmp"/agent-store-links-cav-out-2.out
    run_agent_store link "$source_id" blocks "$target_a" >"$tmp"/agent-store-links-cav-out-1.out
    run_agent_store link "$incoming_b" blocks "$source_id" >"$tmp"/agent-store-links-cav-in-1.out
    run_agent_store link "$incoming_a" relates "$source_id" >"$tmp"/agent-store-links-cav-in-2.out

    expected="out blocks $target_a
out depends_on $target_b
in blocks $incoming_b
in relates $incoming_a"
    got="$(run_agent_store links "$source_prefix")"
    test "$got" = "$expected"
    ;;

  find_filters_links)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-find-links-l7a-init.out
    source_id="$(run_agent_store create task title=source status=open)"
    target_id="$(run_agent_store create note title=target status=open)"
    other_id="$(run_agent_store create note title=other status=open)"
    incoming_id="$(run_agent_store create decision title=incoming status=open)"
    unrelated_id="$(run_agent_store create task title=unrelated status=open)"

    run_agent_store link "$source_id" blocks "$target_id" >"$tmp"/agent-store-find-links-l7a-blocks.out
    run_agent_store link "$source_id" mentions "$other_id" >"$tmp"/agent-store-find-links-l7a-mentions.out
    run_agent_store link "$incoming_id" blocks "$source_id" >"$tmp"/agent-store-find-links-l7a-incoming.out

    source_line="$source_id task status=open title=source"
    target_line="$target_id note status=open title=target"
    unrelated_line="$unrelated_id task status=open title=unrelated"

    got="$(run_agent_store find 'link.out=mentions')"
    test "$got" = "$source_line"

    expected="$source_line
$target_line"
    got="$(run_agent_store find 'link.in=blocks')"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    got="$(run_agent_store find "link.out.blocks=$target_id")"
    test "$got" = "$source_line"

    got="$(run_agent_store find "link.in.blocks=$incoming_id")"
    test "$got" = "$source_line"

    got="$(run_agent_store find "kind=note and link.in.blocks=$source_id")"
    test "$got" = "$target_line"

    expected="$source_line
$target_line"
    got="$(run_agent_store find "link.out=mentions or link.in.blocks=$source_id")"
    test "$(printf "%s\n" "$got" | sort)" = "$(printf "%s\n" "$expected" | sort)"

    got="$(run_agent_store find 'kind=task and not link.out=blocks')"
    test "$got" = "$unrelated_line"

    got="$(run_agent_store find "link.out.blocks=$other_id")"
    test -z "$got"
    ;;

  self_link_rejected)
    cd "$tmp"
    run_agent_store init >"$tmp"/agent-store-self-link-init.out
    id="$(run_agent_store create task title=solo status=open)"
    prefix="$(printf "%s" "$id" | cut -c1-4)"
    hook_id="$(run_agent_store hook add link 'kind=task' -- 'true')"

    expect_self_link_rejected() {
      local json_flag="$1"
      shift
      set +e
      if [ "$json_flag" = "json" ]; then
        run_agent_store --json link "$@" >"$tmp/self.out" 2>"$tmp/self.err"
      else
        run_agent_store link "$@" >"$tmp/self.out" 2>"$tmp/self.err"
      fi
      local code="$?"
      set -e
      test "$code" != "0"
      test ! -s "$tmp/self.out"
      if [ "$json_flag" = "json" ]; then
        grep -Fq "{\"error\":\"cannot link a record to itself ($id)\"}" "$tmp/self.err"
      else
        grep -Fq "error: cannot link a record to itself ($id)" "$tmp/self.err"
      fi
    }

    # Full ID, short prefix (resolving to the same record), and --json all fail.
    expect_self_link_rejected plain "$id" blocks "$id"
    expect_self_link_rejected plain "$prefix" blocks "$id"
    expect_self_link_rejected json "$id" duplicate_of "$prefix"

    # No link exists, no hook fired, no link store event was recorded.
    links="$(run_agent_store links "$id")"
    test -z "$links"
    runs="$(run_agent_store hook runs)"
    test "$runs" = "No hook runs recorded yet."
    python3 - .agent-store/store.sqlite <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
assert con.execute("select count(*) from record_links").fetchone()[0] == 0
link_events = con.execute(
    "select count(*) from store_events where event_type = 'link'"
).fetchone()[0]
assert link_events == 0, link_events
PY
    ;;

  *)
    echo "usage: $0 {link_adds_idempotently|unlink_removes_and_missing_fails|links_lists_deterministically|find_filters_links|self_link_rejected}" >&2
    exit 2
    ;;
esac
