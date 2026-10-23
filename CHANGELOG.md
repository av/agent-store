# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An upgrade test opens stores written by the released v0.1.0, v0.1.1 and
  v0.1.2 binaries and checks that every record, link, hook run and
  schedule survives and schema migration 3 is applied.
- Cargo.toml declares `rust-version = "1.78"` (minimum supported Rust for
  `cargo install`), and `homepage`/`documentation` point at the docs site.
- Docs: a "Claude Code, Codex and Cursor" page (`docs/agents.md`): what
  `init` writes, which agent reads which file, and the step for a fresh
  repo with no `AGENTS.md`/`CLAUDE.md` yet.
- Docs: `docs/install.md` with download verification and attestations,
  shell completions and the man page, installer options, upgrade and
  uninstall per install channel, and a Windows PowerShell
  download-verify-install block.
- Docs: the README covers the session-to-session memory loop, "Why not
  just...?" (MEMORY.md, grep, vector memory, git history) and a Stability
  section; the FAQ covers git history, sharing a store with a worktree or
  seeding a clone, and measured 10k-record performance.
- Example `examples/import-memory-md.sh`: migrate an existing MEMORY.md
  into the store.
- Brand: a new logo with light/dark variants, a hooks/links demo GIF, and
  a social preview card with Open Graph/Twitter meta on the docs site.

### Changed

- Re-running `agent-store init` refreshes builtin skill files and the
  managed `AGENTS.md`/`CLAUDE.md` block that are unmodified copies from an
  earlier release, so upgraded projects get current skills such as the
  schedules section. Edited files are kept and reported with how to
  replace them. `init --json` adds `skills_refreshed` and
  `skills_modified`, and an instruction status may be `refreshed` or
  `modified`.
- `--help`, the man page and the crate description use one tagline:
  "Persistent, queryable memory for coding agents: one binary, one SQLite
  file in your repo, no server."
- Release binaries are built with `--locked` from `Cargo.lock`, and the
  release workflow flags a skipped crates.io publish or Homebrew tap bump
  with a notice instead of skipping silently.
- The package manifest ships only an allowlist of files (`src/`,
  `Cargo.toml`, licenses, `README.md`, `CHANGELOG.md`).

### Fixed

- `schedule enable`/`disable` no longer touch another project's crontab
  entry when one project root is a prefix of another, quote project and
  binary paths (spaces, quotes, `%`) in the cron line, record the invoked
  `agent-store` path so Homebrew/Nix upgrades keep the entry working, and
  refuse to rewrite a crontab that `crontab -l` could not read.
- `schedule add at` rejects dates and times that do not exist
  (`2026-02-30`, `25:99`, trailing text) with exit 2 instead of storing a
  schedule that never fires correctly, stores timestamps with a UTC offset
  as their UTC instant so `tick` fires them on time, and no longer panics
  on a duration ending in a non-ASCII character.
- The Nix flake builds again; it had failed since v0.1.2 (two
  sandbox-incompatible hook tests are now skipped in the Nix check phase),
  and the flake's package version comes from Cargo.toml instead of a stale
  hard-coded 0.1.1.
- Install docs: the "Verifying release downloads" snippet fetched a
  nonexistent `<archive>.sha256` (checksums are named after the target)
  and the attestation command used an unset `$asset`; the `cargo
  uninstall` name is `agent-store-cli`; the uninstall section covers
  crontab entries and `init` leftovers. The release notes template's
  verify snippet and binstall crate name are fixed too.
- Docs: sample outputs that differed from the binary are re-captured from
  real runs.

## [0.1.2] - 2026-07-13

### Added

- Docs: Schedules page (`docs/schedules.md`) covering `add at`/`add every`,
  `tick`, crontab `enable`/`disable`, per-record execution, run capture,
  timeouts, and the shared hook/schedule recursion cap — plus a README
  Schedules section. The feature shipped in v0.1.1 with only `--help` docs.
- Docs: the JSON import/export recipe now warns that record JSON carries no
  links, so copying a store via `find --json | create --stdin` drops edges
  (recreate them via `links <id> --json` + `link`).
