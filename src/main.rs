use clap::{CommandFactory, Parser, Subcommand};
use rusqlite::Connection;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process;
use uuid::Uuid;

/// CLI-first unstructured data store for agents
#[derive(Parser)]
#[command(name = "agent-store", version)]
#[command(
    about = "CLI-first unstructured data store for agents. Push, pull, and query arbitrary data with no schema.",
    before_help = "\
agent-store - CLI-first unstructured data store for agents

Start here (for AI agents):
  agent-store skills get agent-store --full

  Skills ship with the CLI (always version-matched) and include workflow
  patterns, command reference, and copy-paste examples. Prefer this over
  guessing commands from flag docs alone.

  skills list                              List available skills
  skills get agent-store --full            Core reference + command docs
  skills get agent-store-patterns          Workflow recipes (scratchpad, tasks, caching)
  skills get agent-store-pipelines         Shell composition (import, export, chaining)
  skills path [name]                       Print skill directory path",
    after_long_help = "\
agent-store is append-only by design. There are no update or delete commands. \
To supersede an entry, push a new one with the same labels."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Initialize store, install agent skills, and set up project docs
    Init,
    /// Push data from stdin (or --file) into the store
    Push {
        /// Tag entry with a label (can be repeated)
        #[arg(long)]
        label: Vec<String>,
        /// Set entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
        /// Only print the entry ID (for scripting/piping)
        #[arg(long, short = 'q', conflicts_with = "id_only")]
        quiet: bool,
        /// Output only the raw UUID (no prefix text), for scripting
        #[arg(long, conflicts_with = "quiet")]
        id_only: bool,
        /// Set attribute key=value pair (can be repeated)
        #[arg(long = "attr")]
        attr: Vec<String>,
        /// Override created_at timestamp (ISO 8601: "2024-01-15 10:30:00" or "2024-01-15")
        #[arg(long)]
        timestamp: Option<String>,
        /// Read data from a file instead of stdin
        #[arg(long, short = 'f')]
        file: Option<String>,
    },
    /// Pull an entry by ID and print to stdout
    Pull {
        /// Entry ID to retrieve
        id: String,
        /// Output the full entry as a JSON object (same format as query --json)
        #[arg(long)]
        json: bool,
        /// Omit trailing newline (binary-safe piping)
        #[arg(long)]
        raw: bool,
    },
    /// List and filter entries
    Query {
        /// Filter by entry ID (returns entry in query format with JSON support)
        #[arg(long)]
        id: Option<String>,
        /// Filter by label (can be repeated, AND logic)
        #[arg(long)]
        label: Vec<String>,
        /// Exclude entries with this label (can be repeated, excludes all specified)
        #[arg(long = "not-label")]
        not_label: Vec<String>,
        /// Filter by entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
        /// Filter by attribute key=value pair (can be repeated, AND logic)
        #[arg(long = "attr")]
        attr: Vec<String>,
        /// Output as JSON array
        #[arg(long)]
        json: bool,
        /// Output only the count of matching entries
        #[arg(long)]
        count: bool,
        /// Return only the single most recent matching entry
        #[arg(long, conflicts_with = "limit")]
        latest: bool,
        /// Return at most N entries
        #[arg(long)]
        limit: Option<u64>,
        /// Skip first N entries (requires --limit)
        #[arg(long, requires = "limit")]
        offset: Option<u64>,
        /// Reverse sort order to oldest-first
        #[arg(long, short = 'r')]
        reverse: bool,
        /// Filter by substring match in entry data
        #[arg(long)]
        data: Option<String>,
        /// Only entries created after this timestamp (ISO 8601: "2024-01-15" or "2024-01-15 10:30:00")
        #[arg(long)]
        after: Option<String>,
        /// Only entries created before this timestamp (ISO 8601: "2024-01-15" or "2024-01-15 10:30:00")
        #[arg(long)]
        before: Option<String>,
    },
    /// Show entity types and label counts
    Schema,
    /// Show entry count and store size
    Stats {
        /// Output stats as a JSON object
        #[arg(long)]
        json: bool,
    },
    /// Manage built-in usage guides for AI agents
    Skills {
        #[command(subcommand)]
        action: SkillsAction,
    },
    /// Export entries as JSONL (one JSON object per line) for backup and migration
    Export {
        /// Filter by entry ID
        #[arg(long)]
        id: Option<String>,
        /// Filter by label (can be repeated, AND logic)
        #[arg(long)]
        label: Vec<String>,
        /// Exclude entries with this label (can be repeated)
        #[arg(long = "not-label")]
        not_label: Vec<String>,
        /// Filter by entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
        /// Filter by attribute key=value pair (can be repeated, AND logic)
        #[arg(long = "attr")]
        attr: Vec<String>,
        /// Filter by substring match in entry data
        #[arg(long)]
        data: Option<String>,
        /// Only entries created after this timestamp (ISO 8601)
        #[arg(long)]
        after: Option<String>,
        /// Only entries created before this timestamp (ISO 8601)
        #[arg(long)]
        before: Option<String>,
    },
    /// Import entries from JSONL on stdin (complement of export)
    Import {
        /// Parse and validate without inserting; print summary only
        #[arg(long)]
        dry_run: bool,
    },
    /// Delete ALL entries from the store (destructive, requires --confirm)
    Purge {
        /// Confirm you want to delete all data
        #[arg(long)]
        confirm: bool,
    },
    /// Generate shell completions for bash, zsh, fish, elvish, or powershell
    Completions {
        /// Shell to generate completions for
        shell: clap_complete::Shell,
    },
    /// Show store configuration and environment info
    Info {
        /// Output as JSON object
        #[arg(long)]
        json: bool,
    },
    /// List all unique labels in the store
    Labels {
        /// Output as JSON array
        #[arg(long)]
        json: bool,
        /// Show count next to each label
        #[arg(long)]
        count: bool,
    },
    /// List all unique entity types in the store
    Types {
        /// Output as JSON array
        #[arg(long)]
        json: bool,
        /// Show count next to each type
        #[arg(long)]
        count: bool,
    },
}

#[derive(Subcommand)]
enum SkillsAction {
    /// List available skills
    List,
    /// Print a skill guide
    Get {
        /// Skill name
        name: String,
        /// Include references and templates
        #[arg(long)]
        full: bool,
    },
    /// Print skill data path
    Path {
        /// Skill name
        name: String,
    },
}

// Embedded skill content (compiled into binary)
const AGENT_STORE_SKILL: &str = include_str!("../skills/agent-store/SKILL.md");
const AGENT_STORE_COMMANDS_REF: &str = include_str!("../skills/agent-store/references/commands.md");
const PATTERNS_SKILL: &str = include_str!("../skills/agent-store-patterns/SKILL.md");
const PIPELINES_SKILL: &str = include_str!("../skills/agent-store-pipelines/SKILL.md");

struct SkillInfo {
    name: &'static str,
    description: &'static str,
    content: &'static str,
    references: &'static [(&'static str, &'static str)],
    path: &'static str,
}

