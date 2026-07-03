# Contributing

Thanks for helping improve agent-store. Issues and PRs welcome.

## Dev setup

You need a stable Rust toolchain with `rustfmt` and `clippy` (via [rustup](https://rustup.rs)). No other dependencies — SQLite is bundled.

```sh
cargo build
cargo test
```

CI gates every PR on exactly these four commands — run them before pushing:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo build --verbose
cargo test --verbose
```

Slow hook-timeout stress tests are `#[ignore]`d by default; run them with `cargo test --test hook_stress -- --ignored` if you touch hook execution.

## Project layout

```
src/main.rs    binary entry point, command dispatch, init
src/cli.rs     hand-rolled argument parser (not clap)
src/query.rs   find query language: parsing and evaluation
src/store.rs   SQLite-backed store: records, links, hooks, ctx
src/value.rs   typed field values and comparison semantics
src/output.rs  text and --json rendering
tests/         integration tests plus fact-check scripts in tests/facts/
docs/          user-facing deep dives (queries, hooks, json, skills)
```

## Spec workflow

This project is fact-driven: `.facts` files in the repo root are the spec, and every behavior change starts with a fact. See [AGENTS.md](AGENTS.md) for the full workflow and the [facts](https://github.com/av/facts) tool it uses. In short: read the relevant section with `facts list`, add or sharpen a fact describing the new behavior, implement, verify with `facts check`, tag `@implemented`.

## Pull requests

- Keep PRs focused — one behavior change per PR.
- Add or update a fact for any user-visible behavior change, and cover it with a test.
- Update the relevant docs (`README.md`, `docs/`, `man/agent-store.1`, completions) when the CLI surface changes.
- Add a `CHANGELOG.md` entry under Unreleased for user-visible changes.
