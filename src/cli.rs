use agent_store::query::Query;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cli {
    pub json_output: bool,
    pub command: CliCommand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelpTopic {
    Top,
    Init,
    Create,
    Get,
    Find,
    Set,
    Unset,
    Rm,
    Link,
    Unlink,
    Links,
    Context,
    Hook,
    HookAdd,
    HookList,
    HookRemove,
    HookRuns,
    Schedule,
    ScheduleAdd,
    ScheduleList,
    ScheduleRemove,
    ScheduleRuns,
    ScheduleTick,
    ScheduleEnable,
    ScheduleDisable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliCommand {
    Help {
        topic: HelpTopic,
    },
    Version,
    Init,
    Create {
        kind: String,
        fields: BTreeMap<String, String>,
    },
    CreateStdin,
    Get {
        id: String,
        timestamps: bool,
    },
    Find {
        query: Option<String>,
        timestamps: bool,
        sort: Option<String>,
        desc: bool,
        limit: Option<usize>,
        count: bool,
    },
    Set {
        id: String,
        fields: BTreeMap<String, String>,
    },
    Unset {
        id: String,
        keys: Vec<String>,
    },
    Rm {
        id: String,
    },
    Link {
        from: String,
        rel: String,
        to: String,
    },
    Unlink {
        from: String,
        rel: String,
        to: String,
    },
    Links {
        id: String,
    },
    Context,
    Hook(HookCliCommand),
    Schedule(ScheduleCliCommand),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookCliCommand {
    Add {
        event: String,
        query: Option<String>,
        command: String,
    },
    List,
    Remove {
        id: String,
    },
    Runs {
        limit: usize,
        run_id: Option<i64>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScheduleCliCommand {
    Add {
        kind: String,
        expression: String,
        query: Option<String>,
        command: String,
    },
    List,
    Remove {
        id: String,
    },
    Runs {
        limit: usize,
        run_id: Option<i64>,
    },
    Tick,
    Enable,
    Disable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliParseError {
    message: String,
    include_usage: bool,
}

impl CliParseError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            include_usage: false,
        }
    }

    fn with_usage(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            include_usage: true,
        }
    }

    pub fn include_usage(&self) -> bool {
        self.include_usage
    }
}

impl fmt::Display for CliParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl Error for CliParseError {}

pub fn parse_args(args: impl IntoIterator<Item = String>) -> Result<Cli, CliParseError> {
    let mut raw_args: Vec<String> = args.into_iter().collect();
    let json_output = take_json_flag(&mut raw_args);
    let mut args = raw_args.into_iter();

    let command = match args.next() {
        Some(command) => parse_command(command, args)?,
        None => return Err(CliParseError::with_usage("missing command")),
    };

    Ok(Cli {
        json_output,
        command,
    })
}

fn parse_command(
    command: String,
    args: impl Iterator<Item = String>,
) -> Result<CliCommand, CliParseError> {
    let args = args.collect::<Vec<_>>();

    match command.as_str() {
        "-h" | "--help" => Ok(help_command(HelpTopic::Top)),
        "-V" | "--version" => Ok(CliCommand::Version),
        "init" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Init));
            }
            let mut args = args.into_iter();
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "init does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Init)
        }
        "create" | "cr" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Create));
            }
            let mut args = args;
            let stdin = take_bool_flag(&mut args, "--stdin");
            if stdin {
                if let Some(extra) = args.first() {
                    return Err(CliParseError::new(format!(
                        "create --stdin does not accept positional argument '{extra}'"
                    )));
                }
                return Ok(CliCommand::CreateStdin);
            }
            let mut args = args.into_iter();
            let kind = args
                .next()
                .ok_or_else(|| CliParseError::new("create requires a kind"))?;
            validate_kind(&kind)?;
            let fields = parse_fields(args)?;
            Ok(CliCommand::Create { kind, fields })
        }
        "get" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Get));
            }
            let mut args = args;
            let timestamps = take_timestamps_flag(&mut args);
            reject_unknown_flags("get", &args)?;
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("get requires a record ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "get does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Get { id, timestamps })
        }
        "find" | "ls" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Find));
            }
            let mut args = args;
            let timestamps = take_timestamps_flag(&mut args);
            let desc = take_bool_flag(&mut args, "--desc");
            let count = take_bool_flag(&mut args, "--count");
            let sort = take_value_flag(&mut args, "--sort")?;
            if let Some(field) = &sort {
                if field.is_empty() || has_unsupported_identifier_chars(field) {
                    return Err(CliParseError::new(format!(
                        "invalid --sort field '{field}'"
                    )));
                }
            }
            let limit = match take_value_flag(&mut args, "--limit")? {
                Some(value) => Some(value.parse::<usize>().map_err(|_| {
                    CliParseError::new(format!(
                        "invalid --limit value '{value}': expected a non-negative number"
                    ))
                })?),
                None => None,
            };
            reject_unknown_flags(&command, &args)?;
            let query = join_query_args(&args);
            Ok(CliCommand::Find {
                query,
                timestamps,
                sort,
                desc,
                limit,
                count,
            })
        }
        "set" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Set));
            }
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("set requires a record ID"))?;
            let fields = parse_fields(args)?;
            if fields.is_empty() {
                return Err(CliParseError::new(
                    "set requires at least one key=value field",
                ));
            }
            Ok(CliCommand::Set { id, fields })
        }
        "unset" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Unset));
            }
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("unset requires a record ID"))?;
            let keys = parse_field_keys(args)?;
            if keys.is_empty() {
                return Err(CliParseError::new("unset requires at least one field name"));
            }
            Ok(CliCommand::Unset { id, keys })
        }
        "rm" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Rm));
            }
            reject_unknown_flags("rm", &args)?;
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("rm requires a record ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "rm does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Rm { id })
        }
        "link" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Link));
            }
            let (from, rel, to) = parse_link_args(args.into_iter(), "link")?;
            Ok(CliCommand::Link { from, rel, to })
        }
        "unlink" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Unlink));
            }
            let (from, rel, to) = parse_link_args(args.into_iter(), "unlink")?;
            Ok(CliCommand::Unlink { from, rel, to })
        }
        "links" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Links));
            }
            reject_unknown_flags("links", &args)?;
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("links requires a record ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "links does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Links { id })
        }
        "ctx" | "context" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Context));
            }
            let mut args = args.into_iter();
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "{command} does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Context)
        }
        "hook" => parse_hook_command(args),
        "schedule" => parse_schedule_command(args),
        _ => Err(CliParseError::with_usage(format!(
            "unrecognized command '{command}'{}",
            did_you_mean(&command, COMMANDS)
        ))),
    }
}