fn get_skills() -> Vec<SkillInfo> {
    vec![
        SkillInfo {
            name: "agent-store",
            description: "Core reference — data model, commands, configuration. Read this first.",
            content: AGENT_STORE_SKILL,
            references: &[("commands", AGENT_STORE_COMMANDS_REF)],
            path: ".agents/skills/agent-store",
        },
        SkillInfo {
            name: "agent-store-patterns",
            description: "Workflow recipes — scratchpad, task tracking, decision log, caching, knowledge base, cross-agent comms.",
            content: PATTERNS_SKILL,
            references: &[],
            path: ".agents/skills/agent-store-patterns",
        },
        SkillInfo {
            name: "agent-store-pipelines",
            description: "Shell composition — batch import/export, tool chaining, aggregation, multi-store, large data.",
            content: PIPELINES_SKILL,
            references: &[],
            path: ".agents/skills/agent-store-pipelines",
        },
    ]
}

fn strip_frontmatter(content: &str) -> &str {
    if let Some(stripped) = content.strip_prefix("---")
        && let Some(end) = stripped.find("---")
    {
        let after = &stripped[end + 3..];
        return after.trim_start_matches('\n');
    }
    content
}

fn skills_list() {
    let skills = get_skills();
    for skill in &skills {
        println!("{:<12} {}", skill.name, skill.description);
    }
}

fn skills_get(name: &str, full: bool) {
    let skills = get_skills();
    let skill = match skills.iter().find(|s| s.name == name) {
        Some(s) => s,
        None => {
            eprintln!("error: unknown skill '{name}'");
            eprintln!("available skills:");
            for s in &skills {
                eprintln!("  {}", s.name);
            }
            process::exit(1);
        }
    };

    print!("{}", strip_frontmatter(skill.content));

    if full {
        for (ref_name, ref_content) in skill.references {
            println!("\n---\n");
            println!("## Reference: {ref_name}\n");
            print!("{ref_content}");
        }
    }
}

fn skills_path(name: &str) {
    let skills = get_skills();
    let skill = match skills.iter().find(|s| s.name == name) {
        Some(s) => s,
        None => {
            eprintln!("error: unknown skill '{name}'");
            process::exit(1);
        }
    };

    println!("{}", skill.path);
}

// ---------------------------------------------------------------------------
// Skill installation & agent docs (used by init)
// ---------------------------------------------------------------------------

const INSTALLABLE_SKILLS: &[(&str, &str)] = &[
    ("agent-store", AGENT_STORE_SKILL),
    ("agent-store-patterns", PATTERNS_SKILL),
    ("agent-store-pipelines", PIPELINES_SKILL),
];

const SECTION_START: &str = "<!-- agent-store:start -->";
const SECTION_END: &str = "<!-- agent-store:end -->";

const AGENT_DOCS_SECTION: &str = "\
<!-- agent-store:start -->
## Agent data store

This project uses [agent-store](https://github.com/av/agent-store) for persistent data storage. Agents can push, pull, and query arbitrary data with no schema.

**Getting started:** Run `agent-store skills get agent-store --full` for the complete usage guide.

```bash
agent-store init                              # Initialize store + install skills
echo \"data\" | agent-store push --label tag    # Store data
agent-store query --label tag                 # Find it
agent-store pull <id>                         # Retrieve by ID
```

**Skills** (invoke via `agent-store skills get <name>`):
- `agent-store` — Core reference: data model, commands, configuration
- `agent-store-patterns` — Workflow recipes: scratchpad, task tracking, caching, knowledge base
- `agent-store-pipelines` — Shell composition: batch import/export, tool chaining, aggregation
<!-- agent-store:end -->";

const AGENT_MD_FILES: &[&str] = &["CLAUDE.md", "AGENTS.md"];

/// Install a skill file. Returns true on success, false on error.
fn install_skill(root: &Path, name: &str, content: &str) -> bool {
    let skill_dir = root.join(".agents").join("skills").join(name);
    let skill_path = skill_dir.join("SKILL.md");

    if skill_path.exists() {
        let existing = match fs::read_to_string(&skill_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
                return false;
            }
        };
        if existing == content {
            println!("  skip  .agents/skills/{name}/SKILL.md (up to date)");
        } else {
            if let Err(e) = fs::write(&skill_path, content) {
                eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
                return false;
            }
            println!("  update  .agents/skills/{name}/SKILL.md");
        }
    } else {
        if let Err(e) = fs::create_dir_all(&skill_dir) {
            eprintln!("  error  creating .agents/skills/{name}/: {e}");
            return false;
        }
        if let Err(e) = fs::write(&skill_path, content) {
            eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
            return false;
        }
        println!("  create  .agents/skills/{name}/SKILL.md");
    }
    true
}

fn is_claude_available(root: &Path) -> bool {
    if root.join(".claude").exists() {
        return true;
    }
    if let Ok(home) = std::env::var("HOME")
        && Path::new(&home).join(".claude").exists() {
            return true;
        }
    which_exists("claude")
}

