# Concepts

agent-store is persistent, queryable memory for coding agents — one
SQLite file in your repo, addressed through one CLI. This page is the
mental model in one sitting: what a store is, what records, links, and
hooks are, how queries address them, and what `ctx` summarizes. Read it
after the README quickstart; for a hands-on workflow, see
[Using agent-store with Claude Code](claude-code.md).

Every output below is real, captured from a fresh store.

## The store

A store is **project-local**: one ordinary SQLite database at
`.agent-store/store.sqlite` in your project root, created by
`agent-store init` (which also gitignores it and installs the agent
[skills](skills.md)). There is no daemon, no global state, no
configuration file — delete `.agent-store/` and everything is gone.

Every command finds the store by walking up parent directories, so it
works from any subdirectory. Outside a project with a store, commands
fail loudly:

```
error: no agent-store found; run 'agent-store init' first
```

One project, one store. The store is working memory, not a committed
artifact — that's why `init` gitignores it. To move records between
stores, export and import JSONL (see [JSON output and import](json.md)).
Note that record JSON carries no links: moving a store this way keeps
every record but silently drops every edge, and imported records get
fresh IDs. Links must be recreated manually on the destination
(`links <id> --json` to read each edge, `link` to replay it against the
new IDs).

## Records

A record is a **kind** plus free-form **`key=value` fields**. That's the
whole data model — there is no schema to declare, no migration to run.
Kinds are just names you choose (`task`, `decision`, `note`, `finding`,
anything), and each kind's fields are whatever you set on its records:

```sh
$ agent-store create decision area=http choice=reqwest reason="no openssl dep"
z6wei1

$ agent-store create task title="Migrate HTTP client to reqwest" status=pending priority=2
krf5fg
```

`create` prints the new record's ID. IDs are short and
**prefix-resolvable**: any unambiguous prefix works wherever a command
takes an ID:

```sh
$ agent-store get kr
krf5fg task priority=2 status=pending title='Migrate HTTP client to reqwest'
```

Records mutate atomically with `set` (add or change fields) and `unset`
(remove them), and every record carries `created_at`/`updated_at`
timestamps maintained for you:

```sh
$ agent-store set kr status=in-progress
Updated krf5fg

$ agent-store get kr --timestamps
krf5fg task priority=2 status=in-progress title='Migrate HTTP client to reqwest' created_at=2026-10-23T02:36:10.097Z updated_at=2026-10-23T02:36:12.118Z
```

`unset` takes the names of the fields to remove. `rm` deletes the record
along with its fields and links (records on the other end of a link are
kept); after that, `get` fails and exits 1:

```sh
$ agent-store create note text="try ureq instead?" status=draft
swnpqx

$ agent-store unset swn status
Updated swnpqx

$ agent-store get swn
swnpqx note text='try ureq instead?'

$ agent-store rm swn
Removed swnpqx

$ agent-store get swnpqx
error: failed to get record: record 'swnpqx' was not found
```

Field values are stored as the text you typed, but they are **typed by
their shape** when compared: numbers compare numerically, dates and
timestamps on one timeline, everything else as text. Two names are
reserved — `kind` and `id` cannot be field names.

## Links

A link is a **directional, named edge** between two records:
`<from> <relation> <to>`. Relations are free-form names, like kinds:

```sh
$ agent-store link krf5fg implements z6wei1
Linked krf5fg implements z6wei1
```

Direction matters. Seen from each end:

```sh
$ agent-store links krf5fg
out implements z6wei1

$ agent-store links z6wei1
in implements krf5fg
```

`unlink` takes the same three arguments and removes that one edge, for
example a link made with the wrong relation:

```sh
$ agent-store link krf5fg blocks z6wei1
Linked krf5fg blocks z6wei1

$ agent-store unlink krf5fg blocks z6wei1
Unlinked krf5fg blocks z6wei1
```

Links let one record reference another without duplicating its fields —
a task *implements* a decision, a bug *blocks* a release, a finding
*supports* a conclusion. Queries can follow them via `link.out=<rel>`
and `link.in=<rel>`:

```sh
$ agent-store find 'link.in=implements'
z6wei1 decision area=http choice=reqwest reason='no openssl dep'
```

A record cannot link to itself — `link` rejects it with
`error: cannot link a record to itself (<id>)`. A self-edge would count
as both an incoming and an outgoing link of the same record and almost
always indicates a typo'd ID.

## Queries

`find` retrieves records with a small query language: comparisons over
`kind` and field values, joined by `and`, `or`, `not`, and parentheses.
The same language scopes hooks (below). The key ideas:

