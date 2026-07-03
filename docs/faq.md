# FAQ

Honest answers to the questions people actually ask.

## Why not just a `TODO.md` / markdown notes?

Markdown works fine until you need to query it. agent-store gives you
structured records (`kind` + typed fields) that you can filter, sort, and
count: `find kind=task status=pending --sort created_at --limit 5` instead of
an agent re-reading and re-parsing a growing file on every turn. Records also
carry timestamps and links, and mutations can fire hooks — none of which a
flat file gives you.

If your project's memory needs are "a short list a human also edits," a
markdown file is genuinely the better tool. agent-store earns its keep when
records accumulate past what an agent should re-read wholesale, when several
kinds of memory coexist (tasks, decisions, findings, handoffs), or when you
want machine-checkable state instead of prose.

## Why not raw sqlite3 + jq?

You can — the store *is* SQLite, and you're welcome to open it (see below).
What the CLI adds on top:

- A query language agents reliably produce: `find "severity=high or priority<2"`
  instead of SQL over a normalized field table with five typed value columns.
- Typed comparisons (numbers sort as numbers, `1 < 2 < 10`; dates and
  timestamps compare on one timeline) without you writing the `CASE`
  expressions.
- Short human-friendly IDs with prefix resolution, links between records,
  hooks on mutations, and a `ctx` summary.
- Stable `--json` envelopes and JSONL import (`create --stdin`) so jq stays in
  the pipeline where it belongs.

## Why not a vector DB or a "memory MCP server"?

Different problem. agent-store is exact, structured recall — "what tasks are
pending," "what did we decide about auth" — not semantic similarity search.
There are no embeddings, no relevance ranking, and no LLM anywhere in the
binary. If you need "find notes vaguely about X," a vector store is the right
tool; here you'd query `kind=note area=auth` or `title~=auth` (substring,
case-insensitive) and get deterministic results.

Compared to an MCP memory server: agent-store is a plain CLI, so it works
with any agent that can run shell commands — no server process, no protocol
integration, no per-harness plugin. The trade-off is real: there's no push
notification to the agent and no semantic layer. Discovery happens through
installed skills and instruction blocks (see below), not tool schemas.

## Where is my data? Can I inspect it?

In `.agent-store/store.sqlite` at your project root — one ordinary SQLite
database file in WAL mode. It is yours:

```sh
sqlite3 .agent-store/store.sqlite '.tables'
# hook_runs  hooks  record_fields  record_links  records  schema_migrations  store_events
sqlite3 .agent-store/store.sqlite 'SELECT * FROM records LIMIT 5;'
```

The schema is straightforward: `records` (id, kind, timestamps),
`record_fields` (key, raw value, plus typed columns for text/number/
timestamp/boolean), `record_links`, `hooks`, `hook_runs`. Nothing is encoded
or compressed; field values are stored as the text you typed.

Greppable: the default output is one line per record (`id kind key=value ...`),
so `agent-store find | grep` works, and `find --json | jq` gives you the full
structure. For portability, export everything as JSONL with
`agent-store find --json | jq -c '.records[]'` and re-import into any store
with `create --stdin` (see [docs/json.md](json.md)).

`init` adds `.agent-store/` to your `.gitignore` by default — the store is
local working memory, not a committed artifact. Delete the directory and the
store is gone; there is no other state.

## How do agents actually discover and use it?

`agent-store init` does three things: creates `.agent-store/`, installs
skill files under both `.agents/skills/` and `.claude/skills/` (usage guide,
workflow patterns, shell pipelines), and appends a short marked instruction
block to `AGENTS.md`/`CLAUDE.md` telling agents to run `agent-store ctx` and
read the skills. Re-running `init` is safe and refreshes the installed files.

At session start, `agent-store ctx` prints a compact summary (kinds, field
inventory, recent records, last activity) capped at 8192 bytes, so an agent
gets oriented in one command instead of exploring. Any subdirectory works —
the CLI walks up parent directories to find `.agent-store/`.

There is no daemon and no MCP server; if your agent can run shell commands,
it can use the store. If it can't, agent-store won't work for you.

## What happens when multiple agents write at once?

It works, within SQLite's model. Concretely (see `src/store.rs`):

- The database runs in WAL mode, so readers never block on a writer.
- Writers serialize; a 5-second busy timeout plus bounded open-retry with
  backoff absorbs contention instead of erroring immediately.
- Mutations are single transactions; hooks run after commit and hook runs are
  persisted separately, so a slow or failing hook can't hold the write lock
  or roll back a committed mutation.

This is tested, not aspirational: `concurrency.facts` pins a suite of
concurrent-race facts (parallel mutations with hooks, readers during
mutation storms, hook add/rm churn, ID-prefix resolution races), each backed
by a runnable stress test. A quick sanity check — 20 parallel `create`
processes — completes with 20 records and zero errors.

Honest limits: writes are serialized, not parallel — this is one SQLite file,
not a database server. Sustained heavy write contention (many agents in tight
loops) will queue behind the 5s busy timeout, and a writer that waits longer
than that gets a busy error. There is no multi-writer merge, no networked
access, and no cross-machine sync; if two machines need the same store,
that's outside scope (export/import via JSONL is the workaround).

## Is my data sent anywhere?

No. There is no network code and no network-capable dependency. The complete
dependency list (`Cargo.toml`): `libc`, `rand`, `rusqlite` (with bundled
SQLite), `serde_json`. No HTTP client, no telemetry, no analytics, no phoning
home. Everything happens in one local file. The one caveat: hooks run
arbitrary shell commands *you* register, so a hook can do whatever the shell
can — including network calls. Nothing does so by default; `hook ls` shows
exactly what's registered.

## What are the limits? How fast is it?

There is no application-level cap on record count, field count, or value
size; the practical limits are SQLite's (a text value can be up to ~1 GB,
databases scale to terabytes). Two deliberate caps exist: `ctx` output is
truncated at 8192 bytes, and hook stdout/stderr capture is truncated at 8192
bytes per stream (hooks also have a 30-second timeout).

Ballpark on an ordinary dev machine (release build, warm cache): importing
1,000 records via `create --stdin` takes ~40 ms; `find` with a typed
comparison over those 1,000 records returns in under 10 ms; `ctx` is a few
milliseconds; the store file for ~1,000 small records is ~0.5 MB. Field
lookups are index-backed (per-type indexes on `record_fields`), so queries
stay fast well past the record counts an agent memory store realistically
sees (thousands to tens of thousands of records). It is not built or
benchmarked for millions of records — if that's your workload, use a real
database.

## Why Rust? Why a single binary?

Because the whole pitch is "works anywhere your agent has a shell":

- One static binary (~3.4 MB, SQLite bundled) — no Python environment, no
  Node runtime, no shared-library version roulette on the machines and
  containers agents actually run in.
- Startup is effectively free (single-digit milliseconds), which matters when
  an agent shells out dozens of times per session.
- `rusqlite` with the bundled feature compiles SQLite in, so behavior is
  identical across platforms and there's no system-SQLite version drift.

Rust specifically buys the static-linking story and the safety guarantees
for the concurrency handling above; there is no deeper ideology to it. If
you'd rather not run a prebuilt binary, `cargo build --release` from source
is the entire build process.

## See also

- [Using agent-store with Claude Code](claude-code.md)
- [Concepts](concepts.md)
- [Query language](queries.md)
- [Hooks](hooks.md)
- [JSON output and import](json.md)
- [Skills and agent integration](skills.md)