fn which_exists(name: &str) -> bool {
    std::process::Command::new("which")
        .arg(name)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Create a symlink for Claude skill discovery. Returns true on success, false on error.
#[cfg(unix)]
fn link_skill_for_claude(root: &Path, name: &str) -> bool {
    let link_dir = root.join(".claude").join("skills");
    let link_path = link_dir.join(name);
    let target = Path::new("..")
        .join("..")
        .join(".agents")
        .join("skills")
        .join(name);

    if link_path.is_symlink() {
        if let Ok(current) = fs::read_link(&link_path)
            && current == target {
                println!("  skip  .claude/skills/{name} (link up to date)");
                return true;
            }
        let _ = fs::remove_file(&link_path);
    } else if link_path.exists() {
        println!("  skip  .claude/skills/{name} (exists, not a symlink)");
        return true;
    }

    if let Err(e) = fs::create_dir_all(&link_dir) {
        eprintln!("  error  creating .claude/skills/: {e}");
        return false;
    }
    match std::os::unix::fs::symlink(&target, &link_path) {
        Ok(()) => {
            println!("  link  .claude/skills/{name} -> .agents/skills/{name}");
            true
        }
        Err(e) => {
            eprintln!("  error  .claude/skills/{name}: {e}");
            false
        }
    }
}

#[cfg(not(unix))]
fn link_skill_for_claude(_root: &Path, name: &str) -> bool {
    println!("  skip  .claude/skills/{name} (symlinks not supported on this platform)");
    true
}

/// Install agent-store docs section into CLAUDE.md or AGENTS.md. Returns true on success, false on error.
fn install_agent_docs(root: &Path) -> bool {
    let mut installed = false;
    let mut had_errors = false;

    for name in AGENT_MD_FILES {
        let path = root.join(name);
        if !path.is_file() {
            continue;
        }
        let content = match fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  reading {name}: {e}");
                had_errors = true;
                continue;
            }
        };
        if content.contains(SECTION_START) {
            let start = content.find(SECTION_START).unwrap();
            let end_marker = match content[start..].find(SECTION_END) {
                Some(pos) => pos,
                None => {
                    eprintln!(
                        "  error  malformed agent-store section in {name} (missing end marker)"
                    );
                    had_errors = true;
                    continue;
                }
            };
            let end = start + end_marker + SECTION_END.len();
            let existing_section = &content[start..end];
            if existing_section == AGENT_DOCS_SECTION {
                println!("  skip  {name} (agent-store section up to date)");
            } else {
                let mut new_content = String::new();
                new_content.push_str(&content[..start]);
                new_content.push_str(AGENT_DOCS_SECTION);
                new_content.push_str(&content[end..]);
                if let Err(e) = fs::write(&path, new_content) {
                    eprintln!("  error  writing {name}: {e}");
                    had_errors = true;
                    continue;
                }
                println!("  update  {name} (agent-store section updated)");
            }
        } else {
            let mut new_content = content.clone();
            if !new_content.ends_with('\n') && !new_content.is_empty() {
                new_content.push('\n');
            }
            if !new_content.is_empty() {
                new_content.push('\n');
            }
            new_content.push_str(AGENT_DOCS_SECTION);
            new_content.push('\n');
            if let Err(e) = fs::write(&path, new_content) {
                eprintln!("  error  writing {name}: {e}");
                had_errors = true;
                continue;
            }
            println!("  update  {name} (added agent-store section)");
        }
        installed = true;
    }

    if !installed {
        let name = AGENT_MD_FILES.last().unwrap();
        let path = root.join(name);
        let mut content = String::from(AGENT_DOCS_SECTION);
        content.push('\n');
        if let Err(e) = fs::write(&path, content) {
            eprintln!("  error  creating {name}: {e}");
            return false;
        }
        println!("  create  {name} (with agent-store section)");
    }

    !had_errors
}

fn find_project_root() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if dir.join(".git").exists() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn store_dir() -> PathBuf {
    match std::env::var("AGENT_STORE_PATH") {
        Ok(p) => PathBuf::from(p),
        Err(_) => {
            let root = find_project_root()
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
            root.join(".agent-store")
        }
    }
}

fn store_db() -> PathBuf {
    store_dir().join("store.db")
}

fn open_db() -> Connection {
    let db_path = store_db();
    if !db_path.exists() {
        eprintln!("error: store not initialized (run `agent-store init` first)");
        process::exit(1);
    }
    let conn = match Connection::open(&db_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to open database: {e}");
            process::exit(1);
        }
    };
    if let Err(e) = conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;") {
        eprintln!("error: failed to set database pragmas: {e}");
        process::exit(1);
    }
    conn
}

/// Ensure .agent-store/ is in .gitignore. Returns true on success, false on error.
fn ensure_gitignore(root: &Path) -> bool {
    // Only add .gitignore protection in git repos
    if !root.join(".git").exists() {
        return true;
    }

    let gitignore_path = root.join(".gitignore");
    let entry = ".agent-store/";

    if gitignore_path.exists() {
        let content = match fs::read_to_string(&gitignore_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  reading .gitignore: {e}");
                return false;
            }
        };

        // Check if already ignored (match .agent-store/ or .agent-store as a line)
        let already_ignored = content.lines().any(|line| {
            let trimmed = line.trim();
            trimmed == ".agent-store/" || trimmed == ".agent-store"
        });

        if already_ignored {
            println!("  skip  .gitignore (.agent-store/ already ignored)");
            return true;
        }

        // Append to existing .gitignore
        let mut new_content = content.clone();
        if !new_content.is_empty() && !new_content.ends_with('\n') {
            new_content.push('\n');
        }
        new_content.push_str(entry);
        new_content.push('\n');

        if let Err(e) = fs::write(&gitignore_path, new_content) {
            eprintln!("  error  writing .gitignore: {e}");
            return false;
        }
        println!("  update  .gitignore (added .agent-store/)");
    } else {
        // Create new .gitignore
        let content = format!("{entry}\n");
        if let Err(e) = fs::write(&gitignore_path, content) {
            eprintln!("  error  creating .gitignore: {e}");
            return false;
        }
        println!("  create  .gitignore (added .agent-store/)");
    }
    true
}

fn init() {
    let dir = store_dir();
    if let Err(e) = fs::create_dir_all(&dir) {
        eprintln!("error: failed to create store directory: {e}");
        process::exit(1);
    }

    let db_path = store_db();
    let conn = match Connection::open(&db_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to open database: {e}");
            process::exit(1);
        }
    };

    if let Err(e) = conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;") {
        eprintln!("error: failed to set database pragmas: {e}");
        process::exit(1);
    }

    let schema = "
        CREATE TABLE IF NOT EXISTS entries (
            id TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            entity_type TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS labels (
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            PRIMARY KEY (entry_id, label)
        );

        CREATE TABLE IF NOT EXISTS attributes (
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (entry_id, key)
        );

        CREATE INDEX IF NOT EXISTS idx_labels_label ON labels(label);
        CREATE INDEX IF NOT EXISTS idx_attributes_key_value ON attributes(key, value);
    ";

    if let Err(e) = conn.execute_batch(schema) {
        eprintln!("error: failed to initialize schema: {e}");
        process::exit(1);
    }

    println!("initialized store at {}", db_path.display());

    let root = find_project_root().unwrap_or_else(|| std::env::current_dir().unwrap());

    let mut had_errors = false;

    if !ensure_gitignore(&root) {
        had_errors = true;
    }

    for (name, content) in INSTALLABLE_SKILLS {
        if !install_skill(&root, name, content) {
            had_errors = true;
        }
    }

    if is_claude_available(&root) {
        for (name, _) in INSTALLABLE_SKILLS {
            if !link_skill_for_claude(&root, name) {
                had_errors = true;
            }
        }
    }

    if !install_agent_docs(&root) {
        had_errors = true;
    }

    if had_errors {
        process::exit(1);
    }

    println!();
    println!("  hint   run `agent-store skills get agent-store` to get started");
}

fn parse_attr(attr: &str) -> (&str, &str) {
    match attr.split_once('=') {
        Some((k, v)) => (k, v),
        None => {
            eprintln!("error: invalid attribute format '{attr}', expected key=value");
            process::exit(1);
        }
    }
}

