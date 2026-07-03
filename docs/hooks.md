# Hooks

Hooks run a bash command after matching store mutations — notifications,
mirroring state into files, nudging an agent. The mutation commits before
its hooks run, so a hook always sees the store post-change.

## Managing hooks

```sh
agent-store hook add <event> [<query>] -- '<bash command>'
agent-store hook ls
agent-store hook rm <hook-id>
```

Events: `create`, `set`, `unset`, `rm`, `link`, `unlink`. The optional query
uses the [query language](queries.md) and scopes the hook to matching
records; without one, the hook fires on every event of that type.

```sh
$ agent-store hook add create kind=task -- 'echo "new task $AGENT_STORE_ID" >> tasks.log'
5xwtto

$ agent-store hook ls
5xwtto create query='kind=task' -- 'echo "new task $AGENT_STORE_ID" >> tasks.log'
```

## What the command receives

The affected record snapshot arrives on stdin as one default-format record
line, plus these environment variables:

| Variable | When | Value |
| --- | --- | --- |
| `AGENT_STORE_EVENT` | always | `create`, `set`, `unset`, `rm`, `link`, or `unlink` |
| `AGENT_STORE_ID` | always | affected record's ID |
| `AGENT_STORE_KIND` | always | affected record's kind |
| `AGENT_STORE_REL` | link/unlink | the link relation |
| `AGENT_STORE_TARGET_ID` | link/unlink | the link target record ID |
| `AGENT_STORE_FIELD` | set/unset of exactly one field | the field key |
| `AGENT_STORE_KEY` | set/unset of exactly one field | same as `AGENT_STORE_FIELD` |
| `AGENT_STORE_VALUE` | set/unset of exactly one field | the new value (the old value on unset) |
| `AGENT_STORE_OLD_VALUE` | set/unset of exactly one field | the previous value (empty when the field did not exist) |
| `AGENT_STORE_NEW_VALUE` | set/unset of exactly one field | the new value (empty on unset) |

Example — log field transitions:

```sh
agent-store hook add set kind=task -- 'echo "$AGENT_STORE_FIELD: $AGENT_STORE_OLD_VALUE -> $AGENT_STORE_NEW_VALUE"'
```

## Limits

- Each hook command is killed after a **30-second timeout**.
- Captured stdout and stderr are each capped at **8192 bytes**.

## Inspecting runs

Every execution is recorded. `hook runs` lists recent runs newest first;
`hook runs <run-id>` shows one run's captured output:

```sh
$ agent-store hook runs
2 2026-07-03T09:52:18.030Z hook=oxnpm7 event=set record=0zgjrb exit=0
1 2026-07-03T09:52:18.008Z hook=5xwtto event=create record=sc30ut exit=0

$ agent-store hook runs 2
run: 2
created_at: 2026-07-03T09:52:18.030Z
hook: oxnpm7
event: set
record: 0zgjrb
exit_status: 0
stdout:
status: pending -> done

stderr:
```

`--json hook runs` emits a `{"hook_runs":[...]}` array with `id`, `hook_id`,
`event`, `record_id`, `exit_status`, `stdout`, `stderr`, and `created_at`
per run.
