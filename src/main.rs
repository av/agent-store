/// Exit code used when stdout's reader closes early (128 + SIGPIPE).
const BROKEN_PIPE_EXIT_CODE: i32 = 141;

/// Terminates quietly with exit 141 when stdout writes hit a closed pipe.
fn check_stdout(result: std::io::Result<()>) {
    if let Err(error) = result {
        if error.kind() == std::io::ErrorKind::BrokenPipe {
            std::process::exit(BROKEN_PIPE_EXIT_CODE);
        }
        eprintln!("error: failed to write to stdout: {error}");
        std::process::exit(1);
    }
}

/// Like `print!`, but exits quietly on a broken stdout pipe.
macro_rules! out {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        crate::check_stdout(write!(std::io::stdout(), $($arg)*));
    }};
}

/// Like `println!`, but exits quietly on a broken stdout pipe.
macro_rules! outln {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        crate::check_stdout(writeln!(std::io::stdout(), $($arg)*));
    }};
}

mod cli;
mod output;

use agent_store::query::{record_sort_value, Query};
use agent_store::store::{
    FieldChange, Hook, Link, LinkEdge, Record, Schedule, Store, StoreError, STORE_DIR,
};
use agent_store::value::{self, FieldValue};
use cli::{CliCommand, HookCliCommand, ScheduleCliCommand};
use output::{
    count_json, error_json, format_hook, format_hook_run_detail, format_hook_run_summary,
    format_quick_context, format_record, format_record_with_timestamps, format_schedule,
    format_schedule_run_detail, format_schedule_run_summary, help_text, hook_mutation_json,
    hook_runs_json, hooks_json, init_json, link_mutation_json, mutation_json, print_json,
    quick_context_json, record_links_json, records_json, schedule_mutation_json,
    schedule_runs_json, schedules_json, single_hook_run_json, single_record_json,
    single_schedule_run_json, tick_json, USAGE,
};
use serde_json::json;
use std::cmp::Ordering;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{self, Command};
use std::thread;
use std::time::{Duration, Instant};

const GITIGNORE_PATH: &str = ".gitignore";
const GITIGNORE_RULE: &str = ".agent-store/";
const AGENT_SKILLS_DIR: &str = ".agents/skills";
const CLAUDE_SKILLS_DIR: &str = ".claude/skills";
const INSTRUCTION_FILES: &[&str] = &["AGENTS.md", "CLAUDE.md"];
const INSTRUCTIONS_START: &str = "<!-- agent-store:start -->";
const DEFAULT_HOOK_TIMEOUT: Duration = Duration::from_secs(30);
/// Environment variable carrying the current hook/schedule nesting depth.
/// Every spawned hook or schedule command receives `current depth + 1`.
const HOOK_DEPTH_ENV: &str = "AGENT_STORE_HOOK_DEPTH";
/// Mutations performed at or beyond this nesting depth commit normally but
/// skip hook dispatch, so a hook that mutates the store cannot recurse
/// without bound. A note is printed on stderr when dispatch is skipped.
const MAX_HOOK_DEPTH: usize = 3;
const HOOK_TIMEOUT_EXIT_STATUS: i32 = -1;
const HOOK_OUTPUT_CAPTURE_LIMIT_BYTES: usize = 8192;
const HOOK_ENV_KEYS: &[&str] = &[
    "AGENT_STORE_EVENT",
    "AGENT_STORE_ID",
    "AGENT_STORE_KIND",
    "AGENT_STORE_REL",
    "AGENT_STORE_TARGET_ID",
    "AGENT_STORE_FIELD",
    "AGENT_STORE_KEY",
    "AGENT_STORE_VALUE",
    "AGENT_STORE_OLD_VALUE",
    "AGENT_STORE_NEW_VALUE",
];
const INSTRUCTIONS_BLOCK: &str = "\
<!-- agent-store:start -->
## agent-store
- Run `agent-store init` before using the project-local store.
- Use `agent-store create <kind> key=value...` to store records and `agent-store find <query>` to retrieve them.
- Use `agent-store ctx` for a compact project summary, and read the installed `agent-store` skills for workflow guidance.
<!-- agent-store:end -->
";

struct BuiltinSkill {
    name: &'static str,
    content: &'static str,
}