fn push(labels: Vec<String>, entity_type: Option<String>, quiet: bool, id_only: bool, attrs: Vec<String>, timestamp: Option<String>, file: Option<String>) {
    // Validate empty strings before any DB work
    for label in &labels {
        if label.trim().is_empty() {
            eprintln!("error: label cannot be empty");
            process::exit(1);
        }
    }
    if let Some(ref t) = entity_type
        && t.trim().is_empty() {
            eprintln!("error: type cannot be empty");
            process::exit(1);
        }
    let parsed_attrs: Vec<(&str, &str)> = attrs.iter().map(|a| parse_attr(a)).collect();
    for (key, _) in &parsed_attrs {
        if key.trim().is_empty() {
            eprintln!("error: attribute key cannot be empty");
            process::exit(1);
        }
    }

    // Check for duplicate attribute keys
    {
        let mut seen = std::collections::HashSet::new();
        for (key, _) in &parsed_attrs {
            if !seen.insert(*key) {
                eprintln!("error: duplicate attribute key '{key}'");
                process::exit(1);
            }
        }
    }

    let data = if let Some(ref path) = file {
        match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(e) => {
                eprintln!("error: failed to read file '{path}': {e}");
                process::exit(1);
            }
        }
    } else {
        let mut buf = String::new();
        if let Err(e) = io::stdin().read_to_string(&mut buf) {
            eprintln!("error: failed to read stdin: {e}");
            process::exit(1);
        }
        buf
    };

    if data.is_empty() {
        let source = if file.is_some() { "file" } else { "stdin" };
        eprintln!("error: no data provided on {source}");
        process::exit(1);
    }

    let id = Uuid::new_v4().to_string();
    let conn = open_db();

    // Wrap entire push in a transaction for atomicity
    if let Err(e) = conn.execute("BEGIN", []) {
        eprintln!("error: failed to begin transaction: {e}");
        process::exit(1);
    }

    let insert_result = if let Some(ref ts) = timestamp {
        conn.execute(
            "INSERT INTO entries (id, data, entity_type, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id, data, entity_type, ts],
        )
    } else {
        conn.execute(
            "INSERT INTO entries (id, data, entity_type) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, data, entity_type],
        )
    };
    if let Err(e) = insert_result {
        let _ = conn.execute("ROLLBACK", []);
        eprintln!("error: failed to insert entry: {e}");
        process::exit(1);
    }

    for label in &labels {
        if let Err(e) = conn.execute(
            "INSERT INTO labels (entry_id, label) VALUES (?1, ?2)",
            rusqlite::params![id, label],
        ) {
            let _ = conn.execute("ROLLBACK", []);
            eprintln!("error: failed to insert label: {e}");
            process::exit(1);
        }
    }

    for (key, value) in &parsed_attrs {
        if let Err(e) = conn.execute(
            "INSERT INTO attributes (entry_id, key, value) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, key, value],
        ) {
            let _ = conn.execute("ROLLBACK", []);
            eprintln!("error: failed to insert attribute: {e}");
            process::exit(1);
        }
    }

    if let Err(e) = conn.execute("COMMIT", []) {
        let _ = conn.execute("ROLLBACK", []);
        eprintln!("error: failed to commit transaction: {e}");
        process::exit(1);
    }

    if id_only {
        print!("{id}");
    } else if !quiet {
        println!("stored entry {id}");
    }
}

#[derive(Serialize)]
struct EntryJson {
    id: String,
    data: String,
    entity_type: Option<String>,
    created_at: String,
    labels: Vec<String>,
    attributes: HashMap<String, String>,
}

/// Shared filter arguments used by both query and export commands.
/// Eliminates duplicated SQL-building logic.
struct FilterArgs {
    labels: Vec<String>,
    not_labels: Vec<String>,
    entity_type: Option<String>,
    attrs: Vec<String>,
    data_filter: Option<String>,
    after: Option<String>,
    before: Option<String>,
    id_filter: Option<String>,
}

impl FilterArgs {
    /// Validate filter inputs. Prints error and exits on invalid input.
    fn validate(&self) {
        for label in &self.labels {
            if label.trim().is_empty() {
                eprintln!("error: label cannot be empty");
                process::exit(1);
            }
        }
        if let Some(ref t) = self.entity_type
            && t.trim().is_empty()
        {
            eprintln!("error: type cannot be empty");
            process::exit(1);
        }
        let parsed_attrs: Vec<(&str, &str)> = self.attrs.iter().map(|a| parse_attr(a)).collect();
        for (key, _) in &parsed_attrs {
            if key.trim().is_empty() {
                eprintln!("error: attribute key cannot be empty");
                process::exit(1);
            }
        }
    }

    /// Build SQL JOINs, WHERE conditions, and parameter values from the filters.
    /// Returns (joins_sql, conditions, params) where:
    /// - joins_sql: JOIN clauses to append after "FROM entries e"
    /// - conditions: WHERE condition strings (to be joined with " AND ")
    /// - params: ordered parameter values matching ?N placeholders
    fn build_filter_sql(&self) -> (String, Vec<String>, Vec<Box<dyn rusqlite::types::ToSql>>) {
        let mut joins = String::new();
        let mut conditions: Vec<String> = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        let mut param_idx = 1u32;

        let parsed_attrs: Vec<(&str, &str)> = self.attrs.iter().map(|a| parse_attr(a)).collect();

        // ID filter
        if let Some(ref id) = self.id_filter {
            conditions.push(format!("e.id = ?{param_idx}"));
            params.push(Box::new(id.clone()));
            param_idx += 1;
        }

        // Label joins + conditions (one join per label filter, AND logic)
        for (i, l) in self.labels.iter().enumerate() {
            let alias = format!("l{i}");
            joins.push_str(&format!(" JOIN labels {alias} ON e.id = {alias}.entry_id"));
            conditions.push(format!("{alias}.label = ?{param_idx}"));
            params.push(Box::new(l.clone()));
            param_idx += 1;
        }

        // Entity type condition
        if let Some(ref t) = self.entity_type {
            conditions.push(format!("e.entity_type = ?{param_idx}"));
            params.push(Box::new(t.clone()));
            param_idx += 1;
        }

        // Attribute joins + conditions (one join per attr filter, AND logic)
        for (i, (key, value)) in parsed_attrs.iter().enumerate() {
            let alias = format!("a{i}");
            joins.push_str(&format!(
                " JOIN attributes {alias} ON e.id = {alias}.entry_id"
            ));
            conditions.push(format!("{alias}.key = ?{param_idx}"));
            params.push(Box::new(key.to_string()));
            param_idx += 1;
            conditions.push(format!("{alias}.value = ?{param_idx}"));
            params.push(Box::new(value.to_string()));
            param_idx += 1;
        }

        // Data substring filter (uses parameter binding for SQL injection prevention)
        if let Some(ref substr) = self.data_filter {
            conditions.push(format!("e.data LIKE '%' || ?{param_idx} || '%'"));
            params.push(Box::new(substr.clone()));
            param_idx += 1;
        }

        // Not-label exclusion conditions (one subquery per excluded label)
        for nl in &self.not_labels {
            conditions.push(format!(
                "e.id NOT IN (SELECT entry_id FROM labels WHERE label = ?{param_idx})"
            ));
            params.push(Box::new(nl.clone()));
            param_idx += 1;
        }

        // Date range filters
        if let Some(ref ts) = self.after {
            conditions.push(format!("e.created_at > ?{param_idx}"));
            params.push(Box::new(ts.clone()));
            param_idx += 1;
        }
        if let Some(ref ts) = self.before {
            conditions.push(format!("e.created_at < ?{param_idx}"));
            params.push(Box::new(ts.clone()));
            param_idx += 1;
        }
        let _ = param_idx; // suppress unused assignment warning

        (joins, conditions, params)
    }
}

