#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Runs install.sh in dry-run mode with `uname` reporting the given OS and
# machine, so target selection is checked without network access.
dry_run_installer() {
  local os="$1" arch="$2"
  mkdir -p "$tmp/shim"
  cat >"$tmp/shim/uname" <<EOF
#!/bin/sh
case "\$1" in
  -s) echo "$os" ;;
  -m) echo "$arch" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$tmp/shim/uname"
  PATH="$tmp/shim:$PATH" INSTALL_DRY_RUN=1 AGENT_STORE_VERSION=v9.9.9 sh "$repo/install.sh"
}

expect_target() {
  local os="$1" arch="$2" target="$3" out
  out="$(dry_run_installer "$os" "$arch")"
  grep -Fxq "dry run: target=$target" <<<"$out" || {
    printf "%s %s: expected target %s, got:\n%s\n" "$os" "$arch" "$target" "$out" >&2
    return 1
  }
  grep -Fq "releases/download/v9.9.9/agent-store-v9.9.9-$target.tar.gz" <<<"$out"
}

installer_targets() {
  expect_target Linux aarch64 aarch64-unknown-linux-musl
  expect_target Linux arm64 aarch64-unknown-linux-musl
  expect_target Linux x86_64 x86_64-unknown-linux-musl
  expect_target Darwin arm64 aarch64-apple-darwin
  expect_target Darwin x86_64 x86_64-apple-darwin

  local err="$tmp/riscv.err"
  if dry_run_installer Linux riscv64 >/dev/null 2>"$err"; then
    echo "riscv64 Linux should be refused" >&2
    return 1
  fi
  grep -Fq "unsupported Linux architecture: riscv64" "$err"
  grep -Fq "cargo install" "$err"
}

case "$case_name" in
  installer_targets) installer_targets ;;
  *)
    printf "unknown case: %s\n" "$case_name" >&2
    exit 2
    ;;
esac
