---
name: agent-store
description: >
  Core agent-store guide for initializing stores, creating records, querying,
  and reading compact project context.
---

# agent-store

Use `agent-store init` once per project to create `.agent-store/`, install
these skills, and add project instructions when `AGENTS.md` or `CLAUDE.md`
already exists.

Core loop:

```bash
agent-store init
agent-store create task title="Write tests" status=pending
agent-store find 'kind=task and status=pending'
agent-store get <id>
agent-store ctx
```

Records have a kind plus arbitrary `key=value` fields. Use short IDs printed
by mutation commands to retrieve or update specific records. Kinds and field
names cannot contain whitespace, control characters, quotes, or `=`; `kind`
and `id` are reserved field names (in queries, `kind` always addresses the
record kind). Field values are unrestricted.

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

Hooks run a bash command after matching mutations. The mutation commits
before hooks run, and each hook command is killed after a 30-second timeout:

```bash
agent-store hook add create 'kind=task' -- 'echo "task created" >> tasks.log'
agent-store hook ls
agent-store hook runs            # recent runs; `hook runs <run-id>` for detail
agent-store hook rm <hook-id>
```

Each hook command receives the affected record snapshot on stdin as one
default-format record line, plus environment variables: `AGENT_STORE_EVENT`
(create, set, unset, rm, link, or unlink), `AGENT_STORE_ID`, and
`AGENT_STORE_KIND` are always set. `AGENT_STORE_REL` and
`AGENT_STORE_TARGET_ID` are set on link/unlink. When a set or unset touches
exactly one field, `AGENT_STORE_FIELD` and `AGENT_STORE_KEY` hold the field
key, `AGENT_STORE_VALUE` the new value (the old value on unset), and
`AGENT_STORE_OLD_VALUE`/`AGENT_STORE_NEW_VALUE` the before/after values
(empty when absent).