fn parse_hook_command(args: Vec<String>) -> Result<CliCommand, CliParseError> {
    match args.first().map(String::as_str) {
        Some(command) if is_help_arg(command) => Ok(help_command(HelpTopic::Hook)),
        Some("add") => {
            if hook_add_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::HookAdd));
            }
            let (event, query, command) = parse_hook_add_args(args.into_iter().skip(1))?;
            Ok(CliCommand::Hook(HookCliCommand::Add {
                event,
                query,
                command,
            }))
        }
        Some("ls") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::HookList));
            }
            let mut args = args.into_iter().skip(1);
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "hook ls does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Hook(HookCliCommand::List))
        }
        Some("rm") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::HookRemove));
            }
            let mut args = args.into_iter().skip(1);
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("hook rm requires a hook ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "hook rm does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Hook(HookCliCommand::Remove { id }))
        }
        Some("runs") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::HookRuns));
            }
            parse_hook_runs_args(args.into_iter().skip(1))
        }
        Some(command) => Err(CliParseError::new(format!(
            "unrecognized hook command '{command}'{}",
            did_you_mean(command, HOOK_COMMANDS)
        ))),
        None => Err(CliParseError::new("hook requires add, ls, rm, or runs")),
    }
}

const DEFAULT_HOOK_RUNS_LIMIT: usize = 20;

fn parse_hook_runs_args(args: impl Iterator<Item = String>) -> Result<CliCommand, CliParseError> {
    let mut args = args.peekable();
    let mut limit = DEFAULT_HOOK_RUNS_LIMIT;
    let mut run_id = None;

    while let Some(arg) = args.next() {
        if arg == "--limit" {
            let value = args
                .next()
                .ok_or_else(|| CliParseError::new("hook runs --limit requires a number"))?;
            limit = value.parse::<usize>().map_err(|_| {
                CliParseError::new(format!("invalid hook runs --limit value '{value}'"))
            })?;
            if limit == 0 {
                return Err(CliParseError::new(
                    "hook runs --limit requires a positive number",
                ));
            }
        } else if run_id.is_none() && !arg.starts_with('-') {
            run_id = Some(arg.parse::<i64>().map_err(|_| {
                CliParseError::new(format!("invalid hook run ID '{arg}': expected a number"))
            })?);
        } else {
            return Err(CliParseError::new(format!(
                "hook runs does not accept argument '{arg}'"
            )));
        }
    }

    Ok(CliCommand::Hook(HookCliCommand::Runs { limit, run_id }))
}