#[allow(clippy::too_many_arguments)]
fn query(
    labels: Vec<String>,
    not_labels: Vec<String>,
    entity_type: Option<String>,
    attrs: Vec<String>,
    json: bool,
    count: bool,
    latest: bool,
    limit: Option<u64>,
    offset: Option<u64>,
    reverse: bool,
    data_filter: Option<String>,
    after: Option<String>,
    before: Option<String>,
    id_filter: Option<String>,
) {
    let filters = FilterArgs {
        labels,
        not_labels,
        entity_type,
        attrs,
        data_filter,
        after,
        before,
        id_filter,
    };
    filters.validate();

    let conn = open_db();

    // Build query dynamically
    let (joins, conditions, params) = filters.build_filter_sql();

    // When --count + (--latest or --limit/--offset), select rows first then wrap in COUNT subquery
    let needs_count_subquery = count && (latest || limit.is_some());
    let select_cols = if needs_count_subquery {
        "DISTINCT e.id"
    } else if count {
        "COUNT(DISTINCT e.id)"
    } else if json {
        "e.id, e.data, e.entity_type, e.created_at"
    } else {
        "DISTINCT e.data"
    };
    let mut sql = format!("SELECT {select_cols} FROM entries e{joins}");

    if !conditions.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&conditions.join(" AND "));
    }

    // Add ORDER BY (not applied when --count without --latest or --limit)
    if !count || needs_count_subquery {
        let direction = if reverse { "ASC" } else { "DESC" };
        sql.push_str(&format!(" ORDER BY e.created_at {direction}, e.rowid {direction}"));
    }

    // Add LIMIT/OFFSET
    if latest {
        sql.push_str(" LIMIT 1");
    } else if let Some(lim) = limit {
        sql.push_str(&format!(" LIMIT {lim}"));
        if let Some(off) = offset {
            sql.push_str(&format!(" OFFSET {off}"));
        }
    }

    // Wrap in COUNT subquery when --count is combined with --latest or --limit/--offset
    if needs_count_subquery {
        sql = format!("SELECT COUNT(*) FROM ({sql})");
    }

    if count {
        // Count-only output: single integer
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        let result: i64 = match conn.query_row(&sql, params_refs.as_slice(), |row| row.get(0)) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("error: failed to execute count query: {e}");
                process::exit(1);
            }
        };
        println!("{result}");
    } else if json {
        // JSON output: collect full entry objects
        let mut stmt = match conn.prepare(&sql) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to prepare query: {e}");
                process::exit(1);
            }
        };

        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        let rows = match stmt.query_map(params_refs.as_slice(), |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
            ))
        }) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("error: failed to execute query: {e}");
                process::exit(1);
            }
        };

        let mut entries: Vec<EntryJson> = Vec::new();
        for row in rows {
            match row {
                Ok((id, data, etype, created_at)) => {
                    // Fetch labels for this entry
                    let labels = {
                        let mut lstmt =
                            match conn.prepare("SELECT label FROM labels WHERE entry_id = ?1") {
                                Ok(s) => s,
                                Err(e) => {
                                    eprintln!("error: failed to query labels: {e}");
                                    process::exit(1);
                                }
                            };
                        match lstmt.query_map(rusqlite::params![id], |r| r.get::<_, String>(0)) {
                            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                            Err(e) => {
                                eprintln!("error: failed to query labels: {e}");
                                process::exit(1);
                            }
                        }
                    };

                    // Fetch attributes for this entry
                    let attributes = {
                        let mut astmt = match conn
                            .prepare("SELECT key, value FROM attributes WHERE entry_id = ?1")
                        {
                            Ok(s) => s,
                            Err(e) => {
                                eprintln!("error: failed to query attributes: {e}");
                                process::exit(1);
                            }
                        };
                        match astmt.query_map(rusqlite::params![id], |r| {
                            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                        }) {
                            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                            Err(e) => {
                                eprintln!("error: failed to query attributes: {e}");
                                process::exit(1);
                            }
                        }
                    };

                    entries.push(EntryJson {
                        id,
                        data,
                        entity_type: etype,
                        created_at,
                        labels,
                        attributes,
                    });
                }
                Err(e) => {
                    eprintln!("error: failed to read row: {e}");
                    process::exit(1);
                }
            }
        }

        match serde_json::to_string(&entries) {
            Ok(json_str) => println!("{json_str}"),
            Err(e) => {
                eprintln!("error: failed to serialize JSON: {e}");
                process::exit(1);
            }
        }
    } else {
        // Default: newline-delimited data output
        let mut stmt = match conn.prepare(&sql) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to prepare query: {e}");
                process::exit(1);
            }
        };

        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(|p| p.as_ref()).collect();
        let rows = match stmt.query_map(params_refs.as_slice(), |row| row.get::<_, String>(0)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("error: failed to execute query: {e}");
                process::exit(1);
            }
        };

        for row in rows {
            match row {
                Ok(data) => print!("{data}"),
                Err(e) => {
                    eprintln!("error: failed to read row: {e}");
                    process::exit(1);
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn export(
    labels: Vec<String>,
    not_labels: Vec<String>,
    entity_type: Option<String>,
    attrs: Vec<String>,
    data_filter: Option<String>,
    after: Option<String>,
    before: Option<String>,
    id_filter: Option<String>,
) {
    let filters = FilterArgs {
        labels,
        not_labels,
        entity_type,
        attrs,
        data_filter,
        after,
        before,
        id_filter,
    };
    filters.validate();

    let conn = open_db();

    let (joins, conditions, params) = filters.build_filter_sql();

    let mut sql = format!("SELECT e.id, e.data, e.entity_type, e.created_at FROM entries e{joins}");

    if !conditions.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&conditions.join(" AND "));
    }

    sql.push_str(" ORDER BY e.created_at DESC, e.rowid DESC");

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: failed to prepare query: {e}");
            process::exit(1);
        }
    };

    let params_refs: Vec<&dyn rusqlite::types::ToSql> =
        params.iter().map(|p| p.as_ref()).collect();
    let rows = match stmt.query_map(params_refs.as_slice(), |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, String>(3)?,
        ))
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("error: failed to execute query: {e}");
            process::exit(1);
        }
    };

    for row in rows {
        match row {
            Ok((id, data, etype, created_at)) => {
                // Fetch labels for this entry
                let labels = {
                    let mut lstmt =
                        match conn.prepare("SELECT label FROM labels WHERE entry_id = ?1") {
                            Ok(s) => s,
                            Err(e) => {
                                eprintln!("error: failed to query labels: {e}");
                                process::exit(1);
                            }
                        };
                    match lstmt.query_map(rusqlite::params![id], |r| r.get::<_, String>(0)) {
                        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                        Err(e) => {
                            eprintln!("error: failed to query labels: {e}");
                            process::exit(1);
                        }
                    }
                };

                // Fetch attributes for this entry
                let attributes = {
                    let mut astmt = match conn
                        .prepare("SELECT key, value FROM attributes WHERE entry_id = ?1")
                    {
                        Ok(s) => s,
                        Err(e) => {
                            eprintln!("error: failed to query attributes: {e}");
                            process::exit(1);
                        }
                    };
                    match astmt.query_map(rusqlite::params![id], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    }) {
                        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                        Err(e) => {
                            eprintln!("error: failed to query attributes: {e}");
                            process::exit(1);
                        }
                    }
                };

                let entry = EntryJson {
                    id,
                    data,
                    entity_type: etype,
                    created_at,
                    labels,
                    attributes,
                };

                match serde_json::to_string(&entry) {
                    Ok(json_str) => println!("{json_str}"),
                    Err(e) => {
                        eprintln!("error: failed to serialize entry: {e}");
                        process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!("error: failed to read row: {e}");
                process::exit(1);
            }
        }
    }
}