- **Comparisons**: `=`, `!=`, `<`, `<=`, `>`, `>=`, and `~=`
  (case-insensitive substring).
- **Typed**: `priority<2` compares numerically; `created_at>2026-01-01`
  compares on the timeline.
- **Missing fields never match** — a comparison on a field the record
  doesn't have is false, even for `!=`.
- Multiple bare arguments join with an implicit `and`.

```sh
$ agent-store find 'kind=task and status!=done' --sort priority
krf5fg task priority=2 status=in-progress title='Migrate HTTP client to reqwest'

$ agent-store find 'reason~=openssl'
z6wei1 decision area=http choice=reqwest reason='no openssl dep'

$ agent-store find kind=task --count
1
```

Output is one greppable line per record; add `--json` to any command for
structured output (see [JSON output and import](json.md)). The full
grammar — value types, quoting, sorting — is in
[Query language](queries.md).

## Hooks

An agent-store hook runs a **bash command after a matching store
mutation** — the store's own reactivity, useful for notifications,
mirroring state into files, or nudging an agent. (These are distinct
from Claude Code's lifecycle hooks; [the tutorial](claude-code.md) shows
how the two compose.)

A hook is an event (`create`, `set`, `unset`, `rm`, `link`, `unlink`)
plus an optional query scoping it to matching records:

```sh
$ agent-store hook add set kind=task -- 'echo "task $AGENT_STORE_ID $AGENT_STORE_FIELD: $AGENT_STORE_OLD_VALUE -> $AGENT_STORE_NEW_VALUE"'
wrzhpl

$ agent-store set kr status=done
Updated krf5fg
```

The mutation commits first; then the hook runs with the record on stdin
and `AGENT_STORE_*` environment variables describing what changed. Every
run is recorded and inspectable:

```sh
$ agent-store hook runs
1 2026-10-23T02:36:12.263Z hook=wrzhpl event=set record=krf5fg exit=0

$ agent-store hook runs 1
run: 1
created_at: 2026-10-23T02:36:12.263Z
hook: wrzhpl
event: set
record: krf5fg
exit_status: 0
stdout:
task krf5fg status: in-progress -> done

stderr:
```

Hooks are bounded: a 30-second timeout, and captured stdout/stderr
capped at 8192 bytes each. Full details — environment variables, Windows
caveats, security — in [Hooks](hooks.md). Their time-based sibling,
[schedules](schedules.md), runs commands at a moment (`at`) or on an
interval (`every`) with the same execution model and limits.

## Quick Context (`ctx`)

`ctx` is the store's answer to "get me oriented in one command": a
compact summary designed to be pasted into a prompt (or injected at
session start — see [the tutorial](claude-code.md)):

```sh
$ agent-store ctx
Quick Context
Records: 2
Record kinds:
  decision: 1
    fields: area, choice, reason
  task: 1
    fields: priority, status, title
    status: done=1
Links: 1
  implements: 1
Hooks: 1
Schedules: none
Latest activity: 2026-10-23T02:36:12.235Z
Recent records:
  krf5fg task priority=2 status=done title='Migrate HTTP client to reqwest'
  z6wei1 decision area=http choice=reqwest reason='no openssl dep'
```

It shows record counts by kind, each kind's field inventory (with value
breakdowns for low-cardinality fields like `status`), link, hook, and
schedule counts, and the most recently updated records.

The text output has a hard **8192-byte budget**. When the store outgrows
it, `ctx` drops the oldest recent-records lines first; if the summary is
still over budget with no recent-records lines left, it is hard-cut
(possibly mid-line) and ends with an explicit
`... truncated at 8192 bytes` notice, keeping the total within the
budget. Either way the summary stays prompt-sized no matter how large
the store gets. The cap applies to the text output only — `ctx --json`
always emits the complete, uncapped summary for machine consumers.
That's the intended division of labor: `ctx` for orientation, `find`
(or `ctx --json`) for anything specific the summary doesn't surface.

## How the pieces fit

The store is the container; records are the memory; links give records
structure without a schema; queries are how agents (and you) get exact,
deterministic recall; hooks (and schedules) make mutations and time
observable; and `ctx`
compresses the whole thing into a prompt-sized snapshot. An agent's loop
is typically: read `ctx`, `find` what's relevant, do the work, `create`
and `set` what was learned.

See also: [Using agent-store with Claude Code](claude-code.md) — the
worked end-to-end workflow; [Query language](queries.md) — the full
grammar; [Hooks](hooks.md) — events and environment in depth;
[FAQ](faq.md) — data format, concurrency, privacy, and limits.
