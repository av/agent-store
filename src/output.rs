use crate::cli::HelpTopic;
use agent_store::store::{
    Hook, HookRun, Link, LinkEdge, QuickContextSummary, Record, Schedule, ScheduleRun,
    ScheduleSummary,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub const QUICK_CONTEXT_OUTPUT_LIMIT_BYTES: usize = 8192;

const QUICK_CONTEXT_FIELD_VALUE_LIMIT_CHARS: usize = 100;
const QUICK_CONTEXT_FIELD_VALUE_ELLIPSIS: &str = "...";

pub const USAGE: &str = "\
Usage: agent-store [OPTIONS] <COMMAND>

A project-local store for agent-facing records, links, hooks, and context.

Options:
  -h, --help    Print help
  -V, --version Print version
      --json    Print structured JSON for command output

Commands:
  init          Initialize a project-local store
  create, cr    Create a record
  find, ls      Find records by query
  get           Print a record by ID
  set           Update fields on a record by ID
  unset         Remove fields from a record by ID
  rm            Delete a record by ID
  link          Create a directional link between records
  unlink        Remove a directional link between records
  links         Print incoming and outgoing links for a record
  ctx, context  Print a compact Quick Context summary
  hook          Manage stored hooks
  schedule      Manage time-based schedules

Quick Context output is capped at 8192 bytes.
Hook and schedule stdout and stderr captures are capped at 8192 bytes each.
";

const INIT_USAGE: &str = "\
Usage: agent-store init

Initialize the project-local store, install builtin skills, and add managed
agent-store instructions to existing AGENTS.md and CLAUDE.md files.
";

const CREATE_USAGE: &str = "\
Usage: agent-store create <kind> [key=value...]
       agent-store cr <kind> [key=value...]
       agent-store create --stdin
       agent-store cr --stdin

Create a Record with the supplied kind and fields, then print its Record ID.

Kinds and field names cannot contain whitespace, control characters, quotes,
or '='; 'kind' and 'id' are reserved field names, and 'not' is reserved as a
kind and field name. Field values are unrestricted.

Options:
  --stdin  Bulk-import JSONL from stdin instead of argv: one JSON object per
           line of the shape {\"kind\": \"...\", \"fields\": {\"k\": \"v\"}},
           the same record shape find --json emits. Extra keys (id,
           created_at, updated_at) are ignored so exports round-trip, and
           number, boolean, and null field values are stored as their raw
           text just like argv key=value input. Empty lines are skipped.
           One Record is created per line and its ID printed per line in
           input order (--json prints a records array instead); Hooks fire
           per created Record. Every line is validated before any Record is
           created, so an invalid line (bad JSON, missing or invalid kind,
           invalid field name) exits non-zero naming the line number with
           nothing imported. --stdin cannot be combined with positional
           kind or key=value arguments.
";

const GET_USAGE: &str = "\
Usage: agent-store get [--timestamps] <ID>

Print one Record resolved from an unambiguous Record ID prefix.

Options:
  --timestamps  Append created_at=... and updated_at=... to the record line
";

const FIND_USAGE: &str = "\
Usage: agent-store find [--timestamps] [--sort <field>] [--desc] [--limit <N>] [--count] [<Query>]
       agent-store ls [--timestamps] [--sort <field>] [--desc] [--limit <N>] [--count] [<Query>]

Find Records by query. A Query may be quoted as one shell argument or passed
as multiple arguments: multiple arguments are joined with an implicit and
when needed, so `find kind=task status=pending` means
`find 'kind=task and status=pending'`, while unquoted queries that already
spell out and/or/not keep their meaning. Without a Query, every Record is
listed in creation order, oldest first.

Options:
  --timestamps    Append created_at=... and updated_at=... to each record line
  --sort <field>  Sort by a Field name or the built-ins created_at,
                  updated_at, kind, or id; Records missing the field sort last
  --desc          Reverse the listing order
  --limit <N>     Output at most N records
  --count         Print only the number of matching records

Queries combine comparisons with and, or, not, and parentheses; and binds
tighter than or. Comparisons support =, !=, <, <=, >, and >= over kind and
Field values, plus link.out/link.in predicates. The ~= operator matches when
the value is a case-insensitive substring of kind or a Field value, for
example title~=login. The built-in created_at and
updated_at record timestamps compare like Fields (for example
created_at>2026-01-01), unless shadowed by a Field with the same name.

Comparison values may be single- or double-quoted to include spaces or
operator characters, for example note='hello world'. Inside quotes, a
backslash escapes the next character (\\' \\\" \\\\), and '' matches Fields
stored as the empty string.

In queries, kind always addresses the Record kind: 'kind' and 'id' are
reserved and can never be Field names.
";

const SET_USAGE: &str = "\
Usage: agent-store set <ID> key=value...

Resolve a Record ID prefix and update the supplied fields atomically.

Field names cannot contain whitespace, control characters, quotes, or '=';
'kind', 'id', and 'not' are reserved field names. Field values are
unrestricted.
";

const UNSET_USAGE: &str = "\
Usage: agent-store unset <ID> key...

Resolve a Record ID prefix and remove the supplied fields atomically.
";

const RM_USAGE: &str = "\
Usage: agent-store rm <ID>

Resolve a Record ID prefix and delete that Record.
";

const LINK_USAGE: &str = "\
Usage: agent-store link <from> <rel> <to>

Resolve source and target Record ID prefixes and create one directional Link.
";

const UNLINK_USAGE: &str = "\
Usage: agent-store unlink <from> <rel> <to>

Resolve source and target Record ID prefixes and remove one directional Link.
";

const LINKS_USAGE: &str = "\
Usage: agent-store links <ID>

Resolve a Record ID prefix and print its outgoing and incoming Links.
";

const CONTEXT_USAGE: &str = "\
Usage: agent-store ctx
       agent-store context

Print a compact Quick Context summary capped at 8192 bytes.

The summary ends with a Recent records section listing the 10 most recently
updated Records with field values truncated to 100 characters; recent-record
lines are dropped oldest-first to stay within the byte cap.
";

const HOOK_USAGE: &str = "\
Usage: agent-store hook <COMMAND>

Manage stored hooks. Hook bash commands are killed after a 30-second timeout.

Commands:
  add           Add a Hook
  ls            List Hooks
  rm            Remove a Hook by ID
  runs          List recent Hook Runs or show one run's captured output

Each Hook command receives the affected Record snapshot on stdin as one
default-format Record line, plus these environment variables:

  AGENT_STORE_EVENT      always: the event (create, set, unset, rm, link, unlink)
  AGENT_STORE_ID         always: the affected Record's ID
  AGENT_STORE_KIND       always: the affected Record's kind
  AGENT_STORE_REL        link and unlink only: the Link relation
  AGENT_STORE_TARGET_ID  link and unlink only: the Link target Record ID
  AGENT_STORE_FIELD      set/unset of exactly one field: the field key
  AGENT_STORE_KEY        set/unset of exactly one field: same as AGENT_STORE_FIELD
  AGENT_STORE_VALUE      set/unset of exactly one field: the new value (the old
                         value on unset)
  AGENT_STORE_OLD_VALUE  set/unset of exactly one field: the previous value
                         (empty when the field did not exist)
  AGENT_STORE_NEW_VALUE  set/unset of exactly one field: the new value (empty
                         on unset)
";

const HOOK_ADD_USAGE: &str = "\
Usage: agent-store hook add <event> [<Query>] -- <bash command>

Store a Hook for create, set, unset, rm, link, or unlink. When a Query is
provided, the Hook runs only for matching Records.

Hook bash commands are killed after a 30-second timeout. Each Hook command
receives the affected Record snapshot on stdin as one default-format Record
line, plus AGENT_STORE_EVENT, AGENT_STORE_ID, and AGENT_STORE_KIND (always),
AGENT_STORE_REL and AGENT_STORE_TARGET_ID (link/unlink), and AGENT_STORE_FIELD,
AGENT_STORE_KEY, AGENT_STORE_VALUE, AGENT_STORE_OLD_VALUE, and
AGENT_STORE_NEW_VALUE (set/unset of exactly one field). See
`agent-store hook --help` for details.
";

const HOOK_LIST_USAGE: &str = "\
Usage: agent-store hook ls

Print stored Hooks in deterministic order.
";

const HOOK_REMOVE_USAGE: &str = "\
Usage: agent-store hook rm <ID>

Resolve a Hook ID prefix and remove that Hook.
";

const HOOK_RUNS_USAGE: &str = "\
Usage: agent-store hook runs [--limit <N>]
       agent-store hook runs <RUN-ID>

List recent Hook Runs newest first, one summary line per run (20 by default,
override with --limit). Pass a run ID to print that run's full detail,
including captured stdout and stderr. Captures are capped at 8192 bytes each;
negative exit status means the Hook was killed by a signal or timed out.
";

const SCHEDULE_USAGE: &str = "\
Usage: agent-store schedule <COMMAND>

Manage time-based schedules. Schedule commands are killed after a 30-second
timeout, using the same execution model as hooks.

Commands:
  add           Add a schedule (at or every)
  ls            List schedules
  rm            Remove a schedule by ID
  runs          List recent schedule runs or show one run's detail
  tick          Execute all due schedules
  enable        Install a system crontab entry to run tick automatically
  disable       Remove the system crontab entry

Use `schedule tick` manually, via cron, or via `schedule enable` which
installs a crontab entry that runs tick every minute.
";

const SCHEDULE_ADD_USAGE: &str = "\
Usage: agent-store schedule add at <time> [<Query>] -- <bash command>
       agent-store schedule add every <interval> [<Query>] -- <bash command>

Add a time-based schedule.

  at <time>       One-shot schedule. <time> is an absolute timestamp
                  (2026-07-10, 2026-07-10T15:00:00Z) or a relative duration
                  (5m, 1h, 2d) meaning \"from now\".
  every <interval> Recurring schedule. <interval> is a duration: Ns, Nm, Nh,
                  or Nd (seconds, minutes, hours, days).

The optional Query scopes the schedule to matching records: when the schedule
fires, the command runs once per matching record with the record on stdin and
AGENT_STORE_ID, AGENT_STORE_KIND in the environment. Without a query, the
command runs once with no record context.
";

const SCHEDULE_LIST_USAGE: &str = "\
Usage: agent-store schedule ls

Print stored schedules in creation order.
";

const SCHEDULE_REMOVE_USAGE: &str = "\
Usage: agent-store schedule rm <ID>

Resolve a schedule ID prefix and remove that schedule.
";

const SCHEDULE_RUNS_USAGE: &str = "\
Usage: agent-store schedule runs [--limit <N>]
       agent-store schedule runs <RUN-ID>

List recent schedule runs newest first, one summary line per run (20 by
default, override with --limit). Pass a run ID to print that run's full
detail, including captured stdout and stderr.
";

const SCHEDULE_TICK_USAGE: &str = "\
Usage: agent-store schedule tick

Find and execute all due schedules. A schedule is due when its next_run_at
timestamp is at or before the current time.

For one-shot (at) schedules, the status is set to completed after firing.
For recurring (every) schedules, next_run_at advances by the interval.

Tick is idempotent and safe to call concurrently: due schedules are claimed
atomically before their commands run.
";

const SCHEDULE_ENABLE_USAGE: &str = "\
Usage: agent-store schedule enable

Install a system crontab entry that runs `agent-store schedule tick` every
minute for this project. The entry is scoped to the project root directory
so multiple projects can have independent schedules.

Requires `crontab` to be available. On macOS and Linux, no special
permissions are needed.
";

const SCHEDULE_DISABLE_USAGE: &str = "\
Usage: agent-store schedule disable

Remove the system crontab entry for this project, installed by
`schedule enable`. The schedules themselves are not removed; use
`schedule rm` to delete individual schedules.
";

pub fn help_text(topic: HelpTopic) -> &'static str {
    match topic {
        HelpTopic::Top => USAGE,
        HelpTopic::Init => INIT_USAGE,
        HelpTopic::Create => CREATE_USAGE,
        HelpTopic::Get => GET_USAGE,
        HelpTopic::Find => FIND_USAGE,
        HelpTopic::Set => SET_USAGE,
        HelpTopic::Unset => UNSET_USAGE,
        HelpTopic::Rm => RM_USAGE,
        HelpTopic::Link => LINK_USAGE,
        HelpTopic::Unlink => UNLINK_USAGE,
        HelpTopic::Links => LINKS_USAGE,
        HelpTopic::Context => CONTEXT_USAGE,
        HelpTopic::Hook => HOOK_USAGE,
        HelpTopic::HookAdd => HOOK_ADD_USAGE,
        HelpTopic::HookList => HOOK_LIST_USAGE,
        HelpTopic::HookRemove => HOOK_REMOVE_USAGE,
        HelpTopic::HookRuns => HOOK_RUNS_USAGE,
        HelpTopic::Schedule => SCHEDULE_USAGE,
        HelpTopic::ScheduleAdd => SCHEDULE_ADD_USAGE,
        HelpTopic::ScheduleList => SCHEDULE_LIST_USAGE,
        HelpTopic::ScheduleRemove => SCHEDULE_REMOVE_USAGE,
        HelpTopic::ScheduleRuns => SCHEDULE_RUNS_USAGE,
        HelpTopic::ScheduleTick => SCHEDULE_TICK_USAGE,
        HelpTopic::ScheduleEnable => SCHEDULE_ENABLE_USAGE,
        HelpTopic::ScheduleDisable => SCHEDULE_DISABLE_USAGE,
    }
}

pub fn print_json(value: Value) {
    outln!("{value}");
}

pub fn init_json(
    already_initialized: bool,
    skills_installed: &[String],
    instructions: &[(&str, &str)],
) -> Value {
    json!({
        "status": if already_initialized { "already-initialized" } else { "initialized" },
        "store_dir": agent_store::store::STORE_DIR,
        "skills_installed": skills_installed,
        "instructions": instructions
            .iter()
            .map(|(path, status)| json!({ "path": path, "status": status }))
            .collect::<Vec<_>>(),
    })
}

/// Envelope for runtime errors in `--json` mode: `{"error":"<message>"}`.
/// Printed to stderr so stdout stays data-only in both output modes.
pub fn error_json(message: &str) -> Value {
    json!({ "error": message })
}

pub fn count_json(count: usize) -> Value {
    json!({ "count": count })
}

pub fn single_record_json(record: &Record) -> Value {
    json!({
        "record": record_json(record),
    })
}

pub fn records_json(records: &[Record]) -> Value {
    json!({
        "records": records.iter().map(record_json).collect::<Vec<_>>(),
    })
}

pub fn mutation_json(status: &str, record: &Record) -> Value {
    json!({
        "status": status,
        "record": record_json(record),
    })
}

pub fn link_mutation_json(status: &str, link: &Link) -> Value {
    json!({
        "status": status,
        "link": link_json(link),
    })
}

pub fn hook_mutation_json(status: &str, hook: &Hook) -> Value {
    json!({
        "status": status,
        "hook": hook_json(hook),
    })
}

pub fn hooks_json(hooks: &[Hook]) -> Value {
    json!({
        "hooks": hooks.iter().map(hook_json).collect::<Vec<_>>(),
    })
}

pub fn hook_runs_json(runs: &[HookRun]) -> Value {
    json!({
        "hook_runs": runs.iter().map(hook_run_json).collect::<Vec<_>>(),
    })
}

pub fn single_hook_run_json(run: &HookRun) -> Value {
    json!({
        "hook_run": hook_run_json(run),
    })
}

fn hook_run_json(run: &HookRun) -> Value {
    json!({
        "id": run.id,
        "hook_id": &run.hook_id,
        "event": &run.event_type,
        "record_id": &run.record_id,
        "exit_status": run.exit_status,
        "stdout": &run.stdout_summary,
        "stderr": &run.stderr_summary,
        "created_at": &run.created_at,
    })
}

pub fn format_hook_run_summary(run: &HookRun) -> String {
    format!(
        "{} {} hook={} event={} record={} exit={}",
        run.id, run.created_at, run.hook_id, run.event_type, run.record_id, run.exit_status
    )
}

pub fn format_hook_run_detail(run: &HookRun) -> String {
    format!(
        "run: {}\ncreated_at: {}\nhook: {}\nevent: {}\nrecord: {}\nexit_status: {}\nstdout:\n{}\nstderr:\n{}",
        run.id,
        run.created_at,
        run.hook_id,
        run.event_type,
        run.record_id,
        run.exit_status,
        run.stdout_summary,
        run.stderr_summary
    )
}

pub fn quick_context_json(summary: &QuickContextSummary) -> Value {
    // Include as many recent records as fit within the output byte cap,
    // dropping the least recently updated entries first.
    for keep in (0..=summary.recent_records.len()).rev() {
        let value = quick_context_json_with_recent(summary, keep);
        if keep == 0 || value.to_string().len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES {
            return value;
        }
    }
    unreachable!("the keep == 0 iteration always returns")
}

fn quick_context_json_with_recent(summary: &QuickContextSummary, keep: usize) -> Value {
    json!({
        "record_count": summary.record_count,
        "records_by_kind": &summary.records_by_kind,
        "fields_by_kind": &summary.fields_by_kind,
        "status_counts_by_kind": &summary.status_counts_by_kind,
        "date_windows_by_kind": summary
            .date_windows_by_kind
            .iter()
            .map(|(kind, windows)| {
                (
                    kind.clone(),
                    windows
                        .iter()
                        .map(|(field, window)| {
                            (
                                field.clone(),
                                json!({
                                    "earliest": &window.earliest,
                                    "latest": &window.latest,
                                }),
                            )
                        })
                        .collect::<BTreeMap<_, _>>(),
                )
            })
            .collect::<BTreeMap<_, _>>(),
        "link_count": summary.link_count,
        "links_by_relation": &summary.links_by_relation,
        "hook_count": summary.hook_count,
        "schedule_summary": schedule_summary_json(&summary.schedule_summary),
        "latest_activity_at": &summary.latest_activity_at,
        "recent_records": summary.recent_records[..keep]
            .iter()
            .map(recent_record_json)
            .collect::<Vec<_>>(),
    })
}

fn recent_record_json(record: &Record) -> Value {
    json!({
        "id": &record.id,
        "kind": &record.kind,
        "fields": record
            .fields
            .iter()
            .map(|(key, value)| (key.clone(), truncate_field_value(value)))
            .collect::<BTreeMap<_, _>>(),
    })
}

fn truncate_field_value(value: &str) -> String {
    if value.chars().count() <= QUICK_CONTEXT_FIELD_VALUE_LIMIT_CHARS {
        return value.to_owned();
    }

    let mut truncated: String = value
        .chars()
        .take(QUICK_CONTEXT_FIELD_VALUE_LIMIT_CHARS)
        .collect();
    truncated.push_str(QUICK_CONTEXT_FIELD_VALUE_ELLIPSIS);
    truncated
}

fn format_recent_record(record: &Record) -> String {
    let mut output = format!("{} {}", record.id, record.kind);
    for (key, value) in &record.fields {
        output.push(' ');
        output.push_str(key);
        output.push('=');
        output.push_str(&shell_quote_value(&truncate_field_value(value)));
    }
    output
}

pub fn schedule_mutation_json(status: &str, schedule: &Schedule) -> Value {
    json!({
        "status": status,
        "schedule": schedule_json(schedule),
    })
}

pub fn schedules_json(schedules: &[Schedule]) -> Value {
    json!({
        "schedules": schedules.iter().map(schedule_json).collect::<Vec<_>>(),
    })
}

pub fn schedule_runs_json(runs: &[ScheduleRun]) -> Value {
    json!({
        "schedule_runs": runs.iter().map(schedule_run_json).collect::<Vec<_>>(),
    })
}

pub fn single_schedule_run_json(run: &ScheduleRun) -> Value {
    json!({
        "schedule_run": schedule_run_json(run),
    })
}

pub fn tick_json(runs: &[ScheduleRun]) -> Value {
    json!({
        "ticked": runs.len(),
        "schedule_runs": runs.iter().map(schedule_run_json).collect::<Vec<_>>(),
    })
}

fn schedule_json(schedule: &Schedule) -> Value {
    json!({
        "id": &schedule.id,
        "kind": schedule.kind.as_str(),
        "expression": &schedule.expression,
        "interval_seconds": schedule.interval_seconds,
        "query": &schedule.query,
        "command": &schedule.command,
        "next_run_at": &schedule.next_run_at,
        "status": schedule.status.as_str(),
        "created_at": &schedule.created_at,
    })
}

fn schedule_run_json(run: &ScheduleRun) -> Value {
    json!({
        "id": run.id,
        "schedule_id": &run.schedule_id,
        "record_id": &run.record_id,
        "exit_status": run.exit_status,
        "stdout": &run.stdout_summary,
        "stderr": &run.stderr_summary,
        "created_at": &run.created_at,
    })
}

pub fn format_schedule(schedule: &Schedule) -> String {
    let mut output = format!(
        "{} {} {} next={}",
        schedule.id,
        schedule.kind.as_str(),
        schedule.expression,
        schedule.next_run_at
    );
    output.push_str(&format!(" status={}", schedule.status.as_str()));
    if let Some(query) = &schedule.query {
        output.push_str(" query=");
        output.push_str(&shell_quote_value(query));
    }
    output.push_str(" -- ");
    output.push_str(&shell_quote_value(&schedule.command));
    output
}

pub fn format_schedule_run_summary(run: &ScheduleRun) -> String {
    let record_part = match &run.record_id {
        Some(id) => format!(" record={id}"),
        None => String::new(),
    };
    format!(
        "{} {} schedule={}{} exit={}",
        run.id, run.created_at, run.schedule_id, record_part, run.exit_status
    )
}

pub fn format_schedule_run_detail(run: &ScheduleRun) -> String {
    let record_line = match &run.record_id {
        Some(id) => format!("\nrecord: {id}"),
        None => String::new(),
    };
    format!(
        "run: {}\ncreated_at: {}\nschedule: {}{}\nexit_status: {}\nstdout:\n{}\nstderr:\n{}",
        run.id,
        run.created_at,
        run.schedule_id,
        record_line,
        run.exit_status,
        run.stdout_summary,
        run.stderr_summary
    )
}

pub fn schedule_summary_json(summary: &ScheduleSummary) -> Value {
    json!({
        "status": if summary.active_count > 0 { "enabled" } else { "disabled" },
        "active_schedules": summary.active_count,
        "completed_schedules": summary.completed_count,
        "next_run_at": summary.next_run_at,
    })
}

pub fn record_links_json(record_id: &str, links: &[LinkEdge]) -> Value {
    json!({
        "record_id": record_id,
        "links": links.iter().map(link_edge_json).collect::<Vec<_>>(),
    })
}

fn record_json(record: &Record) -> Value {
    json!({
        "id": &record.id,
        "kind": &record.kind,
        "created_at": &record.created_at,
        "updated_at": &record.updated_at,
        "fields": &record.fields,
    })
}

fn hook_json(hook: &Hook) -> Value {
    json!({
        "id": &hook.id,
        "event": &hook.event,
        "query": &hook.query,
        "command": &hook.command,
    })
}

fn link_json(link: &Link) -> Value {
    json!({
        "from_record_id": &link.from_record_id,
        "rel": &link.rel,
        "to_record_id": &link.to_record_id,
    })
}

fn link_edge_json(link: &LinkEdge) -> Value {
    json!({
        "direction": link.direction.as_str(),
        "rel": &link.rel,
        "record_id": &link.peer_record_id,
    })
}

pub fn format_hook(hook: &Hook) -> String {
    let mut output = format!("{} {}", hook.id, hook.event);
    if let Some(query) = &hook.query {
        output.push_str(" query=");
        output.push_str(&shell_quote_value(query));
    }
    output.push_str(" -- ");
    output.push_str(&shell_quote_value(&hook.command));
    output
}

pub fn format_record(record: &Record) -> String {
    let mut output = format!("{} {}", record.id, record.kind);
    for (key, value) in &record.fields {
        output.push(' ');
        output.push_str(key);
        output.push('=');
        output.push_str(&shell_quote_value(value));
    }
    output
}

pub fn format_record_with_timestamps(record: &Record) -> String {
    let mut output = format_record(record);
    output.push_str(" created_at=");
    output.push_str(&shell_quote_value(&record.created_at));
    output.push_str(" updated_at=");
    output.push_str(&shell_quote_value(&record.updated_at));
    output
}

pub fn format_quick_context(summary: &QuickContextSummary) -> String {
    let mut lines = vec![
        "Quick Context".to_owned(),
        format!("Records: {}", summary.record_count),
    ];

    if summary.records_by_kind.is_empty() {
        lines.push("Record kinds: none".to_owned());
    } else {
        lines.push("Record kinds:".to_owned());
        for (kind, count) in &summary.records_by_kind {
            lines.push(format!("  {kind}: {count}"));
            let fields = summary
                .fields_by_kind
                .get(kind)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if fields.is_empty() {
                lines.push("    fields: none".to_owned());
            } else {
                lines.push(format!("    fields: {}", fields.join(", ")));
            }

            if let Some(status_counts) = summary.status_counts_by_kind.get(kind) {
                if !status_counts.is_empty() {
                    lines.push(format!(
                        "    status: {}",
                        format_status_counts(status_counts)
                    ));
                }
            }

            if let Some(date_windows) = summary.date_windows_by_kind.get(kind) {
                for (field, window) in date_windows {
                    lines.push(format!(
                        "    {field}: {}..{}",
                        window.earliest, window.latest
                    ));
                }
            }
        }
    }

    if summary.link_count > 0 {
        lines.push(format!("Links: {}", summary.link_count));
        for (rel, count) in &summary.links_by_relation {
            lines.push(format!("  {rel}: {count}"));
        }
    }

    lines.push(format!("Hooks: {}", summary.hook_count));

    let sched = &summary.schedule_summary;
    if sched.active_count > 0 || sched.completed_count > 0 {
        lines.push(format!(
            "Schedules: {} active, {} completed",
            sched.active_count, sched.completed_count
        ));
        if let Some(next) = &sched.next_run_at {
            lines.push(format!("  next run: {next}"));
        }
    } else {
        lines.push("Schedules: none".to_owned());
    }

    lines.push(format!(
        "Latest activity: {}",
        summary.latest_activity_at.as_deref().unwrap_or("none")
    ));

    let mut output = lines.join("\n");
    append_recent_records_section(&mut output, summary);
    cap_quick_context_output(output)
}

fn append_recent_records_section(output: &mut String, summary: &QuickContextSummary) {
    if summary.recent_records.is_empty() {
        return;
    }

    // Append recent record lines only while the total output stays within the
    // byte cap, dropping the least recently updated entries first.
    let header = "\nRecent records:";
    let mut section = String::new();
    for record in &summary.recent_records {
        let line = format!("\n  {}", format_recent_record(record));
        if output.len() + header.len() + section.len() + line.len()
            > QUICK_CONTEXT_OUTPUT_LIMIT_BYTES
        {
            break;
        }
        section.push_str(&line);
    }

    if !section.is_empty() {
        output.push_str(header);
        output.push_str(&section);
    }
}

fn format_status_counts(status_counts: &BTreeMap<String, i64>) -> String {
    status_counts
        .iter()
        .map(|(status, count)| format!("{}={count}", shell_quote_value(status)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn cap_quick_context_output(mut output: String) -> String {
    if output.len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES {
        return output;
    }

    let marker = format!("\n... truncated at {QUICK_CONTEXT_OUTPUT_LIMIT_BYTES} bytes");
    let mut truncate_at = QUICK_CONTEXT_OUTPUT_LIMIT_BYTES.saturating_sub(marker.len());
    while !output.is_char_boundary(truncate_at) {
        truncate_at -= 1;
    }

    output.truncate(truncate_at);
    output.push_str(&marker);
    output
}

fn shell_quote_value(value: &str) -> String {
    if !value.is_empty() && value.bytes().all(is_shell_safe_byte) {
        return value.to_owned();
    }

    if value.chars().any(char::is_control) {
        return ansi_c_quote_value(value);
    }

    let mut quoted = String::from("'");
    for ch in value.chars() {
        if ch == '\'' {
            quoted.push_str("'\"'\"'");
        } else {
            quoted.push(ch);
        }
    }
    quoted.push('\'');
    quoted
}

/// Quote a value containing control characters as bash ANSI-C `$'...'` so
/// record lines stay one line each (`\n`, `\r`, `\t`, and other control
/// characters are escaped) while remaining shell-eval round-trippable.
fn ansi_c_quote_value(value: &str) -> String {
    let mut quoted = String::from("$'");
    for ch in value.chars() {
        match ch {
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            '\\' => quoted.push_str("\\\\"),
            '\'' => quoted.push_str("\\'"),
            ch if ch.is_control() => {
                for byte in ch.to_string().as_bytes() {
                    quoted.push_str(&format!("\\x{byte:02x}"));
                }
            }
            ch => quoted.push(ch),
        }
    }
    quoted.push('\'');
    quoted
}

fn is_shell_safe_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'/' | b':' | b'@' | b'%')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_json_wraps_message_and_escapes_quotes() {
        assert_eq!(
            error_json("failed to get record: no such record").to_string(),
            r#"{"error":"failed to get record: no such record"}"#
        );
        assert_eq!(
            error_json(r#"bad "value" here"#).to_string(),
            r#"{"error":"bad \"value\" here"}"#
        );
    }

    #[test]
    fn record_output_is_stable_and_shell_quoted() {
        let record = Record {
            id: "abc123".to_owned(),
            kind: "note".to_owned(),
            created_at: "2026-07-01T10:00:00.000Z".to_owned(),
            updated_at: "2026-07-02T11:00:00.000Z".to_owned(),
            fields: BTreeMap::from([
                ("title".to_owned(), "hello world".to_owned()),
                ("empty".to_owned(), String::new()),
                ("status".to_owned(), "open".to_owned()),
            ]),
        };

        assert_eq!(
            format_record(&record),
            "abc123 note empty='' status=open title='hello world'"
        );
        assert_eq!(
            format_record_with_timestamps(&record),
            "abc123 note empty='' status=open title='hello world' \
             created_at=2026-07-01T10:00:00.000Z updated_at=2026-07-02T11:00:00.000Z"
        );
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote_value("can't"), "'can'\"'\"'t'");
    }

    #[test]
    fn multiline_values_stay_on_one_record_line() {
        let record = Record {
            id: "abc123".to_owned(),
            kind: "note".to_owned(),
            created_at: "2026-07-01T10:00:00.000Z".to_owned(),
            updated_at: "2026-07-02T11:00:00.000Z".to_owned(),
            fields: BTreeMap::from([("multi".to_owned(), "line1\nline2".to_owned())]),
        };

        let line = format_record(&record);
        assert_eq!(line, "abc123 note multi=$'line1\\nline2'");
        assert!(!line.contains('\n'));
    }

    #[test]
    fn control_characters_are_ansi_c_quoted() {
        assert_eq!(shell_quote_value("a\tb"), "$'a\\tb'");
        assert_eq!(shell_quote_value("a\rb"), "$'a\\rb'");
        assert_eq!(shell_quote_value("it's\na"), "$'it\\'s\\na'");
        assert_eq!(shell_quote_value("back\\slash\n"), "$'back\\\\slash\\n'");
        assert_eq!(shell_quote_value("bell\x07"), "$'bell\\x07'");
        // Values without control characters keep plain single-quoting.
        assert_eq!(shell_quote_value("hello world"), "'hello world'");
    }

    #[test]
    fn quick_context_output_is_stable() {
        let summary = QuickContextSummary {
            record_count: 3,
            records_by_kind: BTreeMap::from([("note".to_owned(), 1), ("task".to_owned(), 2)]),
            fields_by_kind: BTreeMap::from([
                ("note".to_owned(), vec!["title".to_owned()]),
                (
                    "task".to_owned(),
                    vec!["due".to_owned(), "status".to_owned(), "title".to_owned()],
                ),
            ]),
            status_counts_by_kind: BTreeMap::from([(
                "task".to_owned(),
                BTreeMap::from([("open".to_owned(), 2)]),
            )]),
            date_windows_by_kind: BTreeMap::from([(
                "task".to_owned(),
                BTreeMap::from([(
                    "due".to_owned(),
                    agent_store::store::DateWindow {
                        earliest: "2026-06-26".to_owned(),
                        latest: "2026-06-30".to_owned(),
                    },
                )]),
            )]),
            link_count: 3,
            links_by_relation: BTreeMap::from([
                ("blocks".to_owned(), 2),
                ("depends_on".to_owned(), 1),
            ]),
            hook_count: 1,
            schedule_summary: ScheduleSummary {
                active_count: 2,
                completed_count: 1,
                next_run_at: Some("2026-06-27T00:00:00.000Z".to_owned()),
            },
            latest_activity_at: Some("2026-06-26T12:34:56.789Z".to_owned()),
            recent_records: vec![Record {
                id: "abc123".to_owned(),
                kind: "note".to_owned(),
                created_at: "2026-06-26T12:00:00.000Z".to_owned(),
                updated_at: "2026-06-26T12:34:56.789Z".to_owned(),
                fields: BTreeMap::from([("title".to_owned(), "hello world".to_owned())]),
            }],
        };

        assert_eq!(
            format_quick_context(&summary),
            "Quick Context\nRecords: 3\nRecord kinds:\n  note: 1\n    fields: title\n  task: 2\n    fields: due, status, title\n    status: open=2\n    due: 2026-06-26..2026-06-30\nLinks: 3\n  blocks: 2\n  depends_on: 1\nHooks: 1\nSchedules: 2 active, 1 completed\n  next run: 2026-06-27T00:00:00.000Z\nLatest activity: 2026-06-26T12:34:56.789Z\nRecent records:\n  abc123 note title='hello world'"
        );
    }

    #[test]
    fn recent_record_values_are_truncated_with_ellipsis() {
        let record = Record {
            id: "abc123".to_owned(),
            kind: "note".to_owned(),
            created_at: "2026-06-26T12:00:00.000Z".to_owned(),
            updated_at: "2026-06-26T12:34:56.789Z".to_owned(),
            fields: BTreeMap::from([("body".to_owned(), "x".repeat(500))]),
        };

        let line = format_recent_record(&record);
        assert_eq!(line, format!("abc123 note body={}...", "x".repeat(100)));

        let value = recent_record_json(&record);
        assert_eq!(
            value["fields"]["body"],
            json!(format!("{}...", "x".repeat(100)))
        );
    }

    #[test]
    fn quick_context_recent_section_respects_byte_cap() {
        let recent_records = (0..10)
            .map(|index| Record {
                id: format!("record{index:04}"),
                kind: "note".to_owned(),
                created_at: "2026-06-26T12:00:00.000Z".to_owned(),
                updated_at: "2026-06-26T12:34:56.789Z".to_owned(),
                fields: BTreeMap::from([
                    ("a".to_owned(), "y".repeat(20_000)),
                    ("b".to_owned(), "z".repeat(20_000)),
                    ("c".to_owned(), "w".repeat(20_000)),
                    ("d".to_owned(), "v".repeat(20_000)),
                    ("e".to_owned(), "u".repeat(20_000)),
                ]),
            })
            .collect::<Vec<_>>();
        let summary = QuickContextSummary {
            record_count: 10,
            records_by_kind: BTreeMap::from([("note".to_owned(), 10)]),
            fields_by_kind: BTreeMap::from([(
                "note".to_owned(),
                vec![
                    "a".to_owned(),
                    "b".to_owned(),
                    "c".to_owned(),
                    "d".to_owned(),
                    "e".to_owned(),
                ],
            )]),
            status_counts_by_kind: BTreeMap::new(),
            date_windows_by_kind: BTreeMap::new(),
            link_count: 0,
            links_by_relation: BTreeMap::new(),
            hook_count: 0,
            schedule_summary: ScheduleSummary {
                active_count: 0,
                completed_count: 0,
                next_run_at: None,
            },
            latest_activity_at: Some("2026-06-26T12:34:56.789Z".to_owned()),
            recent_records,
        };

        let output = format_quick_context(&summary);
        assert!(output.len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES);
        assert!(output.contains("Recent records:"));
        assert!(output.contains("record0000"));
        assert!(!output.contains("... truncated at"));

        let json_output = quick_context_json(&summary).to_string();
        assert!(json_output.len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES);
        assert!(json_output.contains("record0000"));
    }

    #[test]
    fn quick_context_output_is_bounded() {
        let summary = QuickContextSummary {
            record_count: 1,
            records_by_kind: BTreeMap::from([("large".to_owned(), 1)]),
            fields_by_kind: BTreeMap::from([(
                "large".to_owned(),
                (0..2000).map(|index| format!("field_{index:04}")).collect(),
            )]),
            status_counts_by_kind: BTreeMap::new(),
            date_windows_by_kind: BTreeMap::new(),
            link_count: 0,
            links_by_relation: BTreeMap::new(),
            hook_count: 0,
            schedule_summary: ScheduleSummary {
                active_count: 0,
                completed_count: 0,
                next_run_at: None,
            },
            latest_activity_at: None,
            recent_records: Vec::new(),
        };

        let output = format_quick_context(&summary);

        assert!(output.len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES);
        assert!(output.ends_with("... truncated at 8192 bytes"));
    }
}