fn parse_schedule_command(args: Vec<String>) -> Result<CliCommand, CliParseError> {
    match args.first().map(String::as_str) {
        Some(command) if is_help_arg(command) => Ok(help_command(HelpTopic::Schedule)),
        Some("add") => {
            if schedule_add_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleAdd));
            }
            parse_schedule_add_args(args.into_iter().skip(1))
        }
        Some("ls") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleList));
            }
            let mut args = args.into_iter().skip(1);
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "schedule ls does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Schedule(ScheduleCliCommand::List))
        }
        Some("rm") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleRemove));
            }
            let mut args = args.into_iter().skip(1);
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("schedule rm requires a schedule ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "schedule rm does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Schedule(ScheduleCliCommand::Remove { id }))
        }
        Some("runs") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleRuns));
            }
            parse_schedule_runs_args(args.into_iter().skip(1))
        }
        Some("tick") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleTick));
            }
            let mut args = args.into_iter().skip(1);
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "schedule tick does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Schedule(ScheduleCliCommand::Tick))
        }
        Some("enable") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleEnable));
            }
            let mut args = args.into_iter().skip(1);
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "schedule enable does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Schedule(ScheduleCliCommand::Enable))
        }
        Some("disable") => {
            if command_help_requested(&args[1..]) {
                return Ok(help_command(HelpTopic::ScheduleDisable));
            }
            let mut args = args.into_iter().skip(1);
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "schedule disable does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Schedule(ScheduleCliCommand::Disable))
        }
        Some(command) => Err(CliParseError::new(format!(
            "unrecognized schedule command '{command}'{}",
            did_you_mean(command, SCHEDULE_COMMANDS)
        ))),
        None => Err(CliParseError::new(
            "schedule requires add, ls, rm, runs, tick, enable, or disable",
        )),
    }
}

fn parse_schedule_add_args(
    args: impl Iterator<Item = String>,
) -> Result<CliCommand, CliParseError> {
    let args = args.collect::<Vec<_>>();
    let Some(kind) = args.first() else {
        return Err(CliParseError::new(
            "schedule add requires at or every",
        ));
    };
    match kind.as_str() {
        "at" | "every" => {}
        _ => {
            return Err(CliParseError::new(format!(
                "schedule add requires at or every, got '{kind}'"
            )));
        }
    }

    let rest = &args[1..];
    let Some(expression) = rest.first() else {
        return Err(CliParseError::new(format!(
            "schedule add {kind} requires a time expression"
        )));
    };

    let Some(separator) = rest.iter().position(|arg| arg == "--") else {
        return Err(CliParseError::new(
            "schedule add requires [<Query>] -- <bash command>",
        ));
    };

    let between = &rest[1..separator];
    let after_separator = &rest[separator + 1..];
    if after_separator.is_empty() {
        return Err(CliParseError::new(
            "schedule add requires a bash command after --",
        ));
    }

    let query = if between.is_empty() {
        None
    } else {
        let query_text = between.join(" ");
        Query::parse(&query_text)
            .map_err(|error| CliParseError::new(format!("invalid schedule query: {error}")))?;
        Some(query_text)
    };

    let command = after_separator.join(" ");
    if command.trim().is_empty() {
        return Err(CliParseError::new(
            "schedule add requires a non-empty bash command after --",
        ));
    }

    Ok(CliCommand::Schedule(ScheduleCliCommand::Add {
        kind: kind.clone(),
        expression: expression.clone(),
        query,
        command,
    }))
}

const DEFAULT_SCHEDULE_RUNS_LIMIT: usize = 20;

fn parse_schedule_runs_args(
    args: impl Iterator<Item = String>,
) -> Result<CliCommand, CliParseError> {
    let mut args = args.peekable();
    let mut limit = DEFAULT_SCHEDULE_RUNS_LIMIT;
    let mut run_id = None;

    while let Some(arg) = args.next() {
        if arg == "--limit" {
            let value = args
                .next()
                .ok_or_else(|| CliParseError::new("schedule runs --limit requires a number"))?;
            limit = value.parse::<usize>().map_err(|_| {
                CliParseError::new(format!("invalid schedule runs --limit value '{value}'"))
            })?;
            if limit == 0 {
                return Err(CliParseError::new(
                    "schedule runs --limit requires a positive number",
                ));
            }
        } else if run_id.is_none() && !arg.starts_with('-') {
            run_id = Some(arg.parse::<i64>().map_err(|_| {
                CliParseError::new(format!(
                    "invalid schedule run ID '{arg}': expected a number"
                ))
            })?);
        } else {
            return Err(CliParseError::new(format!(
                "schedule runs does not accept argument '{arg}'"
            )));
        }
    }

    Ok(CliCommand::Schedule(ScheduleCliCommand::Runs {
        limit,
        run_id,
    }))
}

fn schedule_add_help_requested(args: &[String]) -> bool {
    for arg in args {
        if arg == "--" {
            return false;
        }
        if is_help_arg(arg) {
            return true;
        }
    }
    false
}

