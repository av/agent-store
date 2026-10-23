# Hooks

Hooks run a bash command after matching store mutations — notifications,
mirroring state into files, nudging an agent. The mutation commits before
its hooks run, so a hook always sees the store post-change.

Hook commands are always executed as `bash -c '<command>'`. On Linux and
macOS this just works. On Windows there is no builtin bash: hooks require
a `bash` on `PATH`, such as the one shipped with Git for Windows (Git
Bash) or WSL. Without one, the store mutation itself still commits, but
the hook fails to start and the command exits with an error. Two further
Windows caveats: on timeout only the `bash` process itself is killed
(child processes it spawned may survive; on unix the whole process group
is terminated), and hook runs report a plain exit code rather than unix
signal names.

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
58gj0c

$ agent-store hook ls
58gj0c create query='kind=task' -- 'echo "new task $AGENT_STORE_ID" >> tasks.log'
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
| `AGENT_STORE_HOOK_DEPTH` | always | hook nesting depth (`1` for a hook fired by a top-level command) |

Example — log field transitions:

```sh
agent-store hook add set kind=task -- 'echo "$AGENT_STORE_FIELD: $AGENT_STORE_OLD_VALUE -> $AGENT_STORE_NEW_VALUE"'
```

## Limits

- Each hook command is killed after a **30-second timeout**.
- Captured stdout and stderr are each capped at **8192 bytes**.
- Hook nesting is capped at a **depth of 3**. Every hook (and schedule)
  command runs with `AGENT_STORE_HOOK_DEPTH` set to its nesting depth
  (`1` for a hook fired by a top-level command). A mutation performed at
  depth 3 or deeper still commits, but skips hook dispatch and prints a
  note on stderr (which lands in the parent hook's captured output), so a
  hook that mutates records matched by its own query cannot recurse
  without bound.

## Hook failure

The mutation commits before hooks run, so a failing or timed-out hook
never undoes it. The triggering command still prints its normal stdout
output (the record ID, or the JSON envelope in `--json` mode), then
reports the hook failure on stderr and exits non-zero (`1`). Scripts that
capture stdout always get the ID; check the exit status and stderr to
detect hook failures.

## Inspecting runs

Every execution is recorded. `hook runs` lists recent runs newest first;
`hook runs <run-id>` shows one run's captured output. Here a task was
created and then set to `status=done`, with the `create` hook above and
the field-transition hook from the previous section:

```sh
$ agent-store hook runs
2 2026-10-23T05:40:12.484Z hook=89etcd event=set record=c29g8e exit=0
1 2026-10-23T05:40:12.448Z hook=58gj0c event=create record=c29g8e exit=0

$ agent-store hook runs 2
run: 2
created_at: 2026-10-23T05:40:12.484Z
hook: 89etcd
event: set
record: c29g8e
exit_status: 0
stdout:
status: pending -> done

stderr:
```

`--json hook runs` emits a `{"hook_runs":[...]}` array with `id`, `hook_id`,
`event`, `record_id`, `exit_status`, `stdout`, `stderr`, and `created_at`
per run.

## Security

Hook commands are arbitrary `bash -c` strings stored in
`.agent-store/store.sqlite` and executed automatically when mutations
match — anyone who can write to that file gets code execution when hooks
fire. `agent-store init` gitignores `.agent-store/`, but a cloned repo can
still ship a committed store. A coding agent working in that repo fires
its hooks as soon as it records something, without inspecting them, and
there is no trust prompt. After cloning an untrusted repo, inspect
`agent-store hook ls` and `agent-store schedule ls` (or delete
`.agent-store/`) before you or an agent run mutation commands. See
[SECURITY.md](../SECURITY.md).

See also: [Concepts](concepts.md) — where hooks fit in the overall
model; [Using agent-store with Claude Code](claude-code.md) — how
store hooks compose with Claude Code's own hook system; [FAQ](faq.md) —
data format, concurrency, privacy, and limits.
