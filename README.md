<h1 align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/av/agent-store/master/assets/logo-dark.svg"><img src="https://raw.githubusercontent.com/av/agent-store/master/assets/logo-light.svg" alt="agent-store" width="438"></picture></h1>

<p align="center">
  <a href="https://github.com/av/agent-store/actions/workflows/ci.yml"><img src="https://github.com/av/agent-store/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
  <a href="https://github.com/av/agent-store/releases/latest"><img src="https://img.shields.io/github/v/release/av/agent-store" alt="Latest release"></a>
  <a href="https://av.github.io/agent-store/"><img src="https://img.shields.io/badge/docs-av.github.io-1a7f37" alt="Documentation"></a>
  <a href="https://github.com/av/agent-store/blob/master/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center"><b>Persistent, queryable memory for coding agents</b>: one binary, one SQLite file in your repo, no server.</p>

**Your coding agent forgets everything when the session ends.** Decisions made, dead ends explored, conventions discovered — all re-derived (or contradicted) next time, burning context on rediscovery. `agent-store` gives agents persistent memory that lives inside the repo, as a CLI any agent can already use:

```sh
$ agent-store create decision area=http choice=reqwest reason="rustls default, no openssl build dep"
9kuvgz

# ...weeks and many sessions later, before touching HTTP code:
$ agent-store find kind=decision area=http
9kuvgz decision area=http choice=reqwest reason='rustls default, no openssl build dep'
```