- Docs: the `ctx` 8192-byte cap is qualified — it applies to text output only
  (`ctx --json` is uncapped) — and the truncation fallback is documented.

### Changed

- Hook dispatch is capped at recursion depth 3: hook and schedule commands
  run with `AGENT_STORE_HOOK_DEPTH` set, and mutations made at the cap skip
  hook dispatch (with a note on stderr) instead of recursing without bound.
- When a post-commit hook fails, the mutation's normal stdout output (record
  ID, or the full JSON envelope in `--json` mode) is still printed; the hook
  failure goes to stderr and the exit code remains 1. Previously the new
  record's ID was only visible embedded in the error text.
- `set`/`unset` that change nothing now report `Unchanged <id>`
  (`"status": "unchanged"` in `--json` mode) and no longer bump `updated_at`
  or write a store event, so no-op mutations don't create false activity
  signals. Hooks still fire.
- `find --count` reports the total number of matching records, ignoring
  `--limit`, as documented.

### Fixed

- `ctx` text output could exceed its own 8192-byte cap by one byte; the
  truncation notice now fits within the budget.
- `create` rejects an empty kind (exit 2) instead of storing a nameless
  record kind.
- `schedule disable` now fails with exit 1 when the `crontab` binary cannot
  be run, instead of masking the error as "No crontab entry found".

## [0.1.1] - 2026-07-04

### Added

- Docs: "Using agent-store with Claude Code" tutorial (`docs/claude-code.md`)
  — setup, CLAUDE.md conventions, session-start context injection via a
  Claude Code `SessionStart` hook, and a worked two-session example.
- README "Upgrading and uninstalling" section: per-channel upgrade commands
  and a map of everything an install or `init` puts on disk.
- Docs: Concepts page (`docs/concepts.md`) — the mental model behind stores,
  records, links, queries, hooks, and the `ctx` budget.
- README "Verifying release downloads" section: `sha256sum -c` /
  `shasum -a 256 -c` against the published `.sha256` assets and
  `gh attestation verify` for build provenance.
- Release archives (for releases tagged after v0.1.0) carry signed GitHub
  build provenance attestations, generated by the release workflow.
- `cargo-binstall` support: `[package.metadata.binstall]` in `Cargo.toml`
  points at the prebuilt release archives.
- Homebrew install instructions (`brew install av/tap/agent-store`) in the
  README.
- Release automation: crates.io publish and Homebrew tap formula bump jobs
  in the release workflow (each skipped when its secret is absent; the
  secrets were not set, so neither ran for v0.1.1 or v0.1.2 and the tap
  formula was not bumped), plus a
  release-notes template (`.github/RELEASE_TEMPLATE.md`) and categories
  config for auto-generated release notes (`.github/release.yml`).
- Crate-level rustdoc in `src/lib.rs` and fuller Cargo.toml metadata
  (homepage, documentation, keywords) for registry listings.
- Documentation website: MkDocs site built from the README and `docs/`,
  deployed to GitHub Pages by a new `docs.yml` workflow.
- `examples/memory-graph.sh`: linked memory graph across sessions —
  `link.in`/`link.out`/`link.out.<rel>=<id>` traversal, `ctx` relation
  counts, self-link rejection, and the `--json` error envelope.

### Changed

- The package is named `agent-store-cli` (the bare `agent-store` name is
  taken on crates.io by an unrelated crate); the binary and library keep
  the `agent-store` name. It has not been published to crates.io; install from
  the GitHub release archives or with `cargo install --git`.
- `--json` mode now reports runtime errors as a structured
  `{"error":"<message>"}` object on stderr with exit codes unchanged;
  usage errors from argument parsing stay plain text.
- Clearer CLI errors: kind and field-name validation errors now list the
  disallowed characters and echo the offending name, and queries using
  uppercase `AND`/`OR`/`NOT` get a hint that query keywords are lowercase.
- Typo'd commands now get a "did you mean" suggestion
  (`agent-store creat` suggests `create`, `hook runz` suggests `runs`).
