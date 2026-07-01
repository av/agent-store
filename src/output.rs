use crate::cli::HelpTopic;
use agent_store::store::{Hook, Link, LinkEdge, QuickContextSummary, Record};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub const QUICK_CONTEXT_OUTPUT_LIMIT_BYTES: usize = 8192;

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

Quick Context output is capped at 8192 bytes.
Hook stdout and stderr captures are capped at 8192 bytes each.
";

const INIT_USAGE: &str = "\
Usage: agent-store init

Initialize the project-local store, install builtin skills, and add managed
agent-store instructions to existing AGENTS.md and CLAUDE.md files.
";

const CREATE_USAGE: &str = "\
Usage: agent-store create <kind> [key=value...]
       agent-store cr <kind> [key=value...]

Create a Record with the supplied kind and fields, then print its Record ID.
";

const GET_USAGE: &str = "\
Usage: agent-store get <ID>

Print one Record resolved from an unambiguous Record ID prefix.
";

const FIND_USAGE: &str = "\
Usage: agent-store find <Query>
       agent-store ls <Query>

Find Records by query. Query arguments may be quoted as one shell argument or
passed as multiple arguments that are joined with spaces.
";

const SET_USAGE: &str = "\
Usage: agent-store set <ID> key=value...

Resolve a Record ID prefix and update the supplied fields atomically.
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
";

const HOOK_USAGE: &str = "\
Usage: agent-store hook <COMMAND>

Manage stored hooks.

Commands:
  add           Add a Hook
  ls            List Hooks
  rm            Remove a Hook by ID
";

const HOOK_ADD_USAGE: &str = "\
Usage: agent-store hook add <event> [<Query>] -- <bash command>

Store a Hook for create, set, unset, rm, link, or unlink. When a Query is
provided, the Hook runs only for matching Records.
";

const HOOK_LIST_USAGE: &str = "\
Usage: agent-store hook ls

Print stored Hooks in deterministic order.
";

const HOOK_REMOVE_USAGE: &str = "\
Usage: agent-store hook rm <ID>

Resolve a Hook ID prefix and remove that Hook.
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
    }
}

pub fn print_json(value: Value) {
    outln!("{value}");
}

pub fn init_json() -> Value {
    json!({
        "status": "initialized",
        "store_dir": agent_store::store::STORE_DIR,
    })
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

pub fn quick_context_json(summary: &QuickContextSummary) -> Value {
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
        "latest_activity_at": &summary.latest_activity_at,
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
    lines.push(format!(
        "Latest activity: {}",
        summary.latest_activity_at.as_deref().unwrap_or("none")
    ));
    cap_quick_context_output(lines.join("\n"))
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

fn is_shell_safe_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'/' | b':' | b'@' | b'%')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_output_is_stable_and_shell_quoted() {
        let record = Record {
            id: "abc123".to_owned(),
            kind: "note".to_owned(),
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
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote_value("can't"), "'can'\"'\"'t'");
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
            latest_activity_at: Some("2026-06-26T12:34:56.789Z".to_owned()),
        };

        assert_eq!(
            format_quick_context(&summary),
            "Quick Context\nRecords: 3\nRecord kinds:\n  note: 1\n    fields: title\n  task: 2\n    fields: due, status, title\n    status: open=2\n    due: 2026-06-26..2026-06-30\nLinks: 3\n  blocks: 2\n  depends_on: 1\nHooks: 1\nLatest activity: 2026-06-26T12:34:56.789Z"
        );
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
            latest_activity_at: None,
        };

        let output = format_quick_context(&summary);

        assert!(output.len() <= QUICK_CONTEXT_OUTPUT_LIMIT_BYTES);
        assert!(output.ends_with("... truncated at 8192 bytes"));
    }
}