const BUILTIN_SKILLS: &[BuiltinSkill] = &[
    BuiltinSkill {
        name: "agent-store",
        content: r#"---
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
exactly one field, `AGENT_STORE_FIELD` and `AGENT_STORE_KEY` hold the field
key, `AGENT_STORE_VALUE` the new value (the old value on unset), and
`AGENT_STORE_OLD_VALUE`/`AGENT_STORE_NEW_VALUE` the before/after values
(empty when absent).

Schedules run bash commands on a time basis, complementing event-triggered
hooks. Two kinds: `at` fires once at an absolute timestamp, `every` fires
repeatedly at a duration interval. Commands use the same execution model as
hooks (bash -c, 30s timeout, process group management, stdin record, env
vars). An optional query scopes execution to matching records (one run per
match):

```bash
agent-store schedule add every 5m -- 'echo heartbeat'
agent-store schedule add at 2026-07-07T12:00:00Z -- 'cleanup.sh'
agent-store schedule add every 1h 'kind=task and status=open' -- 'notify.sh'
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
"#,
    },
    BuiltinSkill {
        name: "agent-store-patterns",
        content: r#"---
name: agent-store-patterns
description: >
  Workflow recipes for using agent-store as a scratchpad, task tracker,
  decision log, and handoff memory.
---

# agent-store-patterns

Use records as small, queryable notes rather than long append-only logs.

Scratchpad:

```bash
agent-store create scratch task=refactor step=1 note="parsed current API"
agent-store find 'kind=scratch and task=refactor'
```

Task tracking:

```bash
agent-store create task title="Fix parser" status=pending priority=high
agent-store find 'kind=task and status!=done'
agent-store find kind=task status=pending --sort created_at --limit 5   # oldest open work first
agent-store find 'kind=task and status!=done' --count
agent-store set <id> status=done
```

Decision log:

```bash
agent-store create decision area=storage choice=sqlite reason="single-file project-local store"
agent-store find 'kind=decision and area=storage'
agent-store find kind=decision --sort created_at --desc --limit 3 --timestamps   # latest decisions
```

Chronology is built in: listings default to creation order (oldest first),
and the `created_at`/`updated_at` timestamps are sortable and queryable, so
records do not need a manual date field.
"#,
    },
    BuiltinSkill {
        name: "agent-store-pipelines",
        content: r#"---
name: agent-store-pipelines
description: >
  Shell composition patterns for importing, exporting, and transforming
  agent-store records.
---

# agent-store-pipelines

agent-store is designed to compose with ordinary shell tools.

Batch create from lines:

```bash
while IFS= read -r line; do
  agent-store create note text="$line"
done < notes.txt
```

Bulk import JSONL with `create --stdin` (one `{"kind":...,"fields":{...}}`
object per line, the `find --json` record shape; extra keys like `id` and
timestamps are ignored, so exports round-trip):

```bash
agent-store find kind=task --json | jq -c '.records[]' | agent-store create --stdin
```

Every line is validated before any record is created; an invalid line exits
non-zero naming the line number with nothing imported.

Filter and format: `--json` list output wraps records in a
`{"records":[...]}` envelope, so iterate with `.records[]`:

```bash
agent-store find 'kind=task and status=pending' --json | jq -r '.records[].id'
```

JSON records include `created_at` and `updated_at` timestamps. Prefer the
built-in `--sort`, `--desc`, `--limit`, and `--count` flags over shell-side
`sort`, `head`, or `wc -l`:

```bash
agent-store find kind=log --sort updated_at --desc --limit 10
agent-store find kind=note --count
```

Capture command output:

```bash
agent-store create log command=test output="$(cargo test 2>&1)"
```
"#,
    },
];

fn main() {
    let cli = match cli::parse_args(env::args().skip(1)) {
        Ok(cli) => cli,
        Err(error) => {
            eprintln!("error: {error}");
            if error.include_usage() {
                eprintln!();
                eprint!("{USAGE}");
            }
            process::exit(2);
        }
    };

    match cli.command {
        CliCommand::Help { topic } => {
            out!("{}", help_text(topic));
        }
        CliCommand::Version => {
            outln!("agent-store {}", env!("CARGO_PKG_VERSION"));
        }
        CliCommand::Init => {
            let summary = match init_store() {
                Ok(summary) => summary,
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to initialize store: {error}"),
                    );
                }
            };

            if cli.json_output {
                print_json(init_json(
                    summary.already_initialized,
                    &summary.skills_installed,
                    &summary
                        .instructions
                        .iter()
                        .map(|(path, status)| (*path, status.as_str()))
                        .collect::<Vec<_>>(),
                ));
            } else {
                if summary.already_initialized {
                    outln!("Already initialized {STORE_DIR}/");
                } else {
                    outln!("Initialized {STORE_DIR}/");
                }
                if summary.skills_installed.is_empty() {
                    outln!(
                        "Skills already installed in {AGENT_SKILLS_DIR}/ and {CLAUDE_SKILLS_DIR}/"
                    );
                } else {
                    for path in &summary.skills_installed {
                        outln!("Installed {path}");
                    }
                }
                let all_missing = summary
                    .instructions
                    .iter()
                    .all(|(_, status)| *status == InstructionStatus::Missing);
                if all_missing {
                    outln!(
                        "No AGENTS.md or CLAUDE.md found; create one and re-run `agent-store init` to add the instructions block"
                    );
                } else {
                    for (path, status) in &summary.instructions {
                        match status {
                            InstructionStatus::Added => {
                                outln!("Added instructions block to {path}")
                            }
                            InstructionStatus::Present => {
                                outln!("Instructions block already present in {path}")
                            }
                            InstructionStatus::Missing => {}
                        }
                    }
                }
            }
        }
        CliCommand::Create { kind, fields } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.create_record(&kind, fields) {
                Ok(record) => {
                    if cli.json_output {
                        print_json(mutation_json("created", &record));
                    } else {
                        outln!("{}", record.id);
                    }
                    run_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "create",
                        &record,
                        Some(&[]),
                        &[],
                    );
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to create record: {error}"),
                    );
                }
            }
        }
        CliCommand::CreateStdin => {
            let mut input = String::new();
            if let Err(error) = io::stdin().read_to_string(&mut input) {
                fail(cli.json_output, 1, format!("failed to read stdin: {error}"));
            }

            // Validate every line before creating anything so an invalid
            // line never leaves a partial import behind.
            let mut parsed_lines = Vec::new();
            for (index, line) in input.lines().enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                match cli::parse_jsonl_record(line) {
                    Ok(parsed) => parsed_lines.push(parsed),
                    Err(error) => {
                        fail(
                            cli.json_output,
                            1,
                            format!("stdin line {}: {error}", index + 1),
                        );
                    }
                }
            }

            let mut store = open_store_or_exit(cli.json_output);
            let mut created = Vec::with_capacity(parsed_lines.len());
            for (kind, fields) in parsed_lines {
                match store.create_record(&kind, fields) {
                    Ok(record) => {
                        created.push(record);
                    }
                    Err(error) => {
                        fail(cli.json_output, 1, format!("failed to create record after {} records were already created: {error}", created.len()));
                    }
                }
            }

            if cli.json_output {
                print_json(records_json(&created));
            } else {
                for record in &created {
                    outln!("{}", record.id);
                }
            }

            for record in &created {
                run_hooks_or_exit(
                    cli.json_output,
                    &mut store,
                    "create",
                    record,
                    Some(&[]),
                    &[],
                );
            }
        }
        CliCommand::Get { id, timestamps } => {
            let store = open_store_or_exit(cli.json_output);
            match store.get_record(&id) {
                Ok(record) => {
                    if cli.json_output {
                        print_json(single_record_json(&record));
                    } else if timestamps {
                        outln!("{}", format_record_with_timestamps(&record));
                    } else {
                        outln!("{}", format_record(&record));
                    }
                }
                Err(error) => {
                    fail(cli.json_output, 1, format!("failed to get record: {error}"));
                }
            }
        }
        CliCommand::Find {
            query,
            timestamps,
            sort,
            desc,
            limit,
            count,
        } => {
            let query = match query {
                Some(raw) => match Query::parse(&raw) {
                    Ok(query) => Some(query),
                    Err(error) => {
                        fail(cli.json_output, 2, format!("invalid query: {error}"));
                    }
                },
                None => None,
            };
            let store = open_store_or_exit(cli.json_output);
            match store.find_records(query.as_ref()) {
                Ok(mut records) => {
                    if let Some(field) = &sort {
                        sort_records(&mut records, field, desc);
                    } else if desc {
                        records.reverse();
                    }
                    if let Some(limit) = limit {
                        records.truncate(limit);
                    }
                    if count {
                        if cli.json_output {
                            print_json(count_json(records.len()));
                        } else {
                            outln!("{}", records.len());
                        }
                    } else if cli.json_output {
                        print_json(records_json(&records));
                    } else {
                        for record in records {
                            if timestamps {
                                outln!("{}", format_record_with_timestamps(&record));
                            } else {
                                outln!("{}", format_record(&record));
                            }
                        }
                    }
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to find records: {error}"),
                    );
                }
            }
        }
        CliCommand::Set { id, fields } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.set_record_with_snapshot(&id, fields) {
                Ok(mutation) => {
                    if cli.json_output {
                        print_json(mutation_json("updated", &mutation.record));
                    } else {
                        outln!("Updated {}", mutation.record.id);
                    }
                    run_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "set",
                        &mutation.record,
                        Some(&mutation.record_links),
                        &mutation.field_changes,
                    );
                }
                Err(error) => {
                    fail(cli.json_output, 1, format!("failed to set record: {error}"));
                }
            }
        }
        CliCommand::Unset { id, keys } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.unset_record_with_snapshot(&id, keys) {
                Ok(mutation) => {
                    if cli.json_output {
                        print_json(mutation_json("updated", &mutation.record));
                    } else {
                        outln!("Updated {}", mutation.record.id);
                    }
                    run_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "unset",
                        &mutation.record,
                        Some(&mutation.record_links),
                        &mutation.field_changes,
                    );
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to unset record: {error}"),
                    );
                }
            }
        }
        CliCommand::Rm { id } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.delete_record_with_snapshot(&id) {
                Ok(mutation) => {
                    if cli.json_output {
                        print_json(mutation_json("removed", &mutation.record));
                    } else {
                        outln!("Removed {}", mutation.record.id);
                    }
                    run_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "rm",
                        &mutation.record,
                        Some(&mutation.record_links),
                        &[],
                    );
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to remove record: {error}"),
                    );
                }
            }
        }
        CliCommand::Link { from, rel, to } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.link_records_with_snapshot(&from, &rel, &to) {
                Ok(mutation) => {
                    if cli.json_output {
                        print_json(link_mutation_json("linked", &mutation.link));
                    } else {
                        outln!(
                            "Linked {} {} {}",
                            mutation.link.from_record_id,
                            mutation.link.rel,
                            mutation.link.to_record_id
                        );
                    }
                    run_link_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "link",
                        &mutation.source,
                        &mutation.link,
                        &mutation.source_links,
                    );
                }
                Err(error @ StoreError::SelfLink(_)) => {
                    fail(cli.json_output, 1, format!("{error}"));
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to link records: {error}"),
                    );
                }
            }
        }
        CliCommand::Unlink { from, rel, to } => {
            let mut store = open_store_or_exit(cli.json_output);
            match store.unlink_records_with_snapshot(&from, &rel, &to) {
                Ok(mutation) => {
                    if cli.json_output {
                        print_json(link_mutation_json("unlinked", &mutation.link));
                    } else {
                        outln!(
                            "Unlinked {} {} {}",
                            mutation.link.from_record_id,
                            mutation.link.rel,
                            mutation.link.to_record_id
                        );
                    }
                    run_link_hooks_or_exit(
                        cli.json_output,
                        &mut store,
                        "unlink",
                        &mutation.source,
                        &mutation.link,
                        &mutation.source_links,
                    );
                }
                Err(error @ StoreError::LinkNotFound { .. }) => {
                    fail(cli.json_output, 1, format!("{error}"));
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to unlink records: {error}"),
                    );
                }
            }
        }
        CliCommand::Links { id } => {
            let store = open_store_or_exit(cli.json_output);
            match store.links_for_record(&id) {
                Ok(record_links) => {
                    if cli.json_output {
                        print_json(record_links_json(
                            &record_links.record_id,
                            &record_links.links,
                        ));
                    } else {
                        for link in record_links.links {
                            outln!(
                                "{} {} {}",
                                link.direction.as_str(),
                                link.rel,
                                link.peer_record_id
                            );
                        }
                    }
                }
                Err(error) => {
                    fail(cli.json_output, 1, format!("failed to list links: {error}"));
                }
            }
        }
        CliCommand::Context => {
            let store = open_store_or_exit(cli.json_output);
            match store.quick_context_summary() {
                Ok(summary) => {
                    if cli.json_output {
                        print_json(quick_context_json(&summary));
                    } else {
                        outln!("{}", format_quick_context(&summary));
                    }
                }
                Err(error) => {
                    fail(
                        cli.json_output,
                        1,
                        format!("failed to build Quick Context: {error}"),
                    );
                }
            }
        }
        CliCommand::Hook(command) => match command {
            HookCliCommand::Add {
                event,
                query,
                command,
            } => {
                let mut store = open_store_or_exit(cli.json_output);
                match store.add_hook(&event, query, &command) {
                    Ok(hook) => {
                        if cli.json_output {
                            print_json(hook_mutation_json("added", &hook));
                        } else {
                            outln!("{}", hook.id);
                        }
                    }
                    Err(error) => {
                        fail(cli.json_output, 1, format!("failed to add hook: {error}"));
                    }
                }
            }
            HookCliCommand::List => {
                let store = open_store_or_exit(cli.json_output);
                match store.list_hooks() {
                    Ok(hooks) => {
                        if cli.json_output {
                            print_json(hooks_json(&hooks));
                        } else {
                            for hook in hooks {
                                outln!("{}", format_hook(&hook));
                            }
                        }
                    }
                    Err(error) => {
                        fail(cli.json_output, 1, format!("failed to list hooks: {error}"));
                    }
                }
            }
            HookCliCommand::Remove { id } => {
                let mut store = open_store_or_exit(cli.json_output);
                match store.delete_hook(&id) {
                    Ok(hook) => {
                        if cli.json_output {
                            print_json(hook_mutation_json("removed", &hook));
                        } else {
                            outln!("Removed {}", hook.id);
                        }
                    }
                    Err(error) => {
                        fail(
                            cli.json_output,
                            1,
                            format!("failed to remove hook: {error}"),
                        );
                    }
                }
            }
            HookCliCommand::Runs { limit, run_id } => {
                let store = open_store_or_exit(cli.json_output);
                if let Some(run_id) = run_id {
                    match store.get_hook_run(run_id) {
                        Ok(run) => {
                            if cli.json_output {
                                print_json(single_hook_run_json(&run));
                            } else {
                                outln!("{}", format_hook_run_detail(&run));
                            }
                        }
                        Err(error) => {
                            fail(
                                cli.json_output,
                                1,
                                format!("failed to get hook run: {error}"),
                            );
                        }
                    }
                } else {
                    match store.list_recent_hook_runs(limit) {
                        Ok(runs) => {
                            if cli.json_output {
                                print_json(hook_runs_json(&runs));
                            } else if runs.is_empty() {
                                outln!("No hook runs recorded yet.");
                            } else {
                                for run in runs {
                                    outln!("{}", format_hook_run_summary(&run));
                                }
                            }
                        }
                        Err(error) => {
                            fail(
                                cli.json_output,
                                1,
                                format!("failed to list hook runs: {error}"),
                            );
                        }
                    }
                }
            }
        },
        CliCommand::Schedule(command) => match command {
            ScheduleCliCommand::Add {
                kind,
                expression,
                query,
                command,
            } => {
                let mut store = open_store_or_exit(cli.json_output);
                let (next_run_at, interval_seconds) =
                    resolve_schedule_time(&store, &kind, &expression, cli.json_output);
                match store.add_schedule(
                    &kind,
                    &expression,
                    interval_seconds,
                    &next_run_at,
                    query,
                    &command,
                ) {
                    Ok(schedule) => {
                        if cli.json_output {
                            print_json(schedule_mutation_json("added", &schedule));
                        } else {
                            outln!("{}", schedule.id);
                        }
                    }
                    Err(error) => {
                        fail(
                            cli.json_output,
                            1,
                            format!("failed to add schedule: {error}"),
                        );
                    }
                }
            }
            ScheduleCliCommand::List => {
                let store = open_store_or_exit(cli.json_output);
                match store.list_schedules() {
                    Ok(schedules) => {
                        if cli.json_output {
                            print_json(schedules_json(&schedules));
                        } else {
                            for schedule in schedules {
                                outln!("{}", format_schedule(&schedule));
                            }
                        }
                    }
                    Err(error) => {
                        fail(
                            cli.json_output,
                            1,
                            format!("failed to list schedules: {error}"),
                        );
                    }
                }
            }
            ScheduleCliCommand::Remove { id } => {
                let mut store = open_store_or_exit(cli.json_output);
                match store.delete_schedule(&id) {
                    Ok(schedule) => {
                        if cli.json_output {
                            print_json(schedule_mutation_json("removed", &schedule));
                        } else {
                            outln!("Removed {}", schedule.id);
                        }
                    }
                    Err(error) => {
                        fail(
                            cli.json_output,
                            1,
                            format!("failed to remove schedule: {error}"),
                        );
                    }
                }
            }
            ScheduleCliCommand::Runs { limit, run_id } => {
                let store = open_store_or_exit(cli.json_output);
                if let Some(run_id) = run_id {
                    match store.get_schedule_run(run_id) {
                        Ok(run) => {
                            if cli.json_output {
                                print_json(single_schedule_run_json(&run));
                            } else {
                                outln!("{}", format_schedule_run_detail(&run));
                            }
                        }
                        Err(error) => {
                            fail(
                                cli.json_output,
                                1,
                                format!("failed to get schedule run: {error}"),
                            );
                        }
                    }
                } else {
                    match store.list_recent_schedule_runs(limit) {
                        Ok(runs) => {
                            if cli.json_output {
                                print_json(schedule_runs_json(&runs));
                            } else if runs.is_empty() {
                                outln!("No schedule runs recorded yet.");
                            } else {
                                for run in runs {
                                    outln!("{}", format_schedule_run_summary(&run));
                                }
                            }
                        }
                        Err(error) => {
                            fail(
                                cli.json_output,
                                1,
                                format!("failed to list schedule runs: {error}"),
                            );
                        }
                    }
                }
            }
            ScheduleCliCommand::Tick => {
                let mut store = open_store_or_exit(cli.json_output);
                execute_tick(&mut store, cli.json_output);
            }
            ScheduleCliCommand::Enable => {
                let store = open_store_or_exit(cli.json_output);
                match enable_schedule_cron(&store) {
                    Ok(()) => {
                        if cli.json_output {
                            print_json(json!({"status": "enabled"}));
                        } else {
                            outln!("Enabled: crontab entry installed for schedule tick");
                        }
                    }
                    Err(error) => {
                        fail(cli.json_output, 1, error);
                    }
                }
            }
            ScheduleCliCommand::Disable => {
                let store = open_store_or_exit(cli.json_output);
                match disable_schedule_cron(&store) {
                    Ok(removed) => {
                        if cli.json_output {
                            print_json(json!({"status": "disabled"}));
                        } else if removed {
                            outln!("Disabled: crontab entry removed");
                        } else {
                            outln!("No crontab entry found for this project");
                        }
                    }
                    Err(error) => {
                        fail(cli.json_output, 1, error);
                    }
                }
            }
        },
    }
}

/// Returns whether the store directory already existed before this run.
/// Sorts records by a field using the same typed values as query
/// comparisons. Records missing the field always sort last; the stable sort
/// preserves creation order among equal keys.
fn sort_records(records: &mut [Record], field: &str, desc: bool) {
    records.sort_by(|left, right| {
        match (
            record_sort_value(left, field),
            record_sort_value(right, field),
        ) {
            (Some(left), Some(right)) => {
                let ordering = compare_sort_values(&left, &right);
                if desc {
                    ordering.reverse()
                } else {
                    ordering
                }
            }
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        }
    });
}

fn compare_sort_values(left: &FieldValue, right: &FieldValue) -> Ordering {
    left.value_ordering(right)
        .unwrap_or_else(|| sort_type_rank(left).cmp(&sort_type_rank(right)))
}

/// Groups values of different (incomparable) types into a predictable order:
/// booleans, numbers, dates/timestamps, text, then nulls.
fn sort_type_rank(value: &FieldValue) -> u8 {
    match value {
        FieldValue::Boolean(_) => 0,
        FieldValue::Number(_) => 1,
        FieldValue::Date(_) | FieldValue::Timestamp(_) => 2,
        FieldValue::Text(_) => 3,
        FieldValue::Null => 4,
    }
}

fn resolve_schedule_time(
    store: &Store,
    kind: &str,
    expression: &str,
    json_output: bool,
) -> (String, Option<i64>) {
    if let Some(seconds) = value::parse_duration_seconds(expression) {
        let next_run_at = match store.now_plus_seconds(seconds) {
            Ok(ts) => ts,
            Err(error) => {
                fail(
                    json_output,
                    1,
                    format!("failed to compute schedule time: {error}"),
                );
            }
        };
        let interval_seconds = if kind == "every" { Some(seconds) } else { None };
        return (next_run_at, interval_seconds);
    }

    if kind == "every" {
        fail(
            json_output,
            2,
            format!("invalid interval '{expression}'; expected a duration like 5m, 1h, or 2d"),
        );
    }

    let parsed = FieldValue::parse(expression);
    match parsed {
        FieldValue::Date(date) => {
            let timestamp = format!("{date}T00:00:00.000Z");
            (timestamp, None)
        }
        FieldValue::Timestamp(ts) => (ts, None),
        _ => {
            fail(
                json_output,
                2,
                format!(
                    "invalid time '{expression}'; expected a duration (5m, 1h, 2d) or timestamp"
                ),
            );
        }
    }
}

fn execute_tick(store: &mut Store, json_output: bool) {
    let due_schedules = match store.tick_due_schedules() {
        Ok(schedules) => schedules,
        Err(error) => {
            fail(json_output, 1, format!("failed to tick schedules: {error}"));
        }
    };

    let project_root = store.project_root().to_path_buf();
    let mut all_runs = Vec::new();

    for schedule in &due_schedules {
        if let Some(query_text) = &schedule.query {
            let query = match agent_store::query::Query::parse(query_text) {
                Ok(q) => q,
                Err(error) => {
                    eprintln!(
                        "warning: schedule {} has invalid query, skipping: {error}",
                        schedule.id
                    );
                    continue;
                }
            };
            let records = match store.find_records(Some(&query)) {
                Ok(r) => r,
                Err(error) => {
                    eprintln!(
                        "warning: schedule {} query failed, skipping: {error}",
                        schedule.id
                    );
                    continue;
                }
            };
            for record in &records {
                let run = execute_schedule_command(store, schedule, Some(record), &project_root);
                all_runs.push(run);
            }
        } else {
            let run = execute_schedule_command(store, schedule, None, &project_root);
            all_runs.push(run);
        }
    }

    if json_output {
        print_json(tick_json(&all_runs));
    } else {
        for run in &all_runs {
            outln!("{}", format_schedule_run_summary(run));
        }
    }
}

fn execute_schedule_command(
    store: &mut Store,
    schedule: &Schedule,
    record: Option<&Record>,
    project_root: &Path,
) -> agent_store::store::ScheduleRun {
    let stdin_payload = match record {
        Some(r) => format!("{}\n", format_record(r)),
        None => String::new(),
    };

    let mut env_vars: Vec<(&'static str, String)> =
        vec![("AGENT_STORE_SCHEDULE_ID", schedule.id.clone())];
    if let Some(record) = record {
        env_vars.push(("AGENT_STORE_EVENT", "tick".to_owned()));
        env_vars.push(("AGENT_STORE_ID", record.id.clone()));
        env_vars.push(("AGENT_STORE_KIND", record.kind.clone()));
    }

    let hook = Hook {
        id: schedule.id.clone(),
        event: "tick".to_owned(),
        query: schedule.query.clone(),
        command: schedule.command.clone(),
    };

    let output = match run_hook_command(
        &hook,
        &stdin_payload,
        project_root,
        DEFAULT_HOOK_TIMEOUT,
        &env_vars,
    ) {
        Ok(output) => output,
        Err(error) => {
            let record_id = record.map(|r| r.id.as_str());
            let run = store
                .record_schedule_run(&schedule.id, record_id, 1, "", &error)
                .unwrap_or_else(|_| agent_store::store::ScheduleRun {
                    id: 0,
                    schedule_id: schedule.id.clone(),
                    record_id: record_id.map(str::to_owned),
                    exit_status: 1,
                    stdout_summary: String::new(),
                    stderr_summary: error,
                    created_at: String::new(),
                });
            return run;
        }
    };

    let exit_status = if output.timed_out {
        HOOK_TIMEOUT_EXIT_STATUS
    } else {
        hook_exit_status(&output.status)
    };
    let stdout_summary = String::from_utf8_lossy(&output.stdout).into_owned();
    let mut stderr_summary = String::from_utf8_lossy(&output.stderr).into_owned();
    if output.timed_out {
        let timeout_note = format!("timed out after {} seconds", DEFAULT_HOOK_TIMEOUT.as_secs());
        if stderr_summary.is_empty() {
            stderr_summary = timeout_note;
        } else {
            stderr_summary.push_str("; ");
            stderr_summary.push_str(&timeout_note);
        }
    }

    let record_id = record.map(|r| r.id.as_str());
    store
        .record_schedule_run(
            &schedule.id,
            record_id,
            exit_status,
            &stdout_summary,
            &stderr_summary,
        )
        .unwrap_or_else(|_| agent_store::store::ScheduleRun {
            id: 0,
            schedule_id: schedule.id.clone(),
            record_id: record_id.map(str::to_owned),
            exit_status,
            stdout_summary,
            stderr_summary,
            created_at: String::new(),
        })
}

const CRON_MARKER_PREFIX: &str = "# agent-store:tick:";

fn enable_schedule_cron(store: &Store) -> Result<(), String> {
    let project_root = store
        .project_root()
        .canonicalize()
        .map_err(|e| format!("failed to resolve project root: {e}"))?;
    let project_root_str = project_root.display().to_string();
    let binary_path = env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|e| format!("failed to resolve agent-store binary path: {e}"))?;
    let binary_path_str = binary_path.display().to_string();

    let existing = read_crontab();
    let marker = format!("{CRON_MARKER_PREFIX}{project_root_str}");

    let mut new_lines = Vec::new();
    let mut skip_next = false;
    for line in existing.lines() {
        if skip_next {
            skip_next = false;
            continue;
        }
        if line.starts_with(&marker) {
            skip_next = true;
            continue;
        }
        new_lines.push(line.to_owned());
    }

    new_lines.push(marker);
    new_lines.push(format!(
        "* * * * * cd {project_root_str} && {binary_path_str} schedule tick >/dev/null 2>&1"
    ));

    write_crontab(&new_lines.join("\n"))
}

fn disable_schedule_cron(store: &Store) -> Result<bool, String> {
    let project_root = store
        .project_root()
        .canonicalize()
        .map_err(|e| format!("failed to resolve project root: {e}"))?;
    let project_root_str = project_root.display().to_string();

    let existing = read_crontab();
    let marker = format!("{CRON_MARKER_PREFIX}{project_root_str}");

    let mut new_lines = Vec::new();
    let mut skip_next = false;
    let mut removed = false;
    for line in existing.lines() {
        if skip_next {
            skip_next = false;
            removed = true;
            continue;
        }
        if line.starts_with(&marker) {
            skip_next = true;
            removed = true;
            continue;
        }
        new_lines.push(line.to_owned());
    }

    if removed {
        write_crontab(&new_lines.join("\n"))?;
    }

    Ok(removed)
}

fn read_crontab() -> String {
    let output = Command::new("crontab")
        .arg("-l")
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::piped())
        .output();

    match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => String::new(),
    }
}

fn write_crontab(content: &str) -> Result<(), String> {
    let mut content = content.to_owned();
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }

    let mut child = Command::new("crontab")
        .arg("-")
        .stdin(process::Stdio::piped())
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to run crontab: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(content.as_bytes())
            .map_err(|e| format!("failed to write crontab: {e}"))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("failed to wait for crontab: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("crontab failed: {stderr}"));
    }

    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InstructionStatus {
    Added,
    Present,
    Missing,
}

impl InstructionStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Added => "added",
            Self::Present => "present",
            Self::Missing => "missing",
        }
    }
}

struct InitSummary {
    already_initialized: bool,
    skills_installed: Vec<String>,
    instructions: Vec<(&'static str, InstructionStatus)>,
}

fn init_store() -> io::Result<InitSummary> {
    check_store_dir_conflict(Path::new(STORE_DIR))?;
    let already_initialized = Path::new(STORE_DIR).is_dir();
    fs::create_dir_all(STORE_DIR)?;
    ensure_gitignore_rule(Path::new(GITIGNORE_PATH), GITIGNORE_RULE)?;
    let mut skills_installed = install_builtin_skills(Path::new(AGENT_SKILLS_DIR))?;
    skills_installed.extend(install_builtin_skills(Path::new(CLAUDE_SKILLS_DIR))?);
    let mut instructions = Vec::new();
    for instruction_file in INSTRUCTION_FILES {
        let status = ensure_instruction_block(Path::new(instruction_file))?;
        instructions.push((*instruction_file, status));
    }
    Ok(InitSummary {
        already_initialized,
        skills_installed,
        instructions,
    })
}

/// Rejects an `init` when the store path exists but is not a directory, so
/// the user gets an actionable message instead of a raw `File exists` errno.
fn check_store_dir_conflict(store_dir: &Path) -> io::Result<()> {
    if !store_dir.is_dir() && store_dir.symlink_metadata().is_ok() {
        return Err(io::Error::other(format!(
            "{} exists but is not a directory; remove or rename it, then re-run 'agent-store init'",
            store_dir.display()
        )));
    }
    Ok(())
}

/// Reports a runtime error and exits with `exit_code`. In `--json` mode the
/// message is wrapped in a `{"error":"..."}` envelope; either way it goes to
/// stderr, so stdout stays data-only in both output modes. Usage/parse errors
/// (exit 2 from argument parsing) stay plain-text because they can occur
/// before `--json` is known.
fn fail(json_output: bool, exit_code: i32, message: String) -> ! {
    if json_output {
        eprintln!("{}", error_json(&message));
    } else {
        eprintln!("error: {message}");
    }
    process::exit(exit_code);
}

fn open_store_or_exit(json_output: bool) -> Store {
    match Store::open_project() {
        Ok(store) => store,
        Err(error @ (StoreError::NotInitialized | StoreError::StoreDirConflict(_))) => {
            fail(json_output, 1, format!("{error}"));
        }
        Err(error) => {
            fail(json_output, 1, format!("failed to open store: {error}"));
        }
    }
}

/// Runs matching hooks for a committed mutation, exiting 1 with a stderr
/// report when one fails. Callers must print the mutation's normal stdout
/// output (the record ID, or the JSON envelope) before calling this, so a
/// failing hook never hides the committed result from stdout consumers.
fn run_hooks_or_exit(
    json_output: bool,
    store: &mut Store,
    event_type: &str,
    record: &Record,
    link_context: Option<&[LinkEdge]>,
    field_changes: &[FieldChange],
) {
    if let Err(error) = run_matching_hooks_after_commit(
        store,
        event_type,
        record,
        None,
        link_context,
        field_changes,
    ) {
        fail(json_output, 1, format!("failed to run hooks after Store mutation already committed for {event_type} {}: {error}", record.id));
    }
}

fn run_link_hooks_or_exit(
    json_output: bool,
    store: &mut Store,
    event_type: &str,
    record: &Record,
    link: &Link,
    link_context: &[LinkEdge],
) {
    if let Err(error) = run_matching_hooks_after_commit(
        store,
        event_type,
        record,
        Some(link),
        Some(link_context),
        &[],
    ) {
        fail(json_output, 1, format!("failed to run hooks after Store mutation already committed for {event_type} {}: {error}", record.id));
    }
}

fn run_matching_hooks_after_commit(
    store: &mut Store,
    event_type: &str,
    record: &Record,
    link: Option<&Link>,
    link_context: Option<&[LinkEdge]>,
    field_changes: &[FieldChange],
) -> Result<(), String> {
    let project_root = store.project_root().to_path_buf();
    let hooks = store
        .list_hooks()
        .map_err(|error| format!("failed to list hooks: {error}"))?;
    let mut matching = hooks
        .into_iter()
        .filter(|hook| hook.event == event_type)
        .peekable();

    let depth = current_hook_depth();
    if depth >= MAX_HOOK_DEPTH {
        if matching.peek().is_some() {
            eprintln!(
                "note: skipped hook dispatch for {event_type} {}: hook depth {depth} reached the recursion cap of {MAX_HOOK_DEPTH}",
                record.id
            );
        }
        return Ok(());
    }

    for hook in matching {
        if !hook_query_matches(store, event_type, &hook, record, link_context)? {
            continue;
        }

        let stdin_payload = format!("{}\n", format_record(record));
        let env_vars = hook_env_vars(event_type, record, link, field_changes);
        let output = run_hook_command(
            &hook,
            &stdin_payload,
            &project_root,
            DEFAULT_HOOK_TIMEOUT,
            &env_vars,
        )?;
        let exit_status = if output.timed_out {
            HOOK_TIMEOUT_EXIT_STATUS
        } else {
            hook_exit_status(&output.status)
        };
        let stdout_summary = String::from_utf8_lossy(&output.stdout).into_owned();
        let hook_stderr_summary = String::from_utf8_lossy(&output.stderr).into_owned();
        let mut stderr_summary = hook_stderr_summary.clone();
        if output.timed_out {
            let timeout_summary =
                format!("timed out after {} seconds", DEFAULT_HOOK_TIMEOUT.as_secs());
            if stderr_summary.is_empty() {
                stderr_summary = timeout_summary;
            } else {
                stderr_summary.push_str("; ");
                stderr_summary.push_str(&timeout_summary);
            }
        }

        store
            .record_hook_run(
                &hook.id,
                event_type,
                &record.id,
                exit_status,
                &stdout_summary,
                &stderr_summary,
            )
            .map_err(|error| format!("failed to record hook {} run: {error}", hook.id))?;

        if output.timed_out {
            let stderr_detail = if hook_stderr_summary.is_empty() {
                String::new()
            } else {
                format!("; stderr: {hook_stderr_summary}")
            };
            return Err(format!(
                "hook {} command '{}' timed out after {} seconds{}",
                hook.id,
                hook.command,
                DEFAULT_HOOK_TIMEOUT.as_secs(),
                stderr_detail
            ));
        }

        if !output.status.success() {
            let status_detail = hook_status_detail(&output.status, exit_status);
            return Err(format!(
                "hook {} command '{}' failed with {}; stderr: {}",
                hook.id, hook.command, status_detail, stderr_summary
            ));
        }
    }

    Ok(())
}

/// Current hook/schedule nesting depth, read from the environment. Zero when
/// unset or unparsable (i.e. a top-level invocation).
fn current_hook_depth() -> usize {
    env::var(HOOK_DEPTH_ENV)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(0)
}

fn hook_exit_status(status: &process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }

    #[cfg(unix)]
    {
        if let Some(signal) = status.signal() {
            return -signal;
        }
    }

    1
}

fn hook_status_detail(status: &process::ExitStatus, exit_status: i32) -> String {
    if let Some(code) = status.code() {
        return format!("exit status {code}");
    }

    #[cfg(unix)]
    {
        if let Some(signal) = status.signal() {
            if let Some(name) = unix_signal_name(signal) {
                return format!("terminated by signal {signal} ({name})");
            }
            return format!("terminated by signal {signal}");
        }
    }

    format!("exit status {exit_status}")
}

#[cfg(unix)]
fn unix_signal_name(signal: i32) -> Option<&'static str> {
    match signal {
        libc::SIGHUP => Some("SIGHUP"),
        libc::SIGINT => Some("SIGINT"),
        libc::SIGQUIT => Some("SIGQUIT"),
        libc::SIGABRT => Some("SIGABRT"),
        libc::SIGKILL => Some("SIGKILL"),
        libc::SIGTERM => Some("SIGTERM"),
        _ => None,
    }
}

struct HookCommandOutput {
    status: process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    timed_out: bool,
}

fn run_hook_command(
    hook: &Hook,
    stdin_payload: &str,
    project_root: &Path,
    timeout: Duration,
    env_vars: &[(&'static str, String)],
) -> Result<HookCommandOutput, String> {
    let mut command = Command::new("bash");
    command
        .arg("-c")
        .arg(&hook.command)
        .current_dir(project_root)
        .stdin(process::Stdio::piped())
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::piped());
    for key in HOOK_ENV_KEYS {
        command.env_remove(key);
    }
    for (key, value) in env_vars {
        command.env(key, value);
    }
    command.env(HOOK_DEPTH_ENV, (current_hook_depth() + 1).to_string());

    #[cfg(unix)]
    command.process_group(0);

    let mut child = command
        .spawn()
        .map_err(|error| format!("hook {} failed to start: {error}", hook.id))?;
    let stdout_reader = child
        .stdout
        .take()
        .map(read_hook_pipe)
        .ok_or_else(|| format!("hook {} stdout pipe unavailable", hook.id))?;
    let stderr_reader = child
        .stderr
        .take()
        .map(read_hook_pipe)
        .ok_or_else(|| format!("hook {} stderr pipe unavailable", hook.id))?;

    {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| format!("hook {} stdin pipe unavailable", hook.id))?;
        if let Err(error) = stdin.write_all(stdin_payload.as_bytes()) {
            if error.kind() != io::ErrorKind::BrokenPipe {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("hook {} stdin write failed: {error}", hook.id));
            }
        }
    }

    let timed_out = wait_for_child_timeout(&mut child, timeout)
        .map_err(|error| format!("hook {} failed while waiting: {error}", hook.id))?;
    if timed_out {
        terminate_hook_child(&mut child);
    }

    let status = child
        .wait()
        .map_err(|error| format!("hook {} failed while waiting: {error}", hook.id))?;
    let stdout = join_hook_pipe_reader(hook, "stdout", stdout_reader)?;
    let stderr = join_hook_pipe_reader(hook, "stderr", stderr_reader)?;

    Ok(HookCommandOutput {
        status,
        stdout,
        stderr,
        timed_out,
    })
}

fn hook_env_vars(
    event_type: &str,
    record: &Record,
    link: Option<&Link>,
    field_changes: &[FieldChange],
) -> Vec<(&'static str, String)> {
    let mut env_vars = vec![
        ("AGENT_STORE_EVENT", event_type.to_owned()),
        ("AGENT_STORE_ID", record.id.clone()),
        ("AGENT_STORE_KIND", record.kind.clone()),
    ];
    if let Some(link) = link {
        env_vars.push(("AGENT_STORE_REL", link.rel.clone()));
        env_vars.push(("AGENT_STORE_TARGET_ID", link.to_record_id.clone()));
    }
    if let [field_change] = field_changes {
        let value = field_change
            .new_value
            .as_ref()
            .or(field_change.old_value.as_ref())
            .cloned()
            .unwrap_or_default();
        env_vars.push(("AGENT_STORE_FIELD", field_change.key.clone()));
        env_vars.push(("AGENT_STORE_KEY", field_change.key.clone()));
        env_vars.push(("AGENT_STORE_VALUE", value));
        env_vars.push((
            "AGENT_STORE_OLD_VALUE",
            field_change.old_value.clone().unwrap_or_default(),
        ));
        env_vars.push((
            "AGENT_STORE_NEW_VALUE",
            field_change.new_value.clone().unwrap_or_default(),
        ));
    }
    env_vars
}

fn read_hook_pipe<R>(mut pipe: R) -> thread::JoinHandle<io::Result<Vec<u8>>>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut output = Vec::new();
        let mut buffer = [0_u8; 4096];
        loop {
            let read = pipe.read(&mut buffer)?;
            if read == 0 {
                break;
            }

            let remaining = HOOK_OUTPUT_CAPTURE_LIMIT_BYTES.saturating_sub(output.len());
            if remaining > 0 {
                output.extend_from_slice(&buffer[..read.min(remaining)]);
            }
        }
        Ok(output)
    })
}

fn join_hook_pipe_reader(
    hook: &Hook,
    stream_name: &str,
    reader: thread::JoinHandle<io::Result<Vec<u8>>>,
) -> Result<Vec<u8>, String> {
    reader
        .join()
        .map_err(|_| format!("hook {} {stream_name} reader panicked", hook.id))?
        .map_err(|error| format!("hook {} failed reading {stream_name}: {error}", hook.id))
}

fn wait_for_child_timeout(child: &mut process::Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;

    loop {
        if child.try_wait()?.is_some() {
            return Ok(false);
        }

        let now = Instant::now();
        if now >= deadline {
            return Ok(true);
        }

        thread::sleep((deadline - now).min(Duration::from_millis(20)));
    }
}

fn terminate_hook_child(child: &mut process::Child) {
    #[cfg(unix)]
    {
        let process_group = -(child.id() as libc::pid_t);
        // Hooks run as their own process group so a timed-out shell does not
        // leave child commands alive with inherited stdout/stderr pipes.
        unsafe {
            libc::kill(process_group, libc::SIGTERM);
        }
        thread::sleep(Duration::from_millis(100));
        unsafe {
            libc::kill(process_group, libc::SIGKILL);
        }
    }

    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}

fn hook_query_matches(
    store: &Store,
    event_type: &str,
    hook: &Hook,
    record: &Record,
    link_context: Option<&[LinkEdge]>,
) -> Result<bool, String> {
    let Some(query_text) = hook.query.as_deref() else {
        return Ok(true);
    };

    let query = Query::parse(query_text)
        .map_err(|error| format!("hook {} has invalid query: {error}", hook.id))?;
    if !query.uses_links() {
        return Ok(query.matches(record));
    }

    let live_links;
    let links = if let Some(link_context) = link_context {
        link_context
    } else if event_type == "rm" {
        &[][..]
    } else {
        live_links = store
            .links_for_record(&record.id)
            .map_err(|error| format!("failed to load hook {} link context: {error}", hook.id))?
            .links;
        &live_links
    };

    Ok(query.matches_with_links(record, links))
}

fn ensure_gitignore_rule(path: &Path, rule: &str) -> io::Result<()> {
    let existing = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error),
    };

    if existing.lines().any(|line| line == rule) {
        return Ok(());
    }

    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    if !existing.is_empty() && !existing.ends_with('\n') {
        writeln!(file)?;
    }
    writeln!(file, "{rule}")?;
    Ok(())
}

fn install_builtin_skills(root: &Path) -> io::Result<Vec<String>> {
    let mut installed = Vec::new();
    for skill in BUILTIN_SKILLS {
        let skill_dir = root.join(skill.name);
        fs::create_dir_all(&skill_dir)?;
        let skill_path = skill_dir.join("SKILL.md");
        if write_file_if_absent(&skill_path, skill.content)? {
            installed.push(skill_path.display().to_string());
        }
    }
    Ok(installed)
}

fn write_file_if_absent(path: &Path, contents: &str) -> io::Result<bool> {
    match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => file.write_all(contents.as_bytes()).map(|()| true),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err(error) => Err(error),
    }
}

fn ensure_instruction_block(path: &Path) -> io::Result<InstructionStatus> {
    let existing = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(InstructionStatus::Missing)
        }
        Err(error) => return Err(error),
    };

    if existing.contains(INSTRUCTIONS_START) {
        return Ok(InstructionStatus::Present);
    }

    let mut file = OpenOptions::new().append(true).open(path)?;
    if !existing.is_empty() && !existing.ends_with('\n') {
        writeln!(file)?;
    }
    if !existing.is_empty() {
        writeln!(file)?;
    }
    write!(file, "{INSTRUCTIONS_BLOCK}")?;
    Ok(InstructionStatus::Added)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();
        let path = env::temp_dir().join(format!("agent-store-{name}-{}-{unique}", process::id()));
        fs::create_dir_all(&path).expect("test temp dir should be created");
        path
    }

    #[test]
    fn init_rejects_store_path_that_is_a_file() {
        let root = temp_dir("store-conflict");
        let store_path = root.join(STORE_DIR);
        fs::write(&store_path, "not a directory").expect("conflict file should be written");

        let error =
            check_store_dir_conflict(&store_path).expect_err("file at store path should fail");
        let message = error.to_string();
        assert!(
            message.contains("exists but is not a directory"),
            "{message}"
        );
        assert!(message.contains("agent-store init"), "{message}");

        fs::remove_file(&store_path).expect("conflict file should be removed");
        check_store_dir_conflict(&store_path).expect("absent store path is not a conflict");
        fs::create_dir(&store_path).expect("store dir should be created");
        check_store_dir_conflict(&store_path).expect("existing store dir is not a conflict");

        fs::remove_dir_all(root).expect("test temp dir should be removed");
    }

    #[test]
    fn builtin_skill_install_preserves_existing_files() {
        let root = temp_dir("skills");
        let skills_root = root.join(".agents/skills");
        let custom_skill = skills_root.join("agent-store/SKILL.md");
        fs::create_dir_all(custom_skill.parent().expect("custom skill parent"))
            .expect("custom skill dir should be created");
        fs::write(&custom_skill, "custom skill\n").expect("custom skill should be written");

        let installed = install_builtin_skills(&skills_root).expect("skills should install");

        // The pre-existing skill file is preserved and not reported as installed.
        assert_eq!(installed.len(), BUILTIN_SKILLS.len() - 1);
        assert!(!installed
            .iter()
            .any(|path| path.ends_with("agent-store/SKILL.md")));
        assert_eq!(
            fs::read_to_string(&custom_skill).expect("custom skill should remain readable"),
            "custom skill\n"
        );
        assert!(skills_root.join("agent-store-patterns/SKILL.md").is_file());
        assert!(skills_root.join("agent-store-pipelines/SKILL.md").is_file());

        fs::remove_dir_all(root).expect("test temp dir should be removed");
    }

    #[test]
    fn instruction_block_is_appended_once_to_existing_files() {
        let root = temp_dir("instructions");
        let agents = root.join("AGENTS.md");
        fs::write(&agents, "user-authored line").expect("instructions file should be written");

        let first = ensure_instruction_block(&agents).expect("instruction block should append");
        let second =
            ensure_instruction_block(&agents).expect("instruction block should not duplicate");
        assert_eq!(first, InstructionStatus::Added);
        assert_eq!(second, InstructionStatus::Present);

        let contents = fs::read_to_string(&agents).expect("instructions should be readable");
        assert!(contents.contains("user-authored line"));
        assert_eq!(contents.matches(INSTRUCTIONS_START).count(), 1);
        assert!(contents.contains("agent-store init"));

        fs::remove_dir_all(root).expect("test temp dir should be removed");
    }

    #[test]
    fn instruction_block_does_not_create_missing_files() {
        let root = temp_dir("missing-instructions");
        let missing = root.join("CLAUDE.md");

        let status = ensure_instruction_block(&missing).expect("missing instructions are skipped");

        assert_eq!(status, InstructionStatus::Missing);
        assert!(!missing.exists());

        fs::remove_dir_all(root).expect("test temp dir should be removed");
    }
}
