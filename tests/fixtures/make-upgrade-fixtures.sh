#!/usr/bin/env bash
# Regenerates tests/fixtures/upgrade/v0.1.{0,1,2}.sqlite: stores written by the
# real released agent-store binaries, opened by tests/upgrade.rs with HEAD.
#
#   bash tests/fixtures/make-upgrade-fixtures.sh
#
# Downloads each release's x86_64-unknown-linux-musl tarball from GitHub,
# checks it against the SHA-256 pinned below (the same value the release's
# .sha256 asset publishes), then drives that binary through `init`, records
# (including a multi-line value), links, a hook with a hook run and, from
# v0.1.1 on, schedules with a schedule run. Only the resulting store.sqlite is
# kept. Record IDs and timestamps differ per run; tests/upgrade.rs asserts on
# content, not IDs. Needs bash, curl, tar, sha256sum and Linux x86_64.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$repo/tests/fixtures/upgrade"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

declare -A sha256=(
  [v0.1.0]=b1694921b8efbb333bb4c88eb756ae17775e7e46342ff1fc6864976b24f88370
  [v0.1.1]=e99643251f8da2914ef2af1934d8e4ad26a6d30247ec26769aa2b75679a82449
  [v0.1.2]=312220bc7e9bf1802a8b760c243512b1aaae592da8924d49dca7f4d3f45d7742
)

mkdir -p "$out"

for version in v0.1.0 v0.1.1 v0.1.2; do
  asset="agent-store-$version-x86_64-unknown-linux-musl.tar.gz"
  mkdir -p "$work/$version/bin" "$work/$version/project"
  curl -fsSL --retry 3 -o "$work/$version/$asset" \
    "https://github.com/av/agent-store/releases/download/$version/$asset"
  echo "${sha256[$version]}  $work/$version/$asset" | sha256sum -c -
  tar -xzf "$work/$version/$asset" -C "$work/$version/bin" agent-store
  bin="$work/$version/bin/agent-store"
  "$bin" --version

  (
    cd "$work/$version/project"
    "$bin" init >/dev/null

    plan=$("$bin" create task title="Ship the upgrade" status=open priority=2 \
      body=$'Step one: open the old store.\nStep two: check every field.\n\nTrailing line after a blank line.')
    note=$("$bin" create note title="Release checklist" text="written by agent-store $version")
    bug=$("$bin" create bug title="Hook output survives upgrades" status=open)
    "$bin" link "$plan" blocks "$bug"
    "$bin" link "$note" references "$plan"

    "$bin" hook add set kind=task -- 'printf "hooked %s %s\n" "$AGENT_STORE_EVENT" "$AGENT_STORE_FIELD"' >/dev/null
    "$bin" set "$plan" status=doing

    if [ "$version" != v0.1.0 ]; then
      "$bin" schedule add every 1d kind=bug -- 'printf "daily %s\n" "$AGENT_STORE_ID"' >/dev/null
      "$bin" schedule add at 1s -- 'printf "one-shot ran\n"' >/dev/null
      sleep 2
      "$bin" schedule tick >/dev/null
    fi
  )

  cp "$work/$version/project/.agent-store/store.sqlite" "$out/$version.sqlite"
  test ! -e "$work/$version/project/.agent-store/store.sqlite-wal" \
    || test ! -s "$work/$version/project/.agent-store/store.sqlite-wal"
  echo "wrote $out/$version.sqlite ($(wc -c <"$out/$version.sqlite") bytes)"
done
