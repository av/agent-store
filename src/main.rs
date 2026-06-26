mod store;

use std::collections::BTreeMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::process;
use store::{Record, Store, STORE_DIR};

const GITIGNORE_PATH: &str = ".gitignore";
const GITIGNORE_RULE: &str = ".agent-store/";
const AGENT_SKILLS_DIR: &str = ".agents/skills";
const CLAUDE_SKILLS_DIR: &str = ".claude/skills";
const INSTRUCTION_FILES: &[&str] = &["AGENTS.md", "CLAUDE.md"];
const INSTRUCTIONS_START: &str = "<!-- agent-store:start -->";
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
by mutation commands to retrieve or update specific records.
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
agent-store set <id> status=done
```

Decision log:

```bash
agent-store create decision area=storage choice=sqlite reason="single-file project-local store"
agent-store find 'kind=decision and area=storage'
```
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

Filter and format:

```bash
agent-store find 'kind=task and status=pending' --json | jq .
```

Capture command output:

```bash
agent-store create log command=test output="$(cargo test 2>&1)"
```
"#,
    },
];

const USAGE: &str = "\
Usage: agent-store [OPTIONS] <COMMAND>

A project-local store for agent-facing records, links, hooks, and context.

Options:
  -h, --help    Print help
  -V, --version Print version

Commands:
  init          Initialize a project-local store
  create        Create a record
  get           Print a record by ID
  set           Update fields on a record by ID
  rm            Delete a record by ID
";

fn main() {
    let mut args = env::args().skip(1);

    match args.next().as_deref() {
        Some("-h") | Some("--help") => {
            print!("{USAGE}");
        }
        Some("-V") | Some("--version") => {
            println!("agent-store {}", env!("CARGO_PKG_VERSION"));
        }
        Some("init") => {
            if let Some(extra) = args.next() {
                eprintln!("error: init does not accept argument '{extra}'");
                process::exit(2);
            }

            if let Err(error) = init_store() {
                eprintln!("error: failed to initialize store: {error}");
                process::exit(1);
            }

            println!("Initialized {STORE_DIR}/");
        }
        Some("create") => {
            let Some(kind) = args.next() else {
                eprintln!("error: create requires a kind");
                process::exit(2);
            };

            match parse_fields(args) {
                Ok(fields) => {
                    let mut store = open_store_or_exit();
                    match store.create_record(&kind, fields) {
                        Ok(record) => println!("{}", record.id),
                        Err(error) => {
                            eprintln!("error: failed to create record: {error}");
                            process::exit(1);
                        }
                    }
                }
                Err(error) => {
                    eprintln!("error: {error}");
                    process::exit(2);
                }
            }
        }
        Some("get") => {
            let Some(id) = args.next() else {
                eprintln!("error: get requires a record ID");
                process::exit(2);
            };
            if let Some(extra) = args.next() {
                eprintln!("error: get does not accept argument '{extra}'");
                process::exit(2);
            }

            let store = open_store_or_exit();
            match store.get_record(&id) {
                Ok(record) => println!("{}", format_record(&record)),
                Err(error) => {
                    eprintln!("error: failed to get record: {error}");
                    process::exit(1);
                }
            }
        }
        Some("set") => {
            let Some(id) = args.next() else {
                eprintln!("error: set requires a record ID");
                process::exit(2);
            };

            match parse_fields(args) {
                Ok(fields) if fields.is_empty() => {
                    eprintln!("error: set requires at least one key=value field");
                    process::exit(2);
                }
                Ok(fields) => {
                    let mut store = open_store_or_exit();
                    match store.set_record(&id, fields) {
                        Ok(record) => println!("Updated {}", record.id),
                        Err(error) => {
                            eprintln!("error: failed to set record: {error}");
                            process::exit(1);
                        }
                    }
                }
                Err(error) => {
                    eprintln!("error: {error}");
                    process::exit(2);
                }
            }
        }
        Some("rm") => {
            let Some(id) = args.next() else {
                eprintln!("error: rm requires a record ID");
                process::exit(2);
            };
            if let Some(extra) = args.next() {
                eprintln!("error: rm does not accept argument '{extra}'");
                process::exit(2);
            }

            let mut store = open_store_or_exit();
            match store.delete_record(&id) {
                Ok(record) => println!("Removed {}", record.id),
                Err(error) => {
                    eprintln!("error: failed to remove record: {error}");
                    process::exit(1);
                }
            }
        }
        Some(command) => {
            eprintln!("error: unrecognized command '{command}'");
            eprintln!();
            eprint!("{USAGE}");
            process::exit(2);
        }
        None => {
            print!("{USAGE}");
        }
    }
}

fn init_store() -> io::Result<()> {
    fs::create_dir_all(STORE_DIR)?;
    ensure_gitignore_rule(Path::new(GITIGNORE_PATH), GITIGNORE_RULE)?;
    install_builtin_skills(Path::new(AGENT_SKILLS_DIR))?;
    install_builtin_skills(Path::new(CLAUDE_SKILLS_DIR))?;
    for instruction_file in INSTRUCTION_FILES {
        ensure_instruction_block(Path::new(instruction_file))?;
    }
    Ok(())
}

fn open_store_or_exit() -> Store {
    match Store::open_project() {
        Ok(store) => store,
        Err(error) => {
            eprintln!("error: failed to open store: {error}");
            process::exit(1);
        }
    }
}

fn parse_fields(args: impl Iterator<Item = String>) -> Result<BTreeMap<String, String>, String> {
    let mut fields = BTreeMap::new();

    for arg in args {
        let Some((key, value)) = arg.split_once('=') else {
            return Err(format!("field argument '{arg}' must use key=value syntax"));
        };
        if key.is_empty() {
            return Err("field names cannot be empty".to_owned());
        }

        fields.insert(key.to_owned(), value.to_owned());
    }

    Ok(fields)
}

fn format_record(record: &Record) -> String {
    let mut output = format!("{} {}", record.id, record.kind);
    for (key, value) in &record.fields {
        output.push(' ');
        output.push_str(key);
        output.push('=');
        output.push_str(&shell_quote_value(value));
    }
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

fn install_builtin_skills(root: &Path) -> io::Result<()> {
    for skill in BUILTIN_SKILLS {
        let skill_dir = root.join(skill.name);
        fs::create_dir_all(&skill_dir)?;
        write_file_if_absent(&skill_dir.join("SKILL.md"), skill.content)?;
    }
    Ok(())
}

fn write_file_if_absent(path: &Path, contents: &str) -> io::Result<()> {
    match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => file.write_all(contents.as_bytes()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}

fn ensure_instruction_block(path: &Path) -> io::Result<()> {
    let existing = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };

    if existing.contains(INSTRUCTIONS_START) {
        return Ok(());
    }

    let mut file = OpenOptions::new().append(true).open(path)?;
    if !existing.is_empty() && !existing.ends_with('\n') {
        writeln!(file)?;
    }
    if !existing.is_empty() {
        writeln!(file)?;
    }
    write!(file, "{INSTRUCTIONS_BLOCK}")?;
    Ok(())
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
    fn builtin_skill_install_preserves_existing_files() {
        let root = temp_dir("skills");
        let skills_root = root.join(".agents/skills");
        let custom_skill = skills_root.join("agent-store/SKILL.md");
        fs::create_dir_all(custom_skill.parent().expect("custom skill parent"))
            .expect("custom skill dir should be created");
        fs::write(&custom_skill, "custom skill\n").expect("custom skill should be written");

        install_builtin_skills(&skills_root).expect("skills should install");

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

        ensure_instruction_block(&agents).expect("instruction block should append");
        ensure_instruction_block(&agents).expect("instruction block should not duplicate");

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

        ensure_instruction_block(&missing).expect("missing instructions should be ignored");

        assert!(!missing.exists());

        fs::remove_dir_all(root).expect("test temp dir should be removed");
    }

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
}