fn pull(id: &str, json: bool, raw: bool) {
    let conn = open_db();

    if json {
        // Fetch full entry for JSON output
        let result: Result<(String, String, Option<String>, String), _> = conn.query_row(
            "SELECT id, data, entity_type, created_at FROM entries WHERE id = ?1",
            rusqlite::params![id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        );

        match result {
            Ok((eid, data, etype, created_at)) => {
                // Fetch labels
                let labels: Vec<String> = {
                    let mut lstmt = match conn.prepare("SELECT label FROM labels WHERE entry_id = ?1") {
                        Ok(s) => s,
                        Err(e) => {
                            eprintln!("error: failed to query labels: {e}");
                            process::exit(1);
                        }
                    };
                    match lstmt.query_map(rusqlite::params![eid], |r| r.get::<_, String>(0)) {
                        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                        Err(e) => {
                            eprintln!("error: failed to query labels: {e}");
                            process::exit(1);
                        }
                    }
                };

                // Fetch attributes
                let attributes: HashMap<String, String> = {
                    let mut astmt = match conn.prepare("SELECT key, value FROM attributes WHERE entry_id = ?1") {
                        Ok(s) => s,
                        Err(e) => {
                            eprintln!("error: failed to query attributes: {e}");
                            process::exit(1);
                        }
                    };
                    match astmt.query_map(rusqlite::params![eid], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    }) {
                        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                        Err(e) => {
                            eprintln!("error: failed to query attributes: {e}");
                            process::exit(1);
                        }
                    }
                };

                let entry = EntryJson {
                    id: eid,
                    data,
                    entity_type: etype,
                    created_at,
                    labels,
                    attributes,
                };

                match serde_json::to_string(&entry) {
                    Ok(json_str) => println!("{json_str}"),
                    Err(e) => {
                        eprintln!("error: failed to serialize JSON: {e}");
                        process::exit(1);
                    }
                }
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                eprintln!("error: entry not found: {id}");
                process::exit(1);
            }
            Err(e) => {
                eprintln!("error: failed to query entry: {e}");
                process::exit(1);
            }
        }
    } else {
        let result: Result<String, _> = conn.query_row(
            "SELECT data FROM entries WHERE id = ?1",
            rusqlite::params![id],
            |row| row.get(0),
        );

        match result {
            Ok(data) => {
                if raw {
                    print!("{data}");
                } else {
                    println!("{data}");
                }
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                eprintln!("error: entry not found: {id}");
                process::exit(1);
            }
            Err(e) => {
                eprintln!("error: failed to query entry: {e}");
                process::exit(1);
            }
        }
    }
}

fn schema() {
    let conn = open_db();

    // Entity types with counts
    let mut stmt = match conn.prepare(
        "SELECT COALESCE(entity_type, '(none)'), COUNT(*) FROM entries GROUP BY entity_type ORDER BY COUNT(*) DESC",
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: failed to query entity types: {e}");
            process::exit(1);
        }
    };

    let types: Vec<(String, i64)> = match stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?))) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            eprintln!("error: failed to query entity types: {e}");
            process::exit(1);
        }
    };

    println!("Entity Types:");
    if types.is_empty() {
        println!("  (none)");
    } else {
        for (t, count) in &types {
            let word = if *count == 1 { "entry" } else { "entries" };
            println!("  {t}: {count} {word}");
        }
    }

    // Labels with counts
    let mut stmt = match conn
        .prepare("SELECT label, COUNT(*) FROM labels GROUP BY label ORDER BY COUNT(*) DESC")
    {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: failed to query labels: {e}");
            process::exit(1);
        }
    };

    let labels: Vec<(String, i64)> = match stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
    {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            eprintln!("error: failed to query labels: {e}");
            process::exit(1);
        }
    };

    println!();
    println!("Labels:");
    if labels.is_empty() {
        println!("  (none)");
    } else {
        for (l, count) in &labels {
            let word = if *count == 1 { "entry" } else { "entries" };
            println!("  {l}: {count} {word}");
        }
    }
}

