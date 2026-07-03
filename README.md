<h1 align="center"><img src="assets/logo.svg" alt="agent-store" width="470"></h1>

![agent-store demo: init, create records, query with the find language, ctx summary](assets/demo.gif)

A project-local memory and context store for AI coding agents — records, links, hooks, and compact context via one CLI.

Coding agents lose state between sessions and burn context re-discovering the same facts. `agent-store` gives them a durable, queryable scratchpad that lives inside the repo: a SQLite-backed store of typed records, with directional links between them, shell hooks on mutations, and a byte-capped context summary designed to be pasted into a prompt. One static binary, no daemon, no configuration.

It is built for agents (Claude Code, Codex, and anything else that can run a CLI), but it's just as usable by humans as a terse project notebook: task tracker, decision log, handoff memory.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/av/agent-store/master/install.sh | sh
```

The installer detects your OS/arch, downloads the latest release binary, verifies its SHA-256 checksum, and installs to `~/.local/bin` (set `AGENT_STORE_INSTALL_DIR` to override, `AGENT_STORE_VERSION` to pin a tag).

Or build from source:

```sh
cargo install --git https://github.com/av/agent-store
```

Or download a prebuilt binary for Linux (x86_64 gnu/musl), macOS (x86_64/arm64), or Windows (x86_64) from [GitHub Releases](https://github.com/av/agent-store/releases) — each archive comes with a SHA-256 checksum. Linux/macOS assets are `.tar.gz`; the Windows asset is a `.zip`.

**Windows:** the install script is unix-only — download `agent-store-<tag>-x86_64-pc-windows-msvc.zip` from Releases, unzip, and put `agent-store.exe` on your `PATH` (or use `cargo install` above). The core CLI works natively; [hooks](docs/hooks.md) run their commands via `bash -c`, so hooks require a `bash` on `PATH` (Git Bash or WSL) — everything else works without one. The bundled shell completions and man page below are for unix shells.

### Shell completions and man page

Completion scripts for bash, zsh, and fish live in [`completions/`](completions/):

```sh
# bash
mkdir -p ~/.local/share/bash-completion/completions
cp completions/agent-store.bash ~/.local/share/bash-completion/completions/agent-store
# zsh (any directory on your $fpath works; this one usually needs sudo)
sudo cp completions/_agent-store /usr/share/zsh/site-functions/
# fish
mkdir -p ~/.config/fish/completions
cp completions/agent-store.fish ~/.config/fish/completions/
```

A man page ships in [`man/agent-store.1`](man/agent-store.1):

```sh
mkdir -p ~/.local/share/man/man1 && cp man/agent-store.1 ~/.local/share/man/man1/
man agent-store
```

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

$ agent-store create note text="prefer rustls over openssl"
x3arry

$ agent-store find kind=task status=pending
7f0owa task status=pending title='ship v0.1'

$ agent-store set 7f0owa status=done
Updated 7f0owa

$ agent-store ctx
Quick Context
Records: 2
Record kinds:
  note: 1
    fields: text
  task: 1
    fields: status, title
    status: done=1
Hooks: 0
Latest activity: 2026-07-03T09:16:49.612Z
Recent records:
  7f0owa task status=done title='ship v0.1'
  x3arry note text='prefer rustls over openssl'
```

`init` creates `.agent-store/` (and gitignores it), installs the builtin skills into `.agents/skills/` and `.claude/skills/`, and adds managed agent-store instructions to existing `AGENTS.md` and `CLAUDE.md` files — so agents in the project discover the store on their own.

Every record is a `kind` plus free-form `key=value` fields. IDs are short and prefix-resolvable: any unambiguous prefix works in `get`, `set`, `unset`, `rm`, `link`, and friends.

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
| `hook add/ls/rm/runs` | Manage shell hooks on store mutations |

Run `agent-store <command> --help` for full details on any of them.

## Documentation

- [Query language](docs/queries.md) — operators, value types, combinators, quoting, timestamps, links, sorting
- [Hooks](docs/hooks.md) — events, environment variables, limits, inspecting runs
- [JSON output and import](docs/json.md) — `--json` shapes, `create --stdin`, pipeline recipes
- [Skills and agent integration](docs/skills.md) — what `init` installs and the conventions agents pick up
- [FAQ](docs/faq.md) — why not markdown/jq/a vector DB, data format and inspection, concurrency, privacy, limits
- [Examples](examples/README.md) — runnable scripts: task tracker, decision log, session handoff, JSONL pipelines, audit hooks

## Query language

`find` and hook filters share a small query language:

```sh
agent-store find 'kind=task and (status=pending or status=blocked) and not owner=bot'
agent-store find 'title~=login'                # case-insensitive substring
agent-store find 'created_at>2026-01-01'       # built-in timestamps
agent-store find "note='hello world'"          # quoted values
agent-store find kind=task status=pending      # multiple args join with implicit and
```

- Comparisons: `=`, `!=`, `<`, `<=`, `>`, `>=`, and `~=` (substring) over `kind` and field values, plus `link.out`/`link.in` predicates.
- Combinators: `and`, `or`, `not`, parentheses; `and` binds tighter than `or`.
- `created_at` and `updated_at` compare like fields unless shadowed by a real field.
- Values may be single- or double-quoted; backslash escapes inside quotes; `''` matches the empty string.

## Hooks

Hooks run a bash command whenever matching records mutate — useful for notifications, mirroring state into files, or nudging an agent.

```sh
agent-store hook add set kind=task -- 'notify-send "task $AGENT_STORE_ID: $AGENT_STORE_NEW_VALUE"'
agent-store hook ls
agent-store hook runs            # recent runs, newest first
agent-store hook runs <RUN-ID>   # one run's captured stdout/stderr
```

- Events: `create`, `set`, `unset`, `rm`, `link`, `unlink`; an optional query scopes the hook to matching records.
- The command receives the affected record on stdin plus environment variables: `AGENT_STORE_EVENT`, `AGENT_STORE_ID`, `AGENT_STORE_KIND` (always), `AGENT_STORE_REL` and `AGENT_STORE_TARGET_ID` (link/unlink), and `AGENT_STORE_FIELD`/`AGENT_STORE_KEY`, `AGENT_STORE_VALUE`, `AGENT_STORE_OLD_VALUE`, `AGENT_STORE_NEW_VALUE` (set/unset of exactly one field).
- Commands are killed after 30 seconds; captured stdout and stderr are capped at 8192 bytes each.

## JSON output

Every command supports `--json` for structured output:

```sh
$ agent-store --json find kind=task
{"records":[{"created_at":"2026-07-03T09:16:49.608Z","fields":{"status":"done","title":"ship v0.1"},"id":"7f0owa","kind":"task","updated_at":"2026-07-03T09:16:49.612Z"}]}
```

Exports round-trip: `create --stdin` accepts JSONL of the same record shape `find --json` emits (extra keys like `id` and timestamps are ignored), validating every line before importing anything. This makes the store easy to pipe through `jq`, sync between projects, or seed from scripts.

## Skills

`init` installs three agent-facing skill docs so coding agents pick up the store without prompting:

- `agent-store` — core guide: initializing, creating, querying, reading context
- `agent-store-patterns` — workflow recipes: scratchpad, task tracker, decision log, handoff memory
- `agent-store-pipelines` — shell composition: importing, exporting, transforming records

They land in `.agents/skills/` and `.claude/skills/`, and are the deepest documentation in the repo — worth a read even for human use.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup and workflow.

## License

[MIT](LICENSE)