/// Top-level command names and aliases, used for typo suggestions.
const COMMANDS: &[&str] = &[
    "init", "create", "cr", "get", "find", "ls", "set", "unset", "rm", "link", "unlink", "links",
    "ctx", "context", "hook", "schedule",
];

/// Hook subcommand names, used for typo suggestions.
const HOOK_COMMANDS: &[&str] = &["add", "ls", "rm", "runs"];

/// Schedule subcommand names, used for typo suggestions.
const SCHEDULE_COMMANDS: &[&str] = &["add", "ls", "rm", "runs", "tick", "enable", "disable"];

/// Returns a " (did you mean '<command>'?)" suffix when `input` is within
/// edit distance 2 of a known command, and an empty string otherwise. The
/// distance is also required to be smaller than the input length so that
/// short garbage (e.g. "x") does not suggest unrelated short commands.
fn did_you_mean(input: &str, candidates: &[&str]) -> String {
    let input = input.to_ascii_lowercase();
    candidates
        .iter()
        .map(|candidate| (levenshtein(&input, candidate), candidate))
        .filter(|(distance, _)| *distance <= 2 && *distance < input.chars().count())
        .min_by_key(|(distance, _)| *distance)
        .map(|(_, candidate)| format!(" (did you mean '{candidate}'?)"))
        .unwrap_or_default()
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut previous: Vec<usize> = (0..=b.len()).collect();

    for (row, a_char) in a.iter().enumerate() {
        let mut current = vec![row + 1];
        for (column, b_char) in b.iter().enumerate() {
            let substitution = previous[column] + usize::from(a_char != b_char);
            let insertion = current[column] + 1;
            let deletion = previous[column + 1] + 1;
            current.push(substitution.min(insertion).min(deletion));
        }
        previous = current;
    }

    previous[b.len()]
}

fn help_command(topic: HelpTopic) -> CliCommand {
    CliCommand::Help { topic }
}

fn is_help_arg(arg: &str) -> bool {
    matches!(arg, "-h" | "--help")
}

fn command_help_requested(args: &[String]) -> bool {
    args.iter().any(|arg| is_help_arg(arg))
}

fn hook_add_help_requested(args: &[String]) -> bool {
    for arg in args {
        if arg == "--" {
            return false;
        }
        if is_help_arg(arg) {
            return true;
        }
    }

    false
}

/// Rejects leftover `--flag` arguments after a command's known flags have
/// been consumed, so an unknown flag reports itself instead of falling
/// through to positional parsing (e.g. the find query parser).
fn reject_unknown_flags(command: &str, args: &[String]) -> Result<(), CliParseError> {
    if let Some(flag) = args.iter().find(|arg| arg.starts_with("--")) {
        return Err(CliParseError::new(format!(
            "unknown flag '{flag}' for {command}; see 'agent-store {command} --help'"
        )));
    }
    Ok(())
}

fn take_timestamps_flag(args: &mut Vec<String>) -> bool {
    let mut timestamps = false;
    args.retain(|arg| {
        if arg == "--timestamps" {
            timestamps = true;
            false
        } else {
            true
        }
    });
    timestamps
}

fn take_bool_flag(args: &mut Vec<String>, flag: &str) -> bool {
    let mut present = false;
    args.retain(|arg| {
        if arg == flag {
            present = true;
            false
        } else {
            true
        }
    });
    present
}

fn take_value_flag(args: &mut Vec<String>, flag: &str) -> Result<Option<String>, CliParseError> {
    let Some(position) = args.iter().position(|arg| arg == flag) else {
        return Ok(None);
    };
    if position + 1 >= args.len() {
        return Err(CliParseError::new(format!("{flag} requires a value")));
    }
    let value = args.remove(position + 1);
    args.remove(position);
    if args.iter().any(|arg| arg == flag) {
        return Err(CliParseError::new(format!("{flag} may only be given once")));
    }
    Ok(Some(value))
}

fn take_json_flag(args: &mut Vec<String>) -> bool {
    let mut json_output = false;
    args.retain(|arg| {
        if arg == "--json" {
            json_output = true;
            false
        } else {
            true
        }
    });
    json_output
}

/// Joins positional find/ls query arguments into one query string. A single
/// argument (or arguments that already form a valid query when space-joined,
/// such as an unquoted `kind=task and status=pending`) is kept as-is; when
/// the space-joined form does not parse, the arguments are retried joined
/// with an implicit `and`, so `find kind=task status=pending` means
/// `find 'kind=task and status=pending'`. When neither form parses, the
/// space-joined form is returned so the query error names the user's input.
fn join_query_args(args: &[String]) -> Option<String> {
    let space_joined = args.join(" ");
    if space_joined.trim().is_empty() {
        return None;
    }
    if args.len() > 1 && Query::parse(&space_joined).is_err() {
        let and_joined = args.join(" and ");
        if Query::parse(&and_joined).is_ok() {
            return Some(and_joined);
        }
    }
    Some(space_joined)
}

