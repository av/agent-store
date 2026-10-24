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
$ agent-store create decision area=http choice=reqwest reason="no openssl dep"
w4054s

# ...weeks and many sessions later, before touching HTTP code:
$ agent-store find kind=decision area=http
w4054s decision area=http choice=reqwest reason='no openssl dep'
```

<picture><source media="(max-width: 600px)" srcset="https://raw.githubusercontent.com/av/agent-store/master/assets/demo-phone.gif"><img src="https://raw.githubusercontent.com/av/agent-store/master/assets/demo.gif" alt="agent-store demo: create records, query them with the find language, update one with set, then the ctx summary"></picture>

It is deliberately not a "memory platform":

- **No server, no daemon, no config** — state is a single SQLite file in your project's `.agent-store/` (gitignored, yours to `sqlite3` open). It belongs to that checkout on that machine: a `git worktree`, a fresh clone or a cloud agent's sandbox starts without it unless you [link or seed it](docs/faq.md#does-the-store-follow-worktrees-fresh-clones-ci-or-cloud-agents). Concurrent agents in one checkout are safe — WAL mode, serialized transactional writes — and nothing is locked in: the store is a plain SQLite file, and records export as JSONL (record fields only: links and IDs are not carried, see [JSON output](#json-output)).
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
touch AGENTS.md CLAUDE.md   # init adds its block only to files that exist
agent-store init
```

The script picks the build for your OS and architecture (Linux x86_64, macOS x86_64/arm64), **verifies its SHA-256 checksum**, and installs to `~/.local/bin` without root or prompts; any failure exits nonzero. The `export PATH` line covers the current shell; the installer prints the line for your shell profile when `~/.local/bin` isn't on your `PATH`. `touch` makes sure `AGENTS.md` and `CLAUDE.md` exist (existing files keep their content): `init` adds its instructions block only to existing files, and that block is what reliably points Claude Code (`CLAUDE.md`) and Codex (`AGENTS.md`) at the store ([details](docs/agents.md)). Installer options: [Install details](docs/install.md#install-script-options).

### Other ways to install

For humans installing by hand, or platforms the script doesn't cover:

