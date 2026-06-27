#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$repo/target/facts-cli-help-$case_name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CARGO_TARGET_DIR="$target_dir" cargo build --quiet --manifest-path "$repo/Cargo.toml"
agent_store="$target_dir/debug/agent-store"

run_agent_store() {
  "$agent_store" "$@"
}

help_index=0

assert_help() {
  local expected="$1"
  shift
  local out="$tmp/help-$help_index.out"
  local err="$tmp/help-$help_index.err"
  help_index=$((help_index + 1))

  if ! run_agent_store "$@" >"$out" 2>"$err"; then
    printf "help command failed: agent-store %s\n" "$*" >&2
    cat "$err" >&2
    return 1
  fi
  test ! -s "$err"
  grep -Fq "$expected" "$out"
}

case "$case_name" in
  subcommand_help_is_read_only)
    cd "$tmp"
    run_agent_store init >/tmp/agent-store-help-x3h-init.out
    source_id="$(run_agent_store create task title=Seed status=open)"
    target_id="$(run_agent_store create note title=Peer status=open)"
    run_agent_store link "$source_id" relates "$target_id" >/tmp/agent-store-help-x3h-link.out
    hook_id="$(run_agent_store hook add create -- 'printf hook-ran >> hook-ran.txt')"

    before_records="$(run_agent_store find 'kind!=__agent_store_help_absent__')"
    before_source="$(run_agent_store get "$source_id")"
    before_target="$(run_agent_store get "$target_id")"
    before_links="$(run_agent_store links "$source_id")"
    before_hooks="$(run_agent_store hook ls)"

    assert_help "Usage: agent-store init" init --help
    assert_help "Usage: agent-store init" init -h
    assert_help "Usage: agent-store create" create --help
    assert_help "Usage: agent-store create" create -h
    assert_help "Usage: agent-store create" cr --help
    assert_help "Usage: agent-store create" cr -h
    assert_help "Usage: agent-store find" find --help
    assert_help "Usage: agent-store find" find -h
    assert_help "Usage: agent-store find" ls --help
    assert_help "Usage: agent-store find" ls -h
    assert_help "Usage: agent-store get" get --help
    assert_help "Usage: agent-store get" get -h
    assert_help "Usage: agent-store set" set --help
    assert_help "Usage: agent-store set" set -h
    assert_help "Usage: agent-store unset" unset --help
    assert_help "Usage: agent-store unset" unset -h
    assert_help "Usage: agent-store rm" rm --help
    assert_help "Usage: agent-store rm" rm -h
    assert_help "Usage: agent-store link" link --help
    assert_help "Usage: agent-store link" link -h
    assert_help "Usage: agent-store unlink" unlink --help
    assert_help "Usage: agent-store unlink" unlink -h
    assert_help "Usage: agent-store links" links --help
    assert_help "Usage: agent-store links" links -h
    assert_help "Usage: agent-store ctx" ctx --help
    assert_help "Usage: agent-store ctx" ctx -h
    assert_help "Usage: agent-store ctx" context --help
    assert_help "Usage: agent-store ctx" context -h
    assert_help "Usage: agent-store hook <COMMAND>" hook --help
    assert_help "Usage: agent-store hook <COMMAND>" hook -h
    assert_help "Usage: agent-store hook add" hook add --help
    assert_help "Usage: agent-store hook add" hook add -h
    assert_help "Usage: agent-store hook ls" hook ls --help
    assert_help "Usage: agent-store hook ls" hook ls -h
    assert_help "Usage: agent-store hook rm" hook rm --help
    assert_help "Usage: agent-store hook rm" hook rm -h

    test "$(run_agent_store find 'kind!=__agent_store_help_absent__')" = "$before_records"
    test "$(run_agent_store get "$source_id")" = "$before_source"
    test "$(run_agent_store get "$target_id")" = "$before_target"
    test "$(run_agent_store links "$source_id")" = "$before_links"
    test "$(run_agent_store hook ls)" = "$before_hooks"
    test ! -e hook-ran.txt
    printf "%s\n" "$before_hooks" | grep -Fq "$hook_id create -- 'printf hook-ran >> hook-ran.txt'"

    mkdir noninit
    (
      cd noninit
      assert_help "Usage: agent-store init" init --help
      test ! -e .agent-store
      test ! -e .gitignore
    )
    ;;

  *)
    echo "usage: $0 {subcommand_help_is_read_only}" >&2
    exit 2
    ;;
esac