- The lowercase-keyword hint now also covers uppercase `AND`/`OR`/`NOT`
  in the middle of a query expression, not just trailing keywords.
- `link` now rejects linking a record to itself
  (`error: cannot link a record to itself (<id>)`) instead of silently
  creating a self-edge that counted as both an incoming and an outgoing
  link. Nothing is written on rejection; `unlink` can still remove
  self-links created by earlier versions.

### Fixed

- `install.sh` downloads the checksum file under its actual release asset
  name, so checksum verification runs instead of being skipped.
- Example scripts resolve a relative `AGENT_STORE` path to an absolute one
  before changing into their temp directory, so the documented
  `AGENT_STORE=target/release/agent-store ./examples/<script>.sh`
  invocation works.

## [0.1.0] - 2026-07-03

First public release.

### Added

- Nix flake (`flake.nix`): `nix run github:av/agent-store`, a default package
  with man page and shell completions installed, and a `nix develop` shell with
  the Rust toolchain, clippy, and rustfmt.
- Shell completions for bash, zsh, and fish (`completions/`) and a man page
  (`man/agent-store.1`), bundled into release archives.
- `agent-store init` creates a project-local SQLite store under `.agent-store/`
  and installs the agent-facing skills (`agent-store`, `agent-store-patterns`,
  `agent-store-pipelines`) into `.agents/skills/`, appending pointers to
  `AGENTS.md`/`CLAUDE.md`. Its output enumerates what happened — installed
  skill paths, instruction blocks added/present per file, and a hint to
  create `AGENTS.md`/`CLAUDE.md` and re-run when neither exists — in both
  text and `--json` modes.
- Clear diagnostics for a stray `.agent-store` file: `init` and store-opening
  commands explain that the path exists but is not a directory instead of
  surfacing a raw OS error or an inaccurate "run 'agent-store init' first"
  hint. Unknown `--flags` on `find`/`ls`, `get`, `rm`, and `links` are
  rejected with an "unknown flag" error pointing at `--help` (exit 2) instead
  of falling through to positional parsing.
- Default record output is always one line per record: field values containing
  newlines or other control characters are rendered with bash ANSI-C quoting
  (`multi=$'line1\nline2'`), so line-by-line piping of `find`/`ls` output stays
  safe and values still round-trip through shell `eval`. Applies to `find`,
  `get`, `ctx` recent records, and the record snapshot piped to hook stdin;
  `--json` output is unchanged.
- Records: `create`, `get`, `set`, `unset`, `rm` with kind and field-name
  validation, generated IDs, unique-prefix ID resolution, and created/updated
  timestamps.
- Query language for `find`: comparison operators (`=`, `!=`, `<`, `<=`, `>`,
  `>=`), contains (`~=`), boolean `and`/`or`/`not`, parentheses, quoted values,
  typed comparisons (numbers, dates, and timestamps on a common UTC timeline),
  link-aware predicates, implicit `and` between multiple query arguments, and
  bare `find` listing all records. `find` flags for sorting and limiting output.
- Links: `link`, `unlink`, `links` for typed relations between records, with
  clear errors when removing a link that does not exist.
- Hooks: `hook add`/`ls`/`rm`/`runs` — shell commands triggered by store
  mutations, optionally filtered by query; run in registration order with a
  snapshot of the record on stdin, mutation context in environment variables,
  8192-byte output capture caps, a 30-second timeout enforced on the whole
  process group, and signal-aware failure reporting. Hook runs are persisted
  and inspectable via `hook runs`.
- `ctx` quick context: compact project summary (statuses, fields, links,
  recent records) under a byte cap, suitable for injecting into agent prompts.
- `--json` output mode for all commands, plus JSONL import for bulk loading
  records.
- Robustness: transactional mutations, safe concurrent access (ID-prefix and
  hook races covered by tests), graceful handling of broken stdout pipes, and
  an explicit error when commands run before `init`.

[Unreleased]: https://github.com/av/agent-store/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/av/agent-store/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/av/agent-store/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/av/agent-store/releases/tag/v0.1.0
