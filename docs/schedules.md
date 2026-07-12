# Schedules

Schedules run a bash command on a time basis — one-shot reminders,
recurring maintenance, periodic nudges — complementing event-triggered
[hooks](hooks.md). Commands use the same execution model as hooks
(`bash -c`, 30-second timeout, output capture, process-group cleanup on
unix), so the Windows caveats in [Hooks](hooks.md) apply to schedule
commands too.

Schedules are daemon-less: nothing runs in the background on its own.
`schedule tick` is the heartbeat command that finds and executes all due
schedules; run it manually, from your own cron/CI, or let
`schedule enable` install a per-minute crontab entry for you.

## Managing schedules

```sh
agent-store schedule add at <time> [<query>] -- '<bash command>'
agent-store schedule add every <interval> [<query>] -- '<bash command>'
agent-store schedule ls
agent-store schedule rm <schedule-id>
```

Two kinds:

- `at <time>` — a **one-shot** schedule. `<time>` is an absolute
  timestamp (`2026-07-10`, `2026-07-10T15:00:00Z` — ISO 8601 with a `T`
  separator; a date-only value means midnight UTC) or a relative
  duration (`5m`, `1h`, `2d`) meaning "from now".
- `every <interval>` — a **recurring** schedule. `<interval>` is a
  duration: `Ns`, `Nm`, `Nh`, or `Nd` (seconds, minutes, hours, days).
  The first run is due one interval after creation.

The optional query uses the [query language](queries.md) and scopes the
schedule to matching records, exactly like a hook query.

```sh
$ agent-store schedule add every 1h 'kind=task and status=open' -- 'echo "still open: $AGENT_STORE_ID"'
npqxhk

$ agent-store schedule add at 5m -- 'echo one-shot'
237gj1

$ agent-store schedule ls
237gj1 at 5m next=2026-07-12T13:35:40.759Z status=active -- 'echo one-shot'
npqxhk every 1h next=2026-07-12T14:30:40.760Z status=active query='kind=task and status=open' -- 'echo "still open: $AGENT_STORE_ID"'
```

`rm` accepts any unambiguous ID prefix, like record commands do.

!!! note "Past times are accepted"
    `at` does not reject a timestamp in the past — the schedule is
    created with `next_run_at` already due and fires on the very next
    tick. That includes a date-only value of *today* (midnight is
    already past). Double-check the year and time on one-shot
    reminders.

## Ticking

```sh
agent-store schedule tick
```

A schedule is due when its `next_run_at` is at or before the current
time. Tick claims all due schedules atomically before running their
commands, so it is idempotent and safe to call concurrently — two
overlapping ticks never run the same due schedule twice.

- **One-shot** (`at`) schedules fire once and are marked
  `status=completed`; they never fire again (remove with `schedule rm`
  when done with them).
- **Recurring** (`every`) schedules advance `next_run_at` by the
  interval **from the time the run happened**, not from the previously
  scheduled time. Under a per-minute cron tick this means recurring
  schedules drift by tick latency: an `every 1m` schedule fires roughly
  every one to two minutes, not on exact minute boundaries. Treat
  `every` as "at least this long between runs", not a precise clock.
- A **query-scoped** schedule whose query matches zero records at fire
  time still consumes its due slot (a one-shot is marked completed) but
  runs no command and records no run — there is no trace that it fired
  empty.

Tick prints one summary line per command run (nothing when nothing was
due):

```sh
$ agent-store schedule tick
2 2026-07-12T13:30:51.069Z schedule=psed0g record=zn1wjl exit=0
```

## Crontab integration

```sh
agent-store schedule enable      # install the crontab entry
agent-store schedule disable     # remove it
```

`enable` installs a system crontab entry that runs
`agent-store schedule tick` every minute for this project. The entry is
preceded by a marker comment (`# agent-store:tick:<project-root>`) and
scoped to the project root directory, so multiple projects keep
independent entries and `disable` removes only its own two lines,
preserving the rest of your crontab. `enable` is idempotent — running it
twice does not duplicate the entry. It records the absolute path of the
current `agent-store` binary, so re-run `enable` after moving the
binary.

`disable` removes the entry but keeps the schedules themselves; with no
entry installed it prints `No crontab entry found for this project` and
exits 0.

Requires a working `crontab` on `PATH` (standard on Linux and macOS; no
special permissions needed). There is no crontab integration on
Windows — run `schedule tick` from Task Scheduler or another timer
instead.

## What the command receives

Without a query, the command runs once per fire with empty stdin. With a
query, the command runs **once per matching record**, receiving the
record snapshot on stdin as one default-format record line. Environment
variables:

| Variable | When | Value |
| --- | --- | --- |
| `AGENT_STORE_SCHEDULE_ID` | always | the schedule's ID |
| `AGENT_STORE_EVENT` | query-scoped runs | `tick` |
| `AGENT_STORE_ID` | query-scoped runs | matched record's ID |
| `AGENT_STORE_KIND` | query-scoped runs | matched record's kind |
| `AGENT_STORE_HOOK_DEPTH` | always | nesting depth (`1` for a top-level tick) |

## Limits

- Each schedule command is killed after a **30-second timeout** (the run
  records exit status `-1` and a `timed out after 30 seconds` note on
  stderr; partial output is kept).
- Captured stdout and stderr are each capped at **8192 bytes**. Output
  beyond the cap is dropped without a truncation marker — exactly
  8192 bytes of capture means the output may have been longer.
- Schedule commands share the hook **recursion-depth cap of 3**: a
  schedule command runs with `AGENT_STORE_HOOK_DEPTH=1`, so hooks fired
  by mutations it makes run at depth 2, and mutations at depth 3 or
  deeper commit but skip hook dispatch (see [Hooks](hooks.md#limits)).

## Inspecting runs

Every command execution is recorded. `schedule runs` lists recent runs
newest first (20 by default, `--limit <N>` to override);
`schedule runs <run-id>` shows one run's captured output:

```sh
$ agent-store schedule runs
2 2026-07-12T13:30:51.069Z schedule=psed0g record=zn1wjl exit=0
1 2026-07-12T13:30:40.783Z schedule=u8clmz exit=0

$ agent-store schedule runs 2
run: 2
created_at: 2026-07-12T13:30:51.069Z
schedule: psed0g
record: zn1wjl
exit_status: 0
stdout:
still open: zn1wjl

stderr:
```

`--json schedule ls` emits `{"schedules":[...]}` with `id`, `kind`,
`expression`, `interval_seconds`, `query`, `command`, `next_run_at`,
`status`, and `created_at`; `--json schedule runs` emits
`{"schedule_runs":[...]}` with `id`, `schedule_id`, `record_id`,
`exit_status`, `stdout`, `stderr`, and `created_at` per run. `ctx` shows
a `Schedules:` line with active/completed counts and the next run time.

## Security

Like hooks, schedule commands are arbitrary `bash -c` strings stored in
`.agent-store/store.sqlite` and executed by `schedule tick`. After
cloning an untrusted repo that ships a committed store, inspect
`agent-store schedule ls` (and `hook ls`) before running tick or
enabling the crontab entry. See [SECURITY.md](../SECURITY.md).

See also: [Hooks](hooks.md) — the shared execution model in depth;
[Query language](queries.md) — the full grammar for scoping queries;
[JSON output and import](json.md) — envelope shapes.