fn stats(json: bool) {
    let conn = open_db();

    // Total entry count
    let count: i64 = match conn.query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to count entries: {e}");
            process::exit(1);
        }
    };

    // Entity types list
    let entity_types: Vec<String> = {
        let mut stmt = match conn.prepare(
            "SELECT DISTINCT entity_type FROM entries WHERE entity_type IS NOT NULL ORDER BY entity_type",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query entity types: {e}");
                process::exit(1);
            }
        };
        match stmt.query_map([], |row| row.get::<_, String>(0)) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query entity types: {e}");
                process::exit(1);
            }
        }
    };

    // Labels list
    let labels: Vec<String> = {
        let mut stmt = match conn.prepare("SELECT DISTINCT label FROM labels ORDER BY label") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query labels: {e}");
                process::exit(1);
            }
        };
        match stmt.query_map([], |row| row.get::<_, String>(0)) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query labels: {e}");
                process::exit(1);
            }
        }
    };

    // Per-type entry counts
    let entries_by_type: HashMap<String, i64> = {
        let mut stmt = match conn.prepare(
            "SELECT entity_type, COUNT(*) FROM entries WHERE entity_type IS NOT NULL GROUP BY entity_type",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query entries by type: {e}");
                process::exit(1);
            }
        };
        match stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query entries by type: {e}");
                process::exit(1);
            }
        }
    };

    // Per-label entry counts
    let entries_by_label: HashMap<String, i64> = {
        let mut stmt = match conn.prepare(
            "SELECT label, COUNT(*) FROM labels GROUP BY label",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query entries by label: {e}");
                process::exit(1);
            }
        };
        match stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query entries by label: {e}");
                process::exit(1);
            }
        }
    };

    if json {
        #[derive(Serialize)]
        struct StatsJson {
            entries: i64,
            entity_types: Vec<String>,
            labels: Vec<String>,
            entity_type_count: usize,
            label_count: usize,
            entries_by_type: HashMap<String, i64>,
            entries_by_label: HashMap<String, i64>,
        }

        let stats = StatsJson {
            entries: count,
            entity_type_count: entity_types.len(),
            label_count: labels.len(),
            entity_types,
            labels,
            entries_by_type,
            entries_by_label,
        };

        match serde_json::to_string(&stats) {
            Ok(json_str) => println!("{json_str}"),
            Err(e) => {
                eprintln!("error: failed to serialize stats JSON: {e}");
                process::exit(1);
            }
        }
    } else {
        let word = if count == 1 { "entry" } else { "entries" };
        println!("{count} {word}");

        // Store file size
        let db_path = store_db();
        if let Ok(meta) = fs::metadata(&db_path) {
            let size = meta.len();
            let formatted = if size < 1024 {
                format!("{} B", size)
            } else if size < 1024 * 1024 {
                format!("{:.1} KB", size as f64 / 1024.0)
            } else {
                format!("{:.1} MB", size as f64 / (1024.0 * 1024.0))
            };
            println!("store size: {formatted}");
        }

        let type_count = entity_types.len();
        let type_word = if type_count == 1 {
            "entity type"
        } else {
            "entity types"
        };
        println!("{type_count} {type_word}");

        // Per-type breakdown (sorted by count descending)
        let mut type_pairs: Vec<_> = entries_by_type.iter().collect();
        type_pairs.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
        for (t, c) in &type_pairs {
            println!("  {t}: {c}");
        }

        let label_count = labels.len();
        let label_word = if label_count == 1 { "label" } else { "labels" };
        println!("{label_count} {label_word}");

        // Per-label breakdown (sorted by count descending)
        let mut label_pairs: Vec<_> = entries_by_label.iter().collect();
        label_pairs.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
        for (l, c) in &label_pairs {
            println!("  {l}: {c}");
        }
    }
}

fn import(dry_run: bool) {
    let conn = if dry_run { None } else { Some(open_db()) };

    let stdin = io::stdin();
    let mut imported = 0u64;
    let mut errors = 0u64;

    for (line_num, line_result) in io::BufRead::lines(stdin.lock()).enumerate() {
        let line_num = line_num + 1; // 1-based
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!("error: line {line_num}: failed to read: {e}");
                errors += 1;
                continue;
            }
        };

        // Skip empty lines
        if line.trim().is_empty() {
            continue;
        }

        // Parse JSON
        let obj: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("error: line {line_num}: {e}");
                errors += 1;
                continue;
            }
        };

        let obj = match obj.as_object() {
            Some(o) => o,
            None => {
                eprintln!("error: line {line_num}: expected JSON object");
                errors += 1;
                continue;
            }
        };

        // Extract fields with defaults
        let data = match obj.get("data").and_then(|v| v.as_str()) {
            Some(s) => s.to_string(),
            None => {
                eprintln!("error: line {line_num}: missing or invalid \"data\" field");
                errors += 1;
                continue;
            }
        };

        let entity_type = obj
            .get("entity_type")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let labels: Vec<String> = obj
            .get("labels")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        let attributes: Vec<(String, String)> = obj
            .get("attributes")
            .and_then(|v| v.as_object())
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();

        // Preserve created_at timestamp from JSONL when present
        let created_at = obj
            .get("created_at")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        // In dry-run mode, we validated the line — count it and move on
        if dry_run {
            // Suppress unused variable warnings by using them
            let _ = (data, entity_type, labels, attributes, created_at);
            imported += 1;
            continue;
        }

        // Generate fresh ID (always — don't preserve original id to avoid conflicts)
        let id = Uuid::new_v4().to_string();
        let conn = conn.as_ref().unwrap();

        // Insert within a transaction
        if let Err(e) = conn.execute("BEGIN", []) {
            eprintln!("error: line {line_num}: failed to begin transaction: {e}");
            errors += 1;
            continue;
        }

        let mut failed = false;

        let insert_result = if let Some(ref ts) = created_at {
            conn.execute(
                "INSERT INTO entries (id, data, entity_type, created_at) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id, data, entity_type, ts],
            )
        } else {
            conn.execute(
                "INSERT INTO entries (id, data, entity_type) VALUES (?1, ?2, ?3)",
                rusqlite::params![id, data, entity_type],
            )
        };
        if let Err(e) = insert_result {
            eprintln!("error: line {line_num}: failed to insert entry: {e}");
            failed = true;
        }

        if !failed {
            for label in &labels {
                if let Err(e) = conn.execute(
                    "INSERT INTO labels (entry_id, label) VALUES (?1, ?2)",
                    rusqlite::params![id, label],
                ) {
                    eprintln!("error: line {line_num}: failed to insert label: {e}");
                    failed = true;
                    break;
                }
            }
        }

        if !failed {
            for (key, value) in &attributes {
                if let Err(e) = conn.execute(
                    "INSERT INTO attributes (entry_id, key, value) VALUES (?1, ?2, ?3)",
                    rusqlite::params![id, key, value],
                ) {
                    eprintln!("error: line {line_num}: failed to insert attribute: {e}");
                    failed = true;
                    break;
                }
            }
        }

        if failed {
            let _ = conn.execute("ROLLBACK", []);
            errors += 1;
            continue;
        }

        if let Err(e) = conn.execute("COMMIT", []) {
            let _ = conn.execute("ROLLBACK", []);
            eprintln!("error: line {line_num}: failed to commit: {e}");
            errors += 1;
            continue;
        }

        imported += 1;
    }

    let error_part = if errors == 1 {
        "1 error".to_string()
    } else {
        format!("{errors} errors")
    };
    if dry_run {
        let word = if imported == 1 { "entry" } else { "entries" };
        eprintln!("Dry run: {imported} {word} would be imported ({error_part})");
    } else {
        eprintln!("Imported {imported} entries ({error_part})");
    }
}

fn purge(confirm: bool) {
    if !confirm {
        eprintln!("This will delete ALL entries. Run with --confirm to proceed.");
        process::exit(1);
    }

    let conn = open_db();

    // Count entries before deletion
    let count: i64 = match conn.query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to count entries: {e}");
            process::exit(1);
        }
    };

    // Delete in FK-safe order: attributes, labels, entries
    if let Err(e) = conn.execute("DELETE FROM attributes", []) {
        eprintln!("error: failed to delete attributes: {e}");
        process::exit(1);
    }
    if let Err(e) = conn.execute("DELETE FROM labels", []) {
        eprintln!("error: failed to delete labels: {e}");
        process::exit(1);
    }
    if let Err(e) = conn.execute("DELETE FROM entries", []) {
        eprintln!("error: failed to delete entries: {e}");
        process::exit(1);
    }

    let word = if count == 1 { "entry" } else { "entries" };
    println!("Purged {count} {word}");
}

