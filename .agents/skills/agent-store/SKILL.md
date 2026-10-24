---
name: agent-store
description: >
  Project memory that persists across sessions, stored in this repo's
  .agent-store/. Use it whenever you are asked to remember, record, save or
  note something for future sessions (a decision, task, convention or
  finding), when you need to recall what earlier sessions decided or did, at
  session start or resume (run `agent-store ctx`), and when handing off work.
  Prefer it over writing notes into CLAUDE.md, AGENTS.md or your own memory
  files.
  Covers create, find, get, set, unset, rm, link, unlink, links, ctx, hooks
  and schedules.
---

# agent-store

agent-store is this project's memory across sessions: small records with a
kind and `key=value` fields, kept in `.agent-store/` and queried with
`agent-store find`. Anything a later session should know (decisions, open
tasks, conventions, findings, handoff notes) belongs here.

At session start or resume, read what earlier sessions recorded:

```bash
agent-store ctx
```

If it fails with `no agent-store found`, run `agent-store init` once (it
creates `.agent-store/`, installs these skills, and adds the instructions
block to `AGENTS.md` and `CLAUDE.md` when they exist), then continue.

Record a decision and find it again (see `agent-store-patterns` for the
field conventions):

```bash
agent-store create decision area=auth choice="session cookies" reason="no token refresh to manage"
agent-store find kind=decision area=auth
```

Core loop:

```bash
agent-store create task title="Write tests" status=pending   # prints the new ID
agent-store find 'kind=task and status=pending'
agent-store get <id>
agent-store set <id> status=done owner=me    # add or change fields
agent-store unset <id> owner                 # remove fields
agent-store rm <id>                          # delete the record
```

Links are directional, named edges between records:

```bash
agent-store link <from-id> implements <to-id>
agent-store links <id>                       # outgoing and incoming links
agent-store unlink <from-id> implements <to-id>
agent-store find 'link.out=implements'       # records with an outgoing implements link
```

Records have a kind plus arbitrary `key=value` fields. Use short IDs printed
by mutation commands to retrieve or update specific records; any unambiguous
prefix works. Kinds and field names cannot contain whitespace, control
characters, quotes, or `=`; `kind` and `id` are reserved field names (in
queries, `kind` always addresses the record kind). Field values are
unrestricted.

Queries join comparisons with `and`, `or`, `not`, and parentheses. Multiple
bare query arguments are joined with an implicit `and`, so
`find kind=task status=pending` means `find 'kind=task and status=pending'`.
Comparisons support `=`, `!=`, `<`, `<=`, `>`, `>=`, and `~=` (case-insensitive
substring match, e.g. `title~=login`) over the record kind and fields. Quote
comparison values that contain spaces (`title='Write tests'`, single or
double quotes; backslash escapes an embedded quote), use `field=''` to match
empty-string fields, and run bare `agent-store find` (or `ls`) to list every
record in creation order, oldest first.

Every record carries `created_at` and `updated_at` timestamps. `--json` output
of `get` and `find` includes them, `--timestamps` appends them to text output,
and queries can compare them like fields (`created_at>2026-01-01`) unless
shadowed by a field with the same name.

`find` and `ls` also take `--sort <field>` (a field name or the built-ins
`created_at`, `updated_at`, `kind`, `id`; records missing the field sort
last), `--desc` to reverse the order, `--limit <N>` to cap the output, and
`--count` to print only the number of matches:

```bash
agent-store find kind=task status=pending --sort created_at --desc --limit 5
agent-store find kind=task --count
```

`agent-store ctx` prints a compact project summary capped at 8192 bytes. It
ends with a Recent records section listing the 10 most recently updated
records with field values truncated, dropped oldest-first to fit the cap.

Hooks run a bash command after matching mutations. The query is optional:
omit it to run the hook on every mutation of that event (an empty-string
query is rejected). The mutation commits before hooks run, and each hook
command is killed after a 30-second timeout:

```bash
agent-store hook add create 'kind=task' -- 'echo "task created" >> tasks.log'
agent-store hook add set -- 'echo "record updated" >> audit.log'   # query optional
agent-store hook ls
agent-store hook runs            # recent runs; `hook runs <run-id>` for detail
agent-store hook rm <hook-id>
```

Each hook command receives the affected record snapshot on stdin as one
default-format record line, plus environment variables: `AGENT_STORE_EVENT`
(create, set, unset, rm, link, or unlink), `AGENT_STORE_ID`, and
`AGENT_STORE_KIND` are always set. `AGENT_STORE_REL` and
`AGENT_STORE_TARGET_ID` are set on link/unlink. When a set or unset touches
exactly one field, `AGENT_STORE_FIELD` holds the field key and
`AGENT_STORE_OLD_VALUE`/`AGENT_STORE_NEW_VALUE` the before/after values
(empty when absent); the older `AGENT_STORE_KEY` and `AGENT_STORE_VALUE` are
still set for existing hooks.

If a mutation prints its result and then exits 1 with `failed to run hooks
after Store mutation already committed`, the change was saved and only a
hook failed: do not retry it (a retried `create` makes a duplicate record).
Check `agent-store hook runs` and report the failing hook instead.

Schedules run bash commands on a time basis, complementing event-triggered
hooks. Two kinds: `at` fires once at an absolute timestamp, `every` fires
repeatedly at a duration interval. Commands use the same execution model as
hooks (bash -c, 30s timeout, process group management, stdin record, env
vars). An optional query scopes execution to matching records (one run per
match):

```bash
agent-store schedule add every 5m -- 'echo heartbeat'
agent-store schedule add at 2026-07-07T12:00:00Z -- 'cleanup.sh'
agent-store schedule add every 1h 'kind=task and status=pending' -- 'notify.sh'
agent-store schedule ls
agent-store schedule runs            # recent runs; `schedule runs <run-id>` for detail
agent-store schedule rm <id>
```

Schedules are daemon-less. `schedule tick` is the heartbeat command: it finds
all due schedules, atomically claims them (advances next_run_at or marks `at`
schedules completed), then runs their commands. Use `schedule enable` to
install a per-minute crontab entry that calls tick, and `schedule disable` to
remove it:

```bash
agent-store schedule enable      # installs cron entry
agent-store schedule disable     # removes cron entry
```

Duration expressions: `Ns` (seconds), `Nm` (minutes), `Nh` (hours), `Nd`
(days). Timestamps must be ISO 8601 with a `T` separator.