- **Homebrew** (macOS and Linux; includes man page and completions): `brew install av/tap/agent-store`.
- **Nix** (flakes; includes man page and completions): `nix profile install github:av/agent-store`, or `nix run github:av/agent-store` to try it without installing. `nix develop` gives a dev shell with the Rust toolchain, clippy, and rustfmt.
- **cargo-binstall** (prebuilt, no compile): `cargo binstall --git https://github.com/av/agent-store agent-store-cli` (the crate is `agent-store-cli`; the binary is still `agent-store`)
- **Build from source** (needs [Rust](https://rustup.rs) 1.78+ and a C compiler — the bundled SQLite compiles from source, so `apt install gcc` first on a fresh machine): `cargo install --git https://github.com/av/agent-store`
- **Prebuilt binaries** for Linux (x86_64 gnu/musl), macOS (x86_64/arm64), and Windows (x86_64) from [GitHub Releases](https://github.com/av/agent-store/releases) — each with a SHA-256 checksum and a signed build-provenance attestation. There is no Linux arm64 build yet (Graviton, Ampere, arm64 containers on Apple Silicon): use Nix or build from source there.

**Windows:** the install script is unix-only. Use `cargo binstall` or `cargo install` above, or the PowerShell download-and-verify block in [Install details](docs/install.md#windows). Hooks and schedules need a `bash` on `PATH` (Git Bash or WSL); everything else works natively.

Manual checksum/attestation verification, shell completions, the man page, and upgrade/uninstall paths: [Install details](docs/install.md).

## Quickstart

```sh
$ touch AGENTS.md CLAUDE.md
$ agent-store init
Initialized .agent-store/
Installed .agents/skills/agent-store/SKILL.md
Installed .agents/skills/agent-store-patterns/SKILL.md
Installed .agents/skills/agent-store-pipelines/SKILL.md
Installed .claude/skills/agent-store/SKILL.md
Installed .claude/skills/agent-store-patterns/SKILL.md
Installed .claude/skills/agent-store-pipelines/SKILL.md
Added instructions block to AGENTS.md
Added instructions block to CLAUDE.md

$ agent-store create task title="ship v0.1" status=pending
4juoi3

$ agent-store set 4juoi3 status=done
Updated 4juoi3

$ agent-store ctx
Quick Context
Records: 1
Record kinds:
  task: 1
    fields: status, title
    status: done=1
Hooks: 0
Schedules: none
Latest activity: 2026-10-23T05:34:08.084Z
Recent records:
  4juoi3 task status=done title='ship v0.1'
```

`init` creates `.agent-store/` (and gitignores it), installs the builtin skills into `.agents/skills/` and `.claude/skills/`, and adds managed agent-store instructions to `AGENTS.md` and `CLAUDE.md` (only to files that already exist, hence the `touch`). `ctx` is what an agent runs at session start: the whole store, summarized, in one block that never outgrows its budget.

IDs are short and prefix-resolvable: any unambiguous prefix works wherever a command takes an ID (`get`, `set`, `unset`, `rm`, `link`, ...).

## How agents use it

After `init` (with `AGENTS.md` and `CLAUDE.md` in place), the agent finds the store itself: the skills teach it the commands, and the instructions block points it at `ctx`. That makes the store available, not mandatory; a `SessionStart` hook and a few lines of convention make it a habit (`init` does not write these; see the tutorial below). As it works, the agent records what matters:

```sh
# Session 1 — the reqwest decision from the top of this page, plus the follow-up work:
$ agent-store create decision area=http choice=reqwest reason="no openssl dep"
w4054s
$ agent-store create task title="Migrate HTTP client to reqwest" status=pending
ff14fh
$ agent-store link ff14fh implements w4054s
Linked ff14fh implements w4054s
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
  ff14fh task status=pending title='Migrate HTTP client to reqwest'
  w4054s decision area=http choice=reqwest reason='no openssl dep'
```

The agent sees the pending migration and the reasoning behind it without being told, finishes the work, and runs `agent-store set ff14fh status=done`. No re-discovery, no contradicted decisions.

For the full walkthrough — Claude Code setup, `SessionStart` hook that injects `ctx` automatically, CLAUDE.md conventions — see the [Claude Code tutorial](docs/claude-code.md).

## Why not just...?

You already have something that sort of works. Here's an honest comparison:

- **...a `MEMORY.md` / `TODO.md`?** The better tool while the list is short and a human co-edits it. It stops working when the agent re-reads a growing file every turn: notes can't answer `find kind=task status=pending --sort created_at --limit 5`, and they grow while `ctx` stays a fixed size. `jq -R -c '{kind:"note",fields:{text:.}}' MEMORY.md | agent-store create --stdin` imports the file you already have, one record per line ([a structured variant](examples/import-memory-md.sh) keeps headings queryable).
- **..."my agent greps the repo"?** Grep finds what the code *says*, not what you *decided* — the rejected alternative, the dead end that cost an afternoon, the convention that isn't written anywhere. Those live only in the transcript, and the transcript is gone. (The store itself is grep-friendly: one record per line.)
- **...a vector-memory MCP server?** Different problem: semantic similarity ("notes vaguely about auth") with embeddings and a server per harness. This is exact, deterministic recall (`find kind=decision area=auth`) from a plain CLI. For fuzzy search use a vector store; most agent memory is "what's pending and what did we decide".
- **...git history?** Commits record what changed, not the decisions, findings, and open tasks around the change — and querying prose with `git log --grep` is archaeology, not recall. The store is untouched by branch switches; a `git worktree` gets its own store unless you [link it](docs/faq.md#does-the-store-follow-worktrees-fresh-clones-ci-or-cloud-agents).

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

<picture><source media="(max-width: 600px)" srcset="https://raw.githubusercontent.com/av/agent-store/master/assets/demo-hooks-phone.gif"><img src="https://raw.githubusercontent.com/av/agent-store/master/assets/demo-hooks.gif" alt="agent-store demo: link a finding to a task, add a hook on task updates that creates an event record, trigger it with set, then see the event in find and the link in links"></picture>

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

Every command supports `--json` for structured output, and record exports round-trip — `create --stdin` bulk-imports the same JSONL that `find --json | jq -c '.records[]'` emits (kinds and fields; imported records get new IDs and links are not carried):

```sh
$ agent-store find kind=task --json
{"records":[{"created_at":"2026-10-23T05:34:06.775Z","fields":{"status":"done","title":"ship v0.1"},"id":"4juoi3","kind":"task","updated_at":"2026-10-23T05:34:08.084Z"}]}
```

Scripting behaves the way a shell expects: results on stdout, errors on stderr, nonzero exit on failure (a `get` on a missing ID exits 1; an empty `find` still exits 0 with `{"records":[]}`). Envelope shapes, import validation, and the linked-store caveat: [JSON output and import](docs/json.md).

## Skills

`init` installs three agent-facing skill docs (`agent-store`, `agent-store-patterns`, `agent-store-pipelines`) into `.agents/skills/` and `.claude/skills/`, so coding agents pick up the store without prompting. They double as concise usage docs for humans. Details: [Skills and agent integration](docs/skills.md), [Claude Code, Codex and Cursor](docs/agents.md).

## Documentation

- [Install details](docs/install.md) — verification, completions, upgrade, uninstall
- [Claude Code, Codex and Cursor](docs/agents.md) — what `init` writes and which agent reads what
- [Claude Code tutorial](docs/claude-code.md) — setup, conventions, `SessionStart` hook, two-session example
- [Concepts](docs/concepts.md) — the mental model, with real examples
- [Query language](docs/queries.md) — operators, types, quoting, links, sorting
- [Hooks](docs/hooks.md) — events, variables, limits, runs
- [Schedules](docs/schedules.md) — one-shot and recurring commands, crontab
- [JSON output and import](docs/json.md) — `--json` shapes, `create --stdin`, recipes
- [Skills and agent integration](docs/skills.md) — what agents are taught
- [FAQ](docs/faq.md) — alternatives, data format, worktrees, concurrency, privacy, limits
- [Examples](examples/README.md) — seven runnable scripts

## Stability

agent-store is v0.1.x — early, but the data layer is the part treated as stable. The store is a plain SQLite file with a versioned, checksummed schema; upgrades apply migrations automatically on open, so existing records, links, and hook history survive new releases (covered by [tests that open old-schema stores](https://github.com/av/agent-store/blob/master/tests/upgrade.rs)). Pre-1.0, CLI flags, output wording, and `--json` shapes may still change between minor versions — pin a version if you script against exact output, and check the [CHANGELOG](CHANGELOG.md) before upgrading. Worst case, nothing is locked in: `.agent-store/store.sqlite` is a normal SQLite file with every record, link and hook run, and `find --json` exports the records as JSONL that `create --stdin` re-imports (without links, under new IDs).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup and workflow.

## License

[MIT](https://github.com/av/agent-store/blob/master/LICENSE). Third-party components bundled into release binaries (including SQLite) are listed in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