/// Rejects characters that would break line-oriented output or the query
/// grammar in kinds and field names: whitespace, control characters, quotes,
/// and `=`. Field values stay unrestricted (they are quoted on output).
fn has_unsupported_identifier_chars(value: &str) -> bool {
    value
        .chars()
        .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '=' | '\'' | '"'))
}

fn validate_kind(kind: &str) -> Result<(), CliParseError> {
    if has_unsupported_identifier_chars(kind) {
        return Err(CliParseError::new(format!(
            "kind contains unsupported characters \
             (whitespace, control characters, quotes, and '=' are not allowed): {kind:?}"
        )));
    }
    if kind == "not" {
        return Err(CliParseError::new("'not' is a reserved kind"));
    }
    Ok(())
}

fn validate_field_key(key: &str) -> Result<(), CliParseError> {
    if key.is_empty() {
        return Err(CliParseError::new("field names cannot be empty"));
    }
    if key == "kind" || key == "id" || key == "not" {
        return Err(CliParseError::new(format!(
            "'{key}' is a reserved field name"
        )));
    }
    if has_unsupported_identifier_chars(key) {
        return Err(CliParseError::new(format!(
            "field name contains unsupported characters \
             (whitespace, control characters, quotes, and '=' are not allowed): {key:?}"
        )));
    }
    Ok(())
}

fn parse_fields(
    args: impl Iterator<Item = String>,
) -> Result<BTreeMap<String, String>, CliParseError> {
    let mut fields = BTreeMap::new();

    for arg in args {
        let Some((key, value)) = arg.split_once('=') else {
            return Err(CliParseError::new(format!(
                "field argument '{arg}' must use key=value syntax"
            )));
        };
        validate_field_key(key)?;

        fields.insert(key.to_owned(), value.to_owned());
    }

    Ok(fields)
}

/// Parses one JSONL import line of the shape `{"kind": ..., "fields": {...}}`
/// into the same (kind, fields) pair argv `create <kind> key=value...` would
/// produce. Extra top-level keys (id, created_at, updated_at, ...) are
/// ignored so `find --json` exports round-trip; non-string field values
/// (numbers, booleans, null) are stored as their raw textual form, matching
/// how argv `key=value` input stores them.
pub fn parse_jsonl_record(line: &str) -> Result<(String, BTreeMap<String, String>), CliParseError> {
    let value: serde_json::Value = serde_json::from_str(line)
        .map_err(|error| CliParseError::new(format!("invalid JSON: {error}")))?;
    let object = value
        .as_object()
        .ok_or_else(|| CliParseError::new("expected a JSON object"))?;

    let kind = object
        .get("kind")
        .ok_or_else(|| CliParseError::new("missing 'kind' key"))?
        .as_str()
        .ok_or_else(|| CliParseError::new("'kind' must be a JSON string"))?;
    if kind.is_empty() {
        return Err(CliParseError::new("'kind' cannot be empty"));
    }
    validate_kind(kind)?;

    let mut fields = BTreeMap::new();
    if let Some(raw_fields) = object.get("fields") {
        let field_object = raw_fields
            .as_object()
            .ok_or_else(|| CliParseError::new("'fields' must be a JSON object"))?;
        for (key, field_value) in field_object {
            validate_field_key(key)?;
            let text = match field_value {
                serde_json::Value::String(text) => text.clone(),
                serde_json::Value::Number(number) => number.to_string(),
                serde_json::Value::Bool(boolean) => boolean.to_string(),
                serde_json::Value::Null => "null".to_owned(),
                serde_json::Value::Array(_) | serde_json::Value::Object(_) => {
                    return Err(CliParseError::new(format!(
                        "field '{key}' must be a string, number, boolean, or null"
                    )));
                }
            };
            fields.insert(key.clone(), text);
        }
    }

    Ok((kind.to_owned(), fields))
}

fn parse_field_keys(args: impl Iterator<Item = String>) -> Result<Vec<String>, CliParseError> {
    let mut keys = Vec::new();

    for arg in args {
        if arg.is_empty() {
            return Err(CliParseError::new("field names cannot be empty"));
        }
        if arg.contains('=') {
            return Err(CliParseError::new(format!(
                "field argument '{arg}' must be a field name, not key=value"
            )));
        }

        keys.push(arg);
    }

    Ok(keys)
}

