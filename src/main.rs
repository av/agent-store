mod cli;
mod output;

use agent_store::query::Query;
use agent_store::store::{Hook, Link, LinkEdge, Record, Store, STORE_DIR};
use cli::{CliCommand, HookCliCommand};
use output::{
    format_hook, format_quick_context, format_record, help_text, init_json, link_mutation_json,
    mutation_json, print_json, record_links_json, records_json, single_record_json,
    QUICK_CONTEXT_OUTPUT_LIMIT_BYTES, USAGE,
};
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
            print!("{}", help_text(topic));
        }
        CliCommand::Version => {
            println!("agent-store {}", env!("CARGO_PKG_VERSION"));
        }
        CliCommand::Init => {
            if let Err(error) = init_store() {
                eprintln!("error: failed to initialize store: {error}");
                process::exit(1);
            }

            if cli.json_output {
                print_json(init_json());
            } else {
                println!("Initialized {STORE_DIR}/");
            }
        }
        CliCommand::Create { kind, fields } => {
            let mut store = open_store_or_exit();
            match store.create_record(&kind, fields) {
                Ok(record) => {
                    run_hooks_or_exit(&mut store, "create", &record, None);
                    if cli.json_output {
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
        CliCommand::Get { id } => {
            let store = open_store_or_exit();
            match store.get_record(&id) {
                Ok(record) => {
                    if cli.json_output {
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
        CliCommand::Find { query } => {
            let query = match Query::parse(&query) {
                Ok(query) => query,
                Err(error) => {
                    eprintln!("error: invalid query: {error}");
                    process::exit(2);
                }
            };
            let store = open_store_or_exit();
            match store.find_records(&query) {
                Ok(records) => {
                    if cli.json_output {
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
        CliCommand::Set { id, fields } => {
            let mut store = open_store_or_exit();
            match store.set_record_with_snapshot(&id, fields) {
                Ok(mutation) => {
                    run_hooks_or_exit(
                        &mut store,
                        "set",
                        &mutation.record,
                        Some(&mutation.record_links),
                    );
                    if cli.json_output {
                        print_json(mutation_json("updated", &mutation.record));
                    } else {
                        println!("Updated {}", mutation.record.id);
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to set record: {error}");
                    process::exit(1);
                }
            }
        }
        CliCommand::Unset { id, keys } => {
            let mut store = open_store_or_exit();
            match store.unset_record_with_snapshot(&id, keys) {
                Ok(mutation) => {
                    run_hooks_or_exit(
                        &mut store,
                        "unset",
                        &mutation.record,
                        Some(&mutation.record_links),
                    );
                    if cli.json_output {
                        print_json(mutation_json("updated", &mutation.record));
                    } else {
                        println!("Updated {}", mutation.record.id);
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to unset record: {error}");
                    process::exit(1);
                }
            }
        }
        CliCommand::Rm { id } => {
            let mut store = open_store_or_exit();
            match store.delete_record(&id) {
                Ok(record) => {
                    run_hooks_or_exit(&mut store, "rm", &record, None);
                    if cli.json_output {
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
        CliCommand::Link { from, rel, to } => {
            let mut store = open_store_or_exit();
            match store.link_records_with_snapshot(&from, &rel, &to) {
                Ok(mutation) => {
                    run_link_hooks_or_exit(
                        &mut store,
                        "link",
                        &mutation.source,
                        &mutation.link,
                        &mutation.source_links,
                    );
                    if cli.json_output {
                        print_json(link_mutation_json("linked", &mutation.link));
                    } else {
                        println!(
                            "Linked {} {} {}",
                            mutation.link.from_record_id,
                            mutation.link.rel,
                            mutation.link.to_record_id
                        );
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to link records: {error}");
                    process::exit(1);
                }
            }
        }
        CliCommand::Unlink { from, rel, to } => {
            let mut store = open_store_or_exit();
            match store.unlink_records_with_snapshot(&from, &rel, &to) {
                Ok(mutation) => {
                    run_link_hooks_or_exit(
                        &mut store,
                        "unlink",
                        &mutation.source,
                        &mutation.link,
                        &mutation.source_links,
                    );
                    if cli.json_output {
                        print_json(link_mutation_json("unlinked", &mutation.link));
                    } else {
                        println!(
                            "Unlinked {} {} {}",
                            mutation.link.from_record_id,
                            mutation.link.rel,
                            mutation.link.to_record_id
                        );
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to unlink records: {error}");
                    process::exit(1);
                }
            }
        }
        CliCommand::Links { id } => {
            let store = open_store_or_exit();
            match store.links_for_record(&id) {
                Ok(record_links) => {
                    if cli.json_output {
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
        CliCommand::Context => {
            let store = open_store_or_exit();
            match store.quick_context_summary() {
                Ok(summary) => {
                    let output = format_quick_context(&summary);
                    if output.len() < QUICK_CONTEXT_OUTPUT_LIMIT_BYTES {
                        println!("{output}");
                    } else {
                        print!("{output}");
                    }
                }
                Err(error) => {
                    eprintln!("error: failed to build Quick Context: {error}");
                    process::exit(1);
                }
            }
        }
        CliCommand::Hook(command) => match command {
            HookCliCommand::Add {
                event,
                query,
                command,
            } => {
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
            HookCliCommand::List => {
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
            HookCliCommand::Remove { id } => {
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
        },
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

fn run_hooks_or_exit(
    store: &mut Store,
    event_type: &str,
    record: &Record,
    link_context: Option<&[LinkEdge]>,
) {
    if let Err(error) =
        run_matching_hooks_after_commit(store, event_type, record, None, link_context)
    {
        eprintln!(
            "error: failed to run hooks after Store mutation already committed for {event_type} {}: {error}",
            record.id
        );
        process::exit(1);
    }
}

fn run_link_hooks_or_exit(
    store: &mut Store,
    event_type: &str,
    record: &Record,
    link: &Link,
    link_context: &[LinkEdge],
) {
    if let Err(error) =
        run_matching_hooks_after_commit(store, event_type, record, Some(link), Some(link_context))
    {
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
    link: Option<&Link>,
    link_context: Option<&[LinkEdge]>,
) -> Result<(), String> {
    let project_root = store.project_root().to_path_buf();
    let hooks = store
        .list_hooks()
        .map_err(|error| format!("failed to list hooks: {error}"))?;

    for hook in hooks.into_iter().filter(|hook| hook.event == event_type) {
        if !hook_query_matches(store, event_type, &hook, record, link_context)? {
            continue;
        }

        let stdin_payload = format!("{}\n", format_record(record));
        let env_vars = hook_env_vars(event_type, record, link);
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

fn hook_env_vars(
    event_type: &str,
    record: &Record,
    link: Option<&Link>,
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
    let links = if event_type == "rm" {
        &[][..]
    } else if let Some(link_context) = link_context {
        link_context
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
}
