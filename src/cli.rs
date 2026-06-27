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
    Get {
        id: String,
    },
    Find {
        query: String,
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
        None => CliCommand::Help {
            topic: HelpTopic::Top,
        },
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
            let mut args = args.into_iter();
            let kind = args
                .next()
                .ok_or_else(|| CliParseError::new("create requires a kind"))?;
            let fields = parse_fields(args)?;
            Ok(CliCommand::Create { kind, fields })
        }
        "get" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Get));
            }
            let mut args = args.into_iter();
            let id = args
                .next()
                .ok_or_else(|| CliParseError::new("get requires a record ID"))?;
            if let Some(extra) = args.next() {
                return Err(CliParseError::new(format!(
                    "get does not accept argument '{extra}'"
                )));
            }
            Ok(CliCommand::Get { id })
        }
        "find" | "ls" => {
            if command_help_requested(&args) {
                return Ok(help_command(HelpTopic::Find));
            }
            let query = args.join(" ");
            if query.trim().is_empty() {
                return Err(CliParseError::new("find requires a query"));
            }
            Ok(CliCommand::Find { query })
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
        _ => Err(CliParseError::with_usage(format!(
            "unrecognized command '{command}'"
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
        Some(command) => Err(CliParseError::new(format!(
            "unrecognized hook command '{command}'"
        ))),
        None => Err(CliParseError::new("hook requires add, ls, or rm")),
    }
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
        if key.is_empty() {
            return Err(CliParseError::new("field names cannot be empty"));
        }

        fields.insert(key.to_owned(), value.to_owned());
    }

    Ok(fields)
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
    fn unknown_top_level_commands_request_usage() {
        let error = parse_args(["missing".to_owned()]).expect_err("args should fail");

        assert_eq!(error.to_string(), "unrecognized command 'missing'");
        assert!(error.include_usage());
    }
}