![agent-store demo: init, create records, query with the find language, update with set, ctx summary](https://raw.githubusercontent.com/av/agent-store/master/assets/demo.gif)

It is deliberately not a "memory platform":

- **No server, no daemon, no config** — state is a single SQLite file in your project's `.agent-store/` (gitignored, yours to `sqlite3` open). Concurrent agents are safe — WAL mode, serialized transactional writes — and everything exports as JSONL, so there's no lock-in.
- **No embeddings, no API keys, no LLM in the binary** — exact, structured recall (`find kind=task status=pending`), not similarity search.
- **No schema** — a record is a `kind` plus free-form `key=value` fields; links, mutation hooks, and schedules on top when you want them.
- **Agent-native without a protocol** — works with Claude Code, Codex, Cursor, and anything that can run a shell command. `init` installs skills and an `AGENTS.md`/`CLAUDE.md` block so agents discover the store on their own, and `agent-store ctx` prints a byte-capped summary that starts the next session from memory instead of a blank slate.

It's just as usable by humans as a terse project notebook: task tracker, decision log, handoff memory.

## Install

Most installs are done by a coding agent, not a human. Tell yours:

> Install agent-store from https://github.com/av/agent-store and initialize it in this repo.

Or hand it (or run yourself) this block — non-interactive, from the project root, no sudo needed:

```sh
curl -fsSL https://raw.githubusercontent.com/av/agent-store/master/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
agent-store --version
agent-store init
```

The installer detects OS/arch (Linux x86_64, macOS x86_64/arm64), downloads the latest release binary, **verifies its SHA-256 checksum**, and installs to `~/.local/bin` — no root, no prompts, nonzero exit on any failure (set `AGENT_STORE_INSTALL_DIR` to override the directory, `AGENT_STORE_VERSION` to pin a tag; only the `/usr/local/bin` fallback, used when `~/.local/bin` isn't writable, needs sudo). The `export PATH` line covers the current shell if `~/.local/bin` isn't already on your `PATH` — add it to your shell profile to make it stick (the installer prints the exact line when it's needed). `agent-store --version` confirms the binary works; `agent-store init` sets up the current project — store, agent skills, `AGENTS.md`/`CLAUDE.md` block (see [Quickstart](#quickstart)).

### Other ways to install

For humans installing by hand, or platforms the script doesn't cover:

- **Homebrew** (macOS and Linux; includes man page and completions): `brew install av/tap/agent-store`
- **Nix** (flakes; includes man page and completions): `nix profile install github:av/agent-store`, or `nix run github:av/agent-store` to try it without installing. `nix develop` gives a dev shell with the Rust toolchain, clippy, and rustfmt.
- **cargo-binstall** (prebuilt, no compile): `cargo binstall --git https://github.com/av/agent-store agent-store-cli` (the crate is `agent-store-cli`; the binary is still `agent-store`)
- **Build from source** (needs [Rust](https://rustup.rs) 1.78+ and a C compiler — the bundled SQLite compiles from source, so `apt install gcc` first on a fresh machine): `cargo install --git https://github.com/av/agent-store`
- **Prebuilt binaries** for Linux (x86_64 gnu/musl), macOS (x86_64/arm64), and Windows (x86_64) from [GitHub Releases](https://github.com/av/agent-store/releases) — each with a SHA-256 checksum and a signed build-provenance attestation

**Windows:** the install script is unix-only — the simplest paths are `cargo binstall` (prebuilt) or `cargo install` above, both of which work on Windows. Or download `agent-store-<tag>-x86_64-pc-windows-msvc.zip` from Releases (its checksum lives in the matching `...-msvc.sha256` asset), unzip — `agent-store.exe` sits at the archive root — and put it on your `PATH`; a copy-paste PowerShell download+verify+extract block is in [Install details](docs/install.md#windows). The core CLI works natively; [hooks](docs/hooks.md) run their commands via `bash -c`, so hooks require a `bash` on `PATH` (Git Bash or WSL) — everything else works without one. The bundled shell completions and man page are for unix shells.

Manual checksum/attestation verification, shell completions, the man page, and upgrade/uninstall paths: [Install details](docs/install.md).

## Quickstart

```sh
$ agent-store init
Initialized .agent-store/
Installed .agents/skills/agent-store/SKILL.md
Installed .agents/skills/agent-store-patterns/SKILL.md
Installed .agents/skills/agent-store-pipelines/SKILL.md
Installed .claude/skills/agent-store/SKILL.md
Installed .claude/skills/agent-store-patterns/SKILL.md
Installed .claude/skills/agent-store-pipelines/SKILL.md
No AGENTS.md or CLAUDE.md found; create one and re-run `agent-store init` to add the instructions block

$ agent-store create task title="ship v0.1" status=pending
7f0owa

$ agent-store set 7f0owa status=done
Updated 7f0owa

$ agent-store ctx
Quick Context
Records: 1
Record kinds:
  task: 1
    fields: status, title
    status: done=1
Hooks: 0
Schedules: none
Latest activity: 2026-08-02T19:10:30.437Z
Recent records:
  7f0owa task status=done title='ship v0.1'
```

`init` creates `.agent-store/` (and gitignores it), installs the builtin skills into `.agents/skills/` and `.claude/skills/`, and adds managed agent-store instructions to existing `AGENTS.md` and `CLAUDE.md` files. `ctx` is what an agent runs at session start: the whole store, summarized, in one block that never outgrows its budget.

IDs are short and prefix-resolvable: any unambiguous prefix works wherever a command takes an ID (`get`, `set`, `unset`, `rm`, `link`, ...).

## How agents use it

You run `init` once. From then on the agent finds everything itself: the installed skills teach it the commands and conventions, and the `AGENTS.md`/`CLAUDE.md` block points it at `ctx` and the skills (a one-line convention of your own, or a `SessionStart` hook, makes `ctx` automatic every session — see the link below). As it works, it records what matters:

```sh
# Session 1 — the reqwest decision from the top of this page, plus the follow-up work:
$ agent-store create decision area=http choice=reqwest reason="rustls default, no openssl build dep"
9kuvgz
$ agent-store create task title="Migrate HTTP client to reqwest" status=pending
wau740
$ agent-store link wau740 implements 9kuvgz
Linked wau740 implements 9kuvgz
```

The session ends. The context window is gone; the records are not. Days later, the next session opens with `ctx`:

```
Quick Context
Records: 2
Record kinds:
  decision: 1
    fields: area, choice, reason
  task: 1
    fields: status, title
    status: pending=1
Links: 1
  implements: 1
...
Recent records:
  wau740 task status=pending title='Migrate HTTP client to reqwest'
  9kuvgz decision area=http choice=reqwest reason='rustls default, no openssl build dep'
```

The agent sees the pending migration and the reasoning behind it without being told, finishes the work, and runs `agent-store set wau740 status=done`. No re-discovery, no contradicted decisions.

For the full walkthrough — Claude Code setup, `SessionStart` hook that injects `ctx` automatically, CLAUDE.md conventions — see [Using agent-store with Claude Code](docs/claude-code.md).

## Why not just...?

You already have something that sort of works. Here's an honest comparison:

- **...a `MEMORY.md` / `TODO.md`?** Genuinely the better tool while the list is short and a human co-edits it. It stops working when the agent has to re-read and re-parse a growing file on every turn: notes files can't answer `find kind=task status=pending --sort created_at --limit 5`, carry no timestamps or links, and grow without a cap — while `ctx` stays the same fixed size no matter how many records accumulate. And you don't have to start over: `jq -R -c '{kind:"note",fields:{text:.}}' MEMORY.md | agent-store create --stdin` imports the file you already have, turning each line into a record ([examples/import-memory-md.sh](examples/import-memory-md.sh) also shows a structured variant that keeps your headings queryable).
- **..."my agent greps the repo"?** Grep finds what the code *says*, not what you *decided* — the rejected alternative, the dead end that cost an afternoon, the convention that isn't written anywhere. Those live only in the transcript, and the transcript is gone. (The store itself is grep-friendly: one record per line.)
- **...a vector-memory MCP server?** Different problem. That's semantic similarity — "notes vaguely about auth" — with embeddings, ranking, and a server to integrate per harness. This is exact, deterministic recall (`find kind=decision area=auth`) from a plain CLI, so the same query returns the same records every time, with no protocol integration and nothing running in the background. If you need fuzzy semantic search, a vector store is the right tool; most agent memory turns out to be "what's pending and what did we decide," which isn't.
- **...git history?** Commits record what changed, not the decisions, findings, and open tasks around the change — and querying prose with `git log --grep` is archaeology, not recall. The store is a gitignored file next to the repo, so it's untouched by branch switches; note that a separate `git worktree` is a separate directory and gets its own store.

The [FAQ](docs/faq.md) has the longer versions, including why not raw `sqlite3` + `jq`.

## Commands

| Command | What it does |
| --- | --- |
| `init` | Initialize the store, install skills, wire up AGENTS.md/CLAUDE.md |
| `create` (`cr`) | Create a record; `--stdin` bulk-imports JSONL |
| `find` (`ls`) | Query records; `--sort`, `--desc`, `--limit`, `--count`, `--timestamps` |
| `get` | Print one record by ID prefix |
| `set` / `unset` | Update or remove fields atomically |
| `rm` | Delete a record |
| `link` / `unlink` / `links` | Manage directional, named links between records |
| `ctx` (`context`) | Compact Quick Context summary, capped at 8192 bytes |
| `hook` | `add`/`ls`/`rm`/`runs` — run a bash command on matching mutations; inspect captured runs |
| `schedule` | `add` one-shot (`at`) or recurring (`every`) commands; `tick` runs what's due; `enable` wires up crontab; plus `ls`/`rm`/`runs`/`disable` |

Everywhere: `--json` gives structured output on any command, any unambiguous ID prefix resolves, and `agent-store <command> --help` has the full details.

## Query language

`find` and hook filters share a small query language — comparisons (`=`, `!=`, `<`, `<=`, `>`, `>=`, `~=` substring, `link.out`/`link.in`) joined with `and`, `or`, `not`, and parentheses:

```sh
agent-store find 'kind=task and (status=pending or status=blocked) and not owner=bot'
agent-store find 'created_at>2026-01-01'       # built-in timestamps
```

Value types, quoting, precedence, and link predicates: [Query language](docs/queries.md).

## Hooks

Hooks run a bash command whenever matching records mutate — useful for notifications, mirroring state into files, or nudging an agent.

![agent-store demo: link a finding to a task, add a hook on task updates that creates an event record, trigger it with set, then see the event in find, links, and ctx](https://raw.githubusercontent.com/av/agent-store/master/assets/demo-hooks.gif)

```sh
agent-store hook add set kind=task -- 'notify-send "task $AGENT_STORE_ID: $AGENT_STORE_NEW_VALUE"'
agent-store hook runs            # inspect recent runs and captured output
```

Hooks fire on `create`, `set`, `unset`, `rm`, `link`, and `unlink`; the command gets the affected record on stdin plus `AGENT_STORE_*` environment variables, with a 30-second timeout. Full event/variable reference and limits: [Hooks](docs/hooks.md).

## Schedules

Schedules run a bash command on a time basis — one-shot reminders or recurring maintenance — with the same execution model and limits as hooks:

```sh
agent-store schedule add at 5m -- 'echo reminder'            # one-shot (also absolute timestamps)
agent-store schedule add every 1h kind=task -- 'notify.sh'   # recurring, once per matching record
```

Nothing runs in the background on its own: `schedule tick` executes what's due, and `schedule enable` sets up a crontab entry that ticks every minute. Details: [Schedules](docs/schedules.md).

## JSON output

Every command supports `--json` for structured output, and exports round-trip — `create --stdin` bulk-imports the same JSONL that `find --json | jq -c '.records[]'` emits:

```sh
$ agent-store find kind=task --json
{"records":[{"created_at":"2026-07-03T09:16:49.608Z","fields":{"status":"done","title":"ship v0.1"},"id":"7f0owa","kind":"task","updated_at":"2026-07-03T09:16:49.612Z"}]}
```

Scripting behaves the way a shell expects: results on stdout, errors on stderr, nonzero exit on failure (a `get` on a missing ID exits 1; an empty `find` still exits 0 with `{"records":[]}`). Envelope shapes, import validation, and the linked-store caveat: [JSON output and import](docs/json.md).

## Skills

`init` installs three agent-facing skill docs (`agent-store`, `agent-store-patterns`, `agent-store-pipelines`) into `.agents/skills/` and `.claude/skills/`, so coding agents pick up the store without prompting. They're written for agents but double as concise usage docs — worth a read even for human use. What each covers: [Skills and agent integration](docs/skills.md). Which agent reads which files: [Claude Code, Codex and Cursor](docs/agents.md).

## Documentation

- [Install details](docs/install.md) — verifying downloads, completions and man page, upgrade/uninstall
- [Using with Claude Code, Codex and Cursor](docs/agents.md) — what `init` writes, which files each agent reads, the fresh-repo step
- [Using agent-store with Claude Code](docs/claude-code.md) — setup, CLAUDE.md conventions, session-start context injection, a worked two-session example
- [Concepts](docs/concepts.md) — the mental model: stores, records, links, queries, hooks, and the `ctx` budget, each with a verified example
- [Query language](docs/queries.md) — operators, value types, combinators, quoting, timestamps, links, sorting
- [Hooks](docs/hooks.md) — events, environment variables, limits, inspecting runs
- [Schedules](docs/schedules.md) — one-shot and recurring commands, ticking, crontab integration
- [JSON output and import](docs/json.md) — `--json` shapes, `create --stdin`, pipeline recipes
- [Skills and agent integration](docs/skills.md) — what `init` installs and the conventions agents pick up
- [FAQ](docs/faq.md) — why not markdown/jq/a vector DB/git history, data format and inspection, concurrency, privacy, measured limits
- [Examples](examples/README.md) — runnable scripts: task tracker, decision log, session handoff, MEMORY.md import, JSONL pipelines, audit hooks, linked memory graph

## Stability

agent-store is v0.1.x — early, but the data layer is the part treated as stable. The store is a plain SQLite file with a versioned, checksummed schema; upgrades apply migrations automatically on open, so existing records, links, and hook history survive new releases (covered by [tests that open old-schema stores](https://github.com/av/agent-store/blob/master/tests/upgrade.rs)). Pre-1.0, CLI flags, output wording, and `--json` shapes may still change between minor versions — pin a version if you script against exact output, and check the [CHANGELOG](CHANGELOG.md) before upgrading. Worst case, nothing is locked in: `find --json` exports every record (one `jq -c '.records[]'` away from JSONL that `create --stdin` re-imports), and `.agent-store/store.sqlite` is a normal SQLite file readable by stock `sqlite3` or any SQLite tool.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup and workflow.

## License

[MIT](LICENSE). Third-party components bundled into release binaries (including SQLite) are listed in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
