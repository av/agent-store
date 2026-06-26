use agent_store::query::Query;
use agent_store::store::{Hook, Link, LinkEdge, Record, Store, STORE_DIR};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
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
const HOOK_TIMEOUT_EXIT_STATUS: i32 = -1;
const HOOK_OUTPUT_CAPTURE_LIMIT_BYTES: usize = 8192;
const HOOK_ENV_KEYS: &[&str] = &[
    "AGENT_STORE_EVENT",
    "AGENT_STORE_ID",
    "AGENT_STORE_KIND",
    "AGENT_STORE_REL",
    "AGENT_STORE_TARGET_ID",
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
  hook          Manage stored hooks

Hook stdout and stderr captures are capped at 8192 bytes each.
";

fn main() {
    let mut raw_args: Vec<String> = env::args().skip(1).collect();
    let json_output = take_json_flag(&mut raw_args);
    let mut args = raw_args.into_iter();

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

            if json_output {
                print_json(json!({
                    "status": "initialized",
                    "store_dir": STORE_DIR,
                }));
            } else {
                println!("Initialized {STORE_DIR}/");
            }
        }
        Some("create") | Some("cr") => {
            let Some(kind) = args.next() else {
                eprintln!("error: create requires a kind");
                process::exit(2);
            };

            match parse_fields(args) {
                Ok(fields) => {
                    let mut store = open_store_or_exit();
                    match store.create_record(&kind, fields) {
                        Ok(record) => {
                            run_hooks_or_exit(&mut store, "create", &record);
                            if json_output {
                                print_json(mutation_json("created", &record));
                            } else {
                                println!("{}", record.id);
                            }
                        }
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
                Ok(record) => {
                    if json_output {
                        print_json(single_record_json(&record));
                    } else {
                        println!("{}", format_record(&record));
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to get record: {error}");
                    process::exit(1);
                }
            }
        }
        Some("find") | Some("ls") => {
            let query_text = args.collect::<Vec<_>>().join(" ");
            if query_text.trim().is_empty() {
                eprintln!("error: find requires a query");
                process::exit(2);
            }

            let query = match Query::parse(&query_text) {
                Ok(query) => query,
                Err(error) => {
                    eprintln!("error: invalid query: {error}");
                    process::exit(2);
                }
            };
            let store = open_store_or_exit();
            match store.find_records(&query) {
                Ok(records) => {
                    if json_output {
                        print_json(records_json(&records));
                    } else {
                        for record in records {
                            println!("{}", format_record(&record));
                        }
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to find records: {error}");
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
                        Ok(record) => {
                            run_hooks_or_exit(&mut store, "set", &record);
                            if json_output {
                                print_json(mutation_json("updated", &record));
                            } else {
                                println!("Updated {}", record.id);
                            }
                        }
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
        Some("unset") => {
            let Some(id) = args.next() else {
                eprintln!("error: unset requires a record ID");
                process::exit(2);
            };

            match parse_field_keys(args) {
                Ok(keys) if keys.is_empty() => {
                    eprintln!("error: unset requires at least one field name");
                    process::exit(2);
                }
                Ok(keys) => {
                    let mut store = open_store_or_exit();
                    match store.unset_record(&id, keys) {
                        Ok(record) => {
                            run_hooks_or_exit(&mut store, "unset", &record);
                            if json_output {
                                print_json(mutation_json("updated", &record));
                            } else {
                                println!("Updated {}", record.id);
                            }
                        }
                        Err(error) => {
                            eprintln!("error: failed to unset record: {error}");
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
                Ok(record) => {
                    run_hooks_or_exit(&mut store, "rm", &record);
                    if json_output {
                        print_json(mutation_json("removed", &record));
                    } else {
                        println!("Removed {}", record.id);
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to remove record: {error}");
                    process::exit(1);
                }
            }
        }
        Some("link") => {
            let (from, rel, to) = match parse_link_args(args, "link") {
                Ok(args) => args,
                Err(error) => {
                    eprintln!("error: {error}");
                    process::exit(2);
                }
            };

            let mut store = open_store_or_exit();
            match store.link_records(&from, &rel, &to) {
                Ok(link) => {
                    let source = record_for_link_hook_or_exit(&store, "link", &link);
                    run_hooks_or_exit(&mut store, "link", &source);
                    if json_output {
                        print_json(link_mutation_json("linked", &link));
                    } else {
                        println!(
                            "Linked {} {} {}",
                            link.from_record_id, link.rel, link.to_record_id
                        );
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to link records: {error}");
                    process::exit(1);
                }
            }
        }
        Some("unlink") => {
            let (from, rel, to) = match parse_link_args(args, "unlink") {
                Ok(args) => args,
                Err(error) => {
                    eprintln!("error: {error}");
                    process::exit(2);
                }
            };

            let mut store = open_store_or_exit();
            match store.unlink_records(&from, &rel, &to) {
                Ok(link) => {
                    let source = record_for_link_hook_or_exit(&store, "unlink", &link);
                    run_hooks_or_exit(&mut store, "unlink", &source);
                    if json_output {
                        print_json(link_mutation_json("unlinked", &link));
                    } else {
                        println!(
                            "Unlinked {} {} {}",
                            link.from_record_id, link.rel, link.to_record_id
                        );
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to unlink records: {error}");
                    process::exit(1);
                }
            }
        }
        Some("links") => {
            let Some(id) = args.next() else {
                eprintln!("error: links requires a record ID");
                process::exit(2);
            };
            if let Some(extra) = args.next() {
                eprintln!("error: links does not accept argument '{extra}'");
                process::exit(2);
            }

            let store = open_store_or_exit();
            match store.links_for_record(&id) {
                Ok(record_links) => {
                    if json_output {
                        print_json(record_links_json(
                            &record_links.record_id,
                            &record_links.links,
                        ));
                    } else {
                        for link in record_links.links {
                            println!(
                                "{} {} {}",
                                link.direction.as_str(),
                                link.rel,
                                link.peer_record_id
                            );
                        }
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to list links: {error}");
                    process::exit(1);
                }
            }
        }
        Some("hook") => match args.next().as_deref() {
            Some("add") => {
                let (event, query, command) = match parse_hook_add_args(args) {
                    Ok(parsed) => parsed,
                    Err(error) => {
                        eprintln!("error: {error}");
                        process::exit(2);
                    }
                };

                let mut store = open_store_or_exit();
                match store.add_hook(&event, query, &command) {
                    Ok(hook) => {
                        println!("{}", hook.id);
                    }
                    Err(error) => {
                        eprintln!("error: failed to add hook: {error}");
                        process::exit(1);
                    }
                }
            }
            Some("ls") => {
                if let Some(extra) = args.next() {
                    eprintln!("error: hook ls does not accept argument '{extra}'");
                    process::exit(2);
                }

                let store = open_store_or_exit();
                match store.list_hooks() {
                    Ok(hooks) => {
                        for hook in hooks {
                            println!("{}", format_hook(&hook));
                        }
                    }
                    Err(error) => {
                        eprintln!("error: failed to list hooks: {error}");
                        process::exit(1);
                    }
                }
            }
            Some("rm") => {
                let Some(id) = args.next() else {
                    eprintln!("error: hook rm requires a hook ID");
                    process::exit(2);
                };
                if let Some(extra) = args.next() {
                    eprintln!("error: hook rm does not accept argument '{extra}'");
                    process::exit(2);
                }

                let mut store = open_store_or_exit();
                match store.delete_hook(&id) {
                    Ok(hook) => {
                        println!("Removed {}", hook.id);
                    }
                    Err(error) => {
                        eprintln!("error: failed to remove hook: {error}");
                        process::exit(1);
                    }
                }
            }
            Some(command) => {
                eprintln!("error: unrecognized hook command '{command}'");
                process::exit(2);
            }
            None => {
                eprintln!("error: hook requires add, ls, or rm");
                process::exit(2);
            }
        },
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

fn record_for_link_hook_or_exit(store: &Store, event_type: &str, link: &Link) -> Record {
    match store.get_record(&link.from_record_id) {
        Ok(record) => record,
        Err(error) => {
            eprintln!("error: failed to load {event_type} hook record: {error}");
            process::exit(1);
        }
    }
}

fn run_hooks_or_exit(store: &mut Store, event_type: &str, record: &Record) {
    if let Err(error) = run_matching_hooks_after_commit(store, event_type, record) {
        eprintln!(
            "error: failed to run hooks after Store mutation already committed for {event_type} {}: {error}",
            record.id
        );
        process::exit(1);
    }
}

fn run_matching_hooks_after_commit(
    store: &mut Store,
    event_type: &str,
    record: &Record,
) -> Result<(), String> {
    let project_root = store.project_root().to_path_buf();
    let hooks = store
        .list_hooks()
        .map_err(|error| format!("failed to list hooks: {error}"))?;

    for hook in hooks.into_iter().filter(|hook| hook.event == event_type) {
        if !hook_query_matches(store, event_type, &hook, record)? {
            continue;
        }

        let stdin_payload = format!("{}\n", format_record(record));
        let env_vars = hook_env_vars(event_type, record);
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
            output.status.code().unwrap_or(1)
        };
        let stdout_summary = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut stderr_summary = String::from_utf8_lossy(&output.stderr).into_owned();
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
            return Err(format!(
                "hook {} command '{}' timed out after {} seconds",
                hook.id,
                hook.command,
                DEFAULT_HOOK_TIMEOUT.as_secs()
            ));
        }

        if !output.status.success() {
            return Err(format!(
                "hook {} command '{}' failed with exit status {}; stderr: {}",
                hook.id, hook.command, exit_status, stderr_summary
            ));
        }
    }

    Ok(())
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

fn hook_env_vars(event_type: &str, record: &Record) -> [(&'static str, String); 3] {
    [
        ("AGENT_STORE_EVENT", event_type.to_owned()),
        ("AGENT_STORE_ID", record.id.clone()),
        ("AGENT_STORE_KIND", record.kind.clone()),
    ]
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
) -> Result<bool, String> {
    let Some(query_text) = hook.query.as_deref() else {
        return Ok(true);
    };

    let query = Query::parse(query_text)
        .map_err(|error| format!("hook {} has invalid query: {error}", hook.id))?;
    if !query.uses_links() {
        return Ok(query.matches(record));
    }

    let links = if event_type == "rm" {
        Vec::new()
    } else {
        store
            .links_for_record(&record.id)
            .map_err(|error| format!("failed to load hook {} link context: {error}", hook.id))?
            .links
    };

    Ok(query.matches_with_links(record, &links))
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

fn parse_field_keys(args: impl Iterator<Item = String>) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();

    for arg in args {
        if arg.is_empty() {
            return Err("field names cannot be empty".to_owned());
        }
        if arg.contains('=') {
            return Err(format!(
                "field argument '{arg}' must be a field name, not key=value"
            ));
        }

        keys.push(arg);
    }

    Ok(keys)
}

fn parse_link_args(
    mut args: impl Iterator<Item = String>,
    command: &str,
) -> Result<(String, String, String), String> {
    let Some(from) = args.next() else {
        return Err(format!("{command} requires <from> <rel> <to>"));
    };
    let Some(rel) = args.next() else {
        return Err(format!("{command} requires <from> <rel> <to>"));
    };
    let Some(to) = args.next() else {
        return Err(format!("{command} requires <from> <rel> <to>"));
    };
    if let Some(extra) = args.next() {
        return Err(format!("{command} does not accept argument '{extra}'"));
    }

    Ok((from, rel, to))
}

fn parse_hook_add_args(
    args: impl Iterator<Item = String>,
) -> Result<(String, Option<String>, String), String> {
    let args = args.collect::<Vec<_>>();
    let Some(separator) = args.iter().position(|arg| arg == "--") else {
        return Err("hook add requires <event> [<Query>] -- <bash command>".to_owned());
    };

    let before_separator = &args[..separator];
    let after_separator = &args[separator + 1..];
    let Some(event) = before_separator.first() else {
        return Err("hook add requires an event before --".to_owned());
    };
    if after_separator.is_empty() {
        return Err("hook add requires a bash command after --".to_owned());
    }

    let query = if before_separator.len() > 1 {
        let query_text = before_separator[1..].join(" ");
        Query::parse(&query_text).map_err(|error| format!("invalid hook query: {error}"))?;
        Some(query_text)
    } else {
        None
    };
    let command = after_separator.join(" ");
    if command.trim().is_empty() {
        return Err("hook add requires a non-empty bash command after --".to_owned());
    }

    Ok((event.clone(), query, command))
}

fn print_json(value: Value) {
    println!("{value}");
}

fn single_record_json(record: &Record) -> Value {
    json!({
        "record": record_json(record),
    })
}

fn records_json(records: &[Record]) -> Value {
    json!({
        "records": records.iter().map(record_json).collect::<Vec<_>>(),
    })
}

fn mutation_json(status: &str, record: &Record) -> Value {
    json!({
        "status": status,
        "record": record_json(record),
    })
}

fn link_mutation_json(status: &str, link: &Link) -> Value {
    json!({
        "status": status,
        "link": link_json(link),
    })
}

fn record_json(record: &Record) -> Value {
    json!({
        "id": &record.id,
        "kind": &record.kind,
        "fields": &record.fields,
    })
}

fn link_json(link: &Link) -> Value {
    json!({
        "from_record_id": &link.from_record_id,
        "rel": &link.rel,
        "to_record_id": &link.to_record_id,
    })
}

fn record_links_json(record_id: &str, links: &[LinkEdge]) -> Value {
    json!({
        "record_id": record_id,
        "links": links.iter().map(link_edge_json).collect::<Vec<_>>(),
    })
}

fn link_edge_json(link: &LinkEdge) -> Value {
    json!({
        "direction": link.direction.as_str(),
        "rel": &link.rel,
        "record_id": &link.peer_record_id,
    })
}

fn format_hook(hook: &Hook) -> String {
    let mut output = format!("{} {}", hook.id, hook.event);
    if let Some(query) = &hook.query {
        output.push_str(" query=");
        output.push_str(&shell_quote_value(query));
    }
    output.push_str(" -- ");
    output.push_str(&shell_quote_value(&hook.command));
    output
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