fn info(json: bool) {
    let store_path = store_dir();
    let db_path = store_db();
    let version = env!("CARGO_PKG_VERSION");

    let db_size: Option<u64> = fs::metadata(&db_path).ok().map(|m| m.len());

    let agent_store_path_env = std::env::var("AGENT_STORE_PATH").ok();

    let project_root = find_project_root().map(|p| p.display().to_string());

    if json {
        #[derive(Serialize)]
        struct InfoJson {
            store_path: String,
            db_path: String,
            db_size_bytes: Option<u64>,
            agent_store_path_env: Option<String>,
            project_root: Option<String>,
            version: String,
        }

        let info = InfoJson {
            store_path: store_path.display().to_string(),
            db_path: db_path.display().to_string(),
            db_size_bytes: db_size,
            agent_store_path_env,
            project_root,
            version: version.to_string(),
        };

        match serde_json::to_string(&info) {
            Ok(json_str) => println!("{json_str}"),
            Err(e) => {
                eprintln!("error: failed to serialize info JSON: {e}");
                process::exit(1);
            }
        }
    } else {
        println!("Store path: {}", store_path.display());
        println!("Database: {}", db_path.display());
        match db_size {
            Some(size) => {
                let formatted = if size < 1024 {
                    format!("{} B", size)
                } else if size < 1024 * 1024 {
                    format!("{:.1} KB", size as f64 / 1024.0)
                } else {
                    format!("{:.1} MB", size as f64 / (1024.0 * 1024.0))
                };
                println!("Database size: {formatted}");
            }
            None => println!("Database size: (not initialized)"),
        }
        match &agent_store_path_env {
            Some(p) => println!("AGENT_STORE_PATH: {p}"),
            None => println!("AGENT_STORE_PATH: (not set)"),
        }
        match &project_root {
            Some(p) => println!("Project root: {p}"),
            None => println!("Project root: (not found)"),
        }
        println!("Version: {version}");
    }
}

fn labels_cmd(json: bool, count: bool) {
    let conn = open_db();

    if count {
        // Labels with counts
        let mut stmt = match conn
            .prepare("SELECT label, COUNT(*) FROM labels GROUP BY label ORDER BY label")
        {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query labels: {e}");
                process::exit(1);
            }
        };

        let rows: Vec<(String, i64)> =
            match stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?))) {
                Ok(r) => r.filter_map(|r| r.ok()).collect(),
                Err(e) => {
                    eprintln!("error: failed to query labels: {e}");
                    process::exit(1);
                }
            };

        if json {
            // JSON object: {"label": count, ...}
            let map: serde_json::Map<String, serde_json::Value> = rows
                .into_iter()
                .map(|(l, c)| (l, serde_json::Value::Number(c.into())))
                .collect();
            match serde_json::to_string(&map) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("error: failed to serialize JSON: {e}");
                    process::exit(1);
                }
            }
        } else {
            for (label, c) in &rows {
                println!("{label} ({c})");
            }
        }
    } else {
        // Just unique labels, sorted
        let mut stmt = match conn.prepare("SELECT DISTINCT label FROM labels ORDER BY label") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query labels: {e}");
                process::exit(1);
            }
        };

        let rows: Vec<String> = match stmt.query_map([], |row| row.get::<_, String>(0)) {
            Ok(r) => r.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query labels: {e}");
                process::exit(1);
            }
        };

        if json {
            match serde_json::to_string(&rows) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("error: failed to serialize JSON: {e}");
                    process::exit(1);
                }
            }
        } else {
            for label in &rows {
                println!("{label}");
            }
        }
    }
}

fn types_cmd(json: bool, count: bool) {
    let conn = open_db();

    if count {
        // Types with counts
        let mut stmt = match conn.prepare(
            "SELECT entity_type, COUNT(*) FROM entries WHERE entity_type IS NOT NULL GROUP BY entity_type ORDER BY entity_type",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query entity types: {e}");
                process::exit(1);
            }
        };

        let rows: Vec<(String, i64)> =
            match stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?))) {
                Ok(r) => r.filter_map(|r| r.ok()).collect(),
                Err(e) => {
                    eprintln!("error: failed to query entity types: {e}");
                    process::exit(1);
                }
            };

        if json {
            let map: serde_json::Map<String, serde_json::Value> = rows
                .into_iter()
                .map(|(t, c)| (t, serde_json::Value::Number(c.into())))
                .collect();
            match serde_json::to_string(&map) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("error: failed to serialize JSON: {e}");
                    process::exit(1);
                }
            }
        } else {
            for (etype, c) in &rows {
                println!("{etype} ({c})");
            }
        }
    } else {
        // Just unique types, sorted
        let mut stmt = match conn.prepare(
            "SELECT DISTINCT entity_type FROM entries WHERE entity_type IS NOT NULL ORDER BY entity_type",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("error: failed to query entity types: {e}");
                process::exit(1);
            }
        };

        let rows: Vec<String> = match stmt.query_map([], |row| row.get::<_, String>(0)) {
            Ok(r) => r.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                eprintln!("error: failed to query entity types: {e}");
                process::exit(1);
            }
        };

        if json {
            match serde_json::to_string(&rows) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("error: failed to serialize JSON: {e}");
                    process::exit(1);
                }
            }
        } else {
            for etype in &rows {
                println!("{etype}");
            }
        }
    }
}

fn main() {
    // Reset SIGPIPE to default so piping to head/tail/etc. exits cleanly
    // instead of panicking with "Broken pipe".
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    let cli = Cli::parse();

    match cli.command {
        Command::Init => init(),
        Command::Push {
            label,
            entity_type,
            quiet,
            id_only,
            attr,
            timestamp,
            file,
        } => push(label, entity_type, quiet, id_only, attr, timestamp, file),
        Command::Pull { id, json, raw } => pull(&id, json, raw),
        Command::Query {
            id,
            label,
            not_label,
            entity_type,
            attr,
            json,
            count,
            latest,
            limit,
            offset,
            reverse,
            data,
            after,
            before,
        } => query(label, not_label, entity_type, attr, json, count, latest, limit, offset, reverse, data, after, before, id),

        Command::Export {
            id,
            label,
            not_label,
            entity_type,
            attr,
            data,
            after,
            before,
        } => export(label, not_label, entity_type, attr, data, after, before, id),
        Command::Import { dry_run } => import(dry_run),
        Command::Purge { confirm } => purge(confirm),
        Command::Schema => schema(),
        Command::Stats { json } => stats(json),
        Command::Skills { action } => match action {
            SkillsAction::List => skills_list(),
            SkillsAction::Get { name, full } => skills_get(&name, full),
            SkillsAction::Path { name } => skills_path(&name),
        },
        Command::Info { json } => info(json),
        Command::Labels { json, count } => labels_cmd(json, count),
        Command::Types { json, count } => types_cmd(json, count),
        Command::Completions { shell } => {
            let mut cmd = Cli::command();
            clap_complete::generate(shell, &mut cmd, "agent-store", &mut std::io::stdout());
        }
    }
}