fn parse_link_args(
    mut args: impl Iterator<Item = String>,
    command: &str,
) -> Result<(String, String, String), CliParseError> {
    let Some(from) = args.next() else {
        return Err(CliParseError::new(format!(
            "{command} requires <from> <rel> <to>"
        )));
    };
    let Some(rel) = args.next() else {
        return Err(CliParseError::new(format!(
            "{command} requires <from> <rel> <to>"
        )));
    };
    let Some(to) = args.next() else {
        return Err(CliParseError::new(format!(
            "{command} requires <from> <rel> <to>"
        )));
    };
    if let Some(extra) = args.next() {
        return Err(CliParseError::new(format!(
            "{command} does not accept argument '{extra}'"
        )));
    }

    Ok((from, rel, to))
}

fn parse_hook_add_args(
    args: impl Iterator<Item = String>,
) -> Result<(String, Option<String>, String), CliParseError> {
    let args = args.collect::<Vec<_>>();
    let Some(separator) = args.iter().position(|arg| arg == "--") else {
        return Err(CliParseError::new(
            "hook add requires <event> [<Query>] -- <bash command>",
        ));
    };

    let before_separator = &args[..separator];
    let after_separator = &args[separator + 1..];
    let Some(event) = before_separator.first() else {
        return Err(CliParseError::new("hook add requires an event before --"));
    };
    if after_separator.is_empty() {
        return Err(CliParseError::new(
            "hook add requires a bash command after --",
        ));
    }

    let query = if before_separator.len() > 1 {
        let query_text = before_separator[1..].join(" ");
        Query::parse(&query_text)
            .map_err(|error| CliParseError::new(format!("invalid hook query: {error}")))?;
        Some(query_text)
    } else {
        None
    };
    let command = after_separator.join(" ");
    if command.trim().is_empty() {
        return Err(CliParseError::new(
            "hook add requires a non-empty bash command after --",
        ));
    }

    Ok((event.clone(), query, command))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_find_and_ls_list_all_records() {
        for command in ["find", "ls"] {
            let parsed = parse_args([command.to_owned()]).expect("args should parse");
            assert_eq!(
                parsed.command,
                CliCommand::Find {
                    query: None,
                    timestamps: false,
                    sort: None,
                    desc: false,
                    limit: None,
                    count: false,
                }
            );
        }

        let parsed =
            parse_args(["find".to_owned(), "kind=task".to_owned()]).expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task".to_owned()),
                timestamps: false,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );
    }

    #[test]
    fn get_and_find_accept_timestamps_flag_in_any_position() {
        let parsed = parse_args([
            "get".to_owned(),
            "--timestamps".to_owned(),
            "abc123".to_owned(),
        ])
        .expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Get {
                id: "abc123".to_owned(),
                timestamps: true,
            }
        );

        let parsed = parse_args([
            "find".to_owned(),
            "kind=task".to_owned(),
            "--timestamps".to_owned(),
        ])
        .expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task".to_owned()),
                timestamps: true,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );

        let parsed =
            parse_args(["ls".to_owned(), "--timestamps".to_owned()]).expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: None,
                timestamps: true,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );
    }

    #[test]
    fn find_accepts_sort_desc_limit_and_count_flags_alongside_a_query() {
        let parsed = parse_args([
            "find".to_owned(),
            "--sort".to_owned(),
            "n".to_owned(),
            "kind=task".to_owned(),
            "--desc".to_owned(),
            "--limit".to_owned(),
            "5".to_owned(),
            "--count".to_owned(),
        ])
        .expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task".to_owned()),
                timestamps: false,
                sort: Some("n".to_owned()),
                desc: true,
                limit: Some(5),
                count: true,
            }
        );
    }

    #[test]
    fn find_joins_multiple_bare_query_arguments_with_an_implicit_and() {
        let parsed = parse_args([
            "find".to_owned(),
            "kind=task".to_owned(),
            "status=pending".to_owned(),
        ])
        .expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task and status=pending".to_owned()),
                timestamps: false,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );
    }

    #[test]
    fn find_keeps_unquoted_query_arguments_that_already_form_a_valid_query() {
        let parsed = parse_args([
            "find".to_owned(),
            "kind=task".to_owned(),
            "or".to_owned(),
            "kind=note".to_owned(),
        ])
        .expect("args should parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task or kind=note".to_owned()),
                timestamps: false,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );
    }

    #[test]
    fn find_keeps_invalid_queries_space_joined_for_error_reporting() {
        let parsed = parse_args([
            "find".to_owned(),
            "kind=task".to_owned(),
            "bogus".to_owned(),
        ])
        .expect("query validity is checked at execution, not parse");
        assert_eq!(
            parsed.command,
            CliCommand::Find {
                query: Some("kind=task bogus".to_owned()),
                timestamps: false,
                sort: None,
                desc: false,
                limit: None,
                count: false,
            }
        );
    }

    #[test]
    fn find_flags_report_clear_errors() {
        let error = parse_args(["find".to_owned(), "--limit".to_owned(), "abc".to_owned()])
            .expect_err("non-numeric limit should fail");
        assert_eq!(
            error.to_string(),
            "invalid --limit value 'abc': expected a non-negative number"
        );

        let error = parse_args(["ls".to_owned(), "--sort".to_owned()])
            .expect_err("missing sort value should fail");
        assert_eq!(error.to_string(), "--sort requires a value");

        let error = parse_args([
            "find".to_owned(),
            "--sort".to_owned(),
            "a".to_owned(),
            "--sort".to_owned(),
            "b".to_owned(),
        ])
        .expect_err("repeated sort should fail");
        assert_eq!(error.to_string(), "--sort may only be given once");
    }

    #[test]
    fn unknown_flags_report_the_flag_instead_of_falling_through() {
        let error = parse_args(["find".to_owned(), "--unknown-flag".to_owned()])
            .expect_err("unknown find flag should fail");
        assert_eq!(
            error.to_string(),
            "unknown flag '--unknown-flag' for find; see 'agent-store find --help'"
        );

        let error = parse_args(["ls".to_owned(), "kind=task".to_owned(), "--nope".to_owned()])
            .expect_err("unknown ls flag should fail");
        assert_eq!(
            error.to_string(),
            "unknown flag '--nope' for ls; see 'agent-store ls --help'"
        );

        for command in ["get", "rm", "links"] {
            let error = parse_args([command.to_owned(), "--bogus".to_owned(), "abc".to_owned()])
                .expect_err("unknown flag should fail");
            assert_eq!(
                error.to_string(),
                format!("unknown flag '--bogus' for {command}; see 'agent-store {command} --help'")
            );
        }
    }

    #[test]
    fn parses_json_flag_from_any_position() {
        let parsed = parse_args([
            "create".to_owned(),
            "task".to_owned(),
            "title=Write".to_owned(),
            "--json".to_owned(),
        ])
        .expect("args should parse");

        assert!(parsed.json_output);
        assert_eq!(
            parsed.command,
            CliCommand::Create {
                kind: "task".to_owned(),
                fields: BTreeMap::from([("title".to_owned(), "Write".to_owned())]),
            }
        );
    }

    #[test]
    fn subcommand_help_flags_take_precedence_over_positionals() {
        let cases = [
            (
                vec!["create", "--help"],
                CliCommand::Help {
                    topic: HelpTopic::Create,
                },
            ),
            (
                vec!["find", "--help"],
                CliCommand::Help {
                    topic: HelpTopic::Find,
                },
            ),
            (
                vec!["hook", "--help"],
                CliCommand::Help {
                    topic: HelpTopic::Hook,
                },
            ),
            (
                vec!["hook", "add", "--help"],
                CliCommand::Help {
                    topic: HelpTopic::HookAdd,
                },
            ),
            (
                vec!["hook", "ls", "-h"],
                CliCommand::Help {
                    topic: HelpTopic::HookList,
                },
            ),
            (
                vec!["hook", "rm", "-h"],
                CliCommand::Help {
                    topic: HelpTopic::HookRemove,
                },
            ),
        ];

        for (args, expected) in cases {
            let parsed =
                parse_args(args.into_iter().map(str::to_owned)).expect("args should parse");
            assert_eq!(parsed.command, expected);
        }
    }

    #[test]
    fn hook_add_allows_help_text_inside_bash_command() {
        let parsed = parse_args([
            "hook".to_owned(),
            "add".to_owned(),
            "create".to_owned(),
            "--".to_owned(),
            "echo".to_owned(),
            "--help".to_owned(),
        ])
        .expect("args should parse");

        assert_eq!(
            parsed.command,
            CliCommand::Hook(HookCliCommand::Add {
                event: "create".to_owned(),
                query: None,
                command: "echo --help".to_owned(),
            })
        );
    }

    #[test]
    fn parses_hook_add_query_and_command() {
        let parsed = parse_args([
            "hook".to_owned(),
            "add".to_owned(),
            "create".to_owned(),
            "kind=task".to_owned(),
            "--".to_owned(),
            "echo".to_owned(),
            "created".to_owned(),
        ])
        .expect("args should parse");

        assert_eq!(
            parsed.command,
            CliCommand::Hook(HookCliCommand::Add {
                event: "create".to_owned(),
                query: Some("kind=task".to_owned()),
                command: "echo created".to_owned(),
            })
        );
    }

    #[test]
    fn bare_invocation_requests_usage_error() {
        let error = parse_args([]).expect_err("bare invocation should fail");

        assert_eq!(error.to_string(), "missing command");
        assert!(error.include_usage());
    }

    #[test]
    fn not_is_reserved_as_kind_and_field_name() {
        let error = parse_args(["create".to_owned(), "not".to_owned()])
            .expect_err("reserved kind should fail");
        assert_eq!(error.to_string(), "'not' is a reserved kind");

        for command in ["create", "set"] {
            let error = parse_args([
                command.to_owned(),
                "note".to_owned(),
                "not=really".to_owned(),
            ])
            .expect_err("reserved field name should fail");
            assert_eq!(error.to_string(), "'not' is a reserved field name");
        }
    }

    #[test]
    fn unknown_top_level_commands_request_usage() {
        let error = parse_args(["missing".to_owned()]).expect_err("args should fail");

        assert_eq!(error.to_string(), "unrecognized command 'missing'");
        assert!(error.include_usage());
    }

    #[test]
    fn typoed_commands_suggest_the_nearest_command() {
        for (typo, suggestion) in [
            ("creat", "create"),
            ("finde", "find"),
            ("lnk", "link"),
            ("contxt", "context"),
            ("hok", "hook"),
            ("CREATE", "create"),
        ] {
            let error =
                parse_args([typo.to_owned()]).expect_err("unrecognized command should fail");
            assert_eq!(
                error.to_string(),
                format!("unrecognized command '{typo}' (did you mean '{suggestion}'?)")
            );
            assert!(error.include_usage());
        }
    }

    #[test]
    fn distant_or_short_typos_get_no_suggestion() {
        for typo in ["missing", "x", "c"] {
            let error =
                parse_args([typo.to_owned()]).expect_err("unrecognized command should fail");
            assert_eq!(error.to_string(), format!("unrecognized command '{typo}'"));
        }
    }

    #[test]
    fn typoed_hook_commands_suggest_the_nearest_hook_command() {
        let error = parse_args(["hook".to_owned(), "runz".to_owned()])
            .expect_err("unrecognized hook command should fail");
        assert_eq!(
            error.to_string(),
            "unrecognized hook command 'runz' (did you mean 'runs'?)"
        );

        let error = parse_args(["hook".to_owned(), "nothing".to_owned()])
            .expect_err("unrecognized hook command should fail");
        assert_eq!(error.to_string(), "unrecognized hook command 'nothing'");
    }

    #[test]
    fn parses_schedule_add_every_with_and_without_query() {
        let result =
            parse_args("schedule add every 5m -- echo tick".split_whitespace().map(String::from))
                .unwrap();
        match result.command {
            CliCommand::Schedule(ScheduleCliCommand::Add {
                kind,
                expression,
                query,
                command,
            }) => {
                assert_eq!(kind, "every");
                assert_eq!(expression, "5m");
                assert!(query.is_none());
                assert_eq!(command, "echo tick");
            }
            other => panic!("expected Schedule(Add), got {other:?}"),
        }

        let result = parse_args(
            "schedule add every 1h kind=task -- echo go"
                .split_whitespace()
                .map(String::from),
        )
        .unwrap();
        match result.command {
            CliCommand::Schedule(ScheduleCliCommand::Add {
                kind,
                expression,
                query,
                command,
            }) => {
                assert_eq!(kind, "every");
                assert_eq!(expression, "1h");
                assert_eq!(query, Some("kind=task".to_owned()));
                assert_eq!(command, "echo go");
            }
            other => panic!("expected Schedule(Add), got {other:?}"),
        }
    }

    #[test]
    fn parses_schedule_at() {
        let result = parse_args(
            "schedule add at 2026-07-07T12:00:00Z -- echo done"
                .split_whitespace()
                .map(String::from),
        )
        .unwrap();
        match result.command {
            CliCommand::Schedule(ScheduleCliCommand::Add {
                kind, expression, ..
            }) => {
                assert_eq!(kind, "at");
                assert_eq!(expression, "2026-07-07T12:00:00Z");
            }
            other => panic!("expected Schedule(Add), got {other:?}"),
        }
    }

    #[test]
    fn schedule_add_rejects_missing_double_dash() {
        let error = parse_args(
            "schedule add every 5m echo tick"
                .split_whitespace()
                .map(String::from),
        )
        .expect_err("missing -- should fail");
        assert!(
            error.to_string().contains("--"),
            "error should mention --: {error}"
        );
    }

    #[test]
    fn typoed_schedule_commands_suggest_the_nearest_schedule_command() {
        let error = parse_args(["schedule".to_owned(), "enabel".to_owned()])
            .expect_err("unrecognized schedule command should fail");
        assert_eq!(
            error.to_string(),
            "unrecognized schedule command 'enabel' (did you mean 'enable'?)"
        );
    }
}
