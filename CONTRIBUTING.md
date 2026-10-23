# Contributing

Thanks for helping improve agent-store. Issues and PRs welcome.

## Dev setup

You need a stable Rust toolchain (1.78 or newer) with `rustfmt` and `clippy` (via [rustup](https://rustup.rs)). No other dependencies — SQLite is bundled.

```sh
cargo build
cargo test
```

CI runs three jobs on every PR. The first is these four commands — run them before pushing:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo build --verbose
cargo test --verbose
```

The second runs the slow hook-timeout stress tests, which are `#[ignore]`d by default; run them with `cargo test --test hook_stress -- --ignored` if you touch hook execution. The third is the fact suite (see [Spec workflow](#spec-workflow)): `facts lint && facts fmt --check`, then `facts check --no-agent`.

## Project layout

```
src/main.rs    binary entry point, command dispatch, init and its skill
               texts, hook and schedule execution, crontab integration
src/cli.rs     hand-rolled argument parser (not clap)
src/query.rs   find query language: parsing and evaluation
src/store.rs   SQLite-backed store: records, links, hooks, schedules, ctx,
               schema migrations
src/value.rs   typed field values and comparison semantics
src/output.rs  text and --json rendering
*.facts        the spec: .facts, concurrency.facts, json-hooks.facts
tests/         integration tests; tests/facts/ holds the shell scripts
               that fact commands run
docs/          user-facing docs (install, agents, Claude Code tutorial,
               concepts, queries, hooks, schedules, json, skills, faq)
examples/      runnable example scripts
```

## Spec workflow

This project is fact-driven: the `.facts` files in the repo root are the spec, and every behavior change starts with a fact. A fact is a one-line claim about behavior, usually with a command that checks it (often a function in a `tests/facts/` script). [facts](https://github.com/av/facts) is the CLI that lists, lints and checks them; install it with `curl -fsSL https://av.codes/facts.sh | sh` (or `npm install -g @avcodes/facts`, or `pipx install facts-cli`; CI pins v0.7.1).

In short: read the relevant section with `facts list --section <name>`, add or sharpen a fact describing the new behavior, implement, verify with `facts check --tags <tag>` (the full suite is slow; scope it), and tag the fact `@implemented`. The full workflow is in [AGENTS.md](https://github.com/av/agent-store/blob/master/AGENTS.md).

## Pull requests

- Keep PRs focused — one behavior change per PR.
- Add or update a fact for any user-visible behavior change, and cover it with a test.
- Update the relevant docs (`README.md`, `docs/`, `man/agent-store.1`, completions) when the CLI surface changes.
- Add a `CHANGELOG.md` entry under Unreleased for user-visible changes.
