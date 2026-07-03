# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-03

First public release.

### Added

- Shell completions for bash, zsh, and fish (`completions/`) and a man page
  (`man/agent-store.1`), bundled into release archives.
- `agent-store init` creates a project-local SQLite store under `.agent-store/`
  and installs the agent-facing skills (`agent-store`, `agent-store-patterns`,
  `agent-store-pipelines`) into `.agents/skills/`, appending pointers to
  `AGENTS.md`/`CLAUDE.md`.
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

[0.1.0]: https://github.com/av/agent-store/releases/tag/v0.1.0
