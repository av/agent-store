use clap::{Parser, Subcommand};
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
#[command(name = "agent-store")]
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
  skills path [name]                       Print skill directory path"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Initialize store, install agent skills, and set up project docs
    Init,
    /// Push data from stdin into the store
    Push {
        /// Tag entry with a label (can be repeated)
        #[arg(long)]
        label: Vec<String>,
        /// Set entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
        /// Only print the entry ID (for scripting/piping)
        #[arg(long)]
        quiet: bool,
        /// Set attribute key=value pair (can be repeated)
        #[arg(long = "attr")]
        attr: Vec<String>,
    },
    /// Pull an entry by ID and print to stdout
    Pull {
        /// Entry ID to retrieve
        id: String,
    },
    /// List and filter entries
    Query {
        /// Filter by label
        #[arg(long)]
        label: Option<String>,
        /// Filter by entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
        /// Filter by attribute key=value pair (can be repeated, AND logic)
        #[arg(long = "attr")]
        attr: Vec<String>,
        /// Output as JSON array
        #[arg(long)]
        json: bool,
    },
    /// Show entity types and label counts
    Schema,
    /// Show entry count and store size
    Stats,
    /// Manage built-in usage guides for AI agents
    Skills {
        #[command(subcommand)]
        action: SkillsAction,
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
            path: "skills/agent-store",
        },
        SkillInfo {
            name: "agent-store-patterns",
            description: "Workflow recipes — scratchpad, task tracking, decision log, caching, knowledge base, cross-agent comms.",
            content: PATTERNS_SKILL,
            references: &[],
            path: "skills/agent-store-patterns",
        },
        SkillInfo {
            name: "agent-store-pipelines",
            description: "Shell composition — batch import/export, tool chaining, aggregation, multi-store, large data.",
            content: PIPELINES_SKILL,
            references: &[],
            path: "skills/agent-store-pipelines",
        },
    ]
}

fn strip_frontmatter(content: &str) -> &str {
    if content.starts_with("---") {
        if let Some(end) = content[3..].find("---") {
            let after = &content[3 + end + 3..];
            return after.trim_start_matches('\n');
        }
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

fn install_skill(root: &Path, name: &str, content: &str) {
    let skill_dir = root.join(".agents").join("skills").join(name);
    let skill_path = skill_dir.join("SKILL.md");

    if skill_path.exists() {
        let existing = match fs::read_to_string(&skill_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
                return;
            }
        };
        if existing == content {
            println!("  skip  .agents/skills/{name}/SKILL.md (up to date)");
        } else {
            if let Err(e) = fs::write(&skill_path, content) {
                eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
                return;
            }
            println!("  update  .agents/skills/{name}/SKILL.md");
        }
    } else {
        if let Err(e) = fs::create_dir_all(&skill_dir) {
            eprintln!("  error  creating .agents/skills/{name}/: {e}");
            return;
        }
        if let Err(e) = fs::write(&skill_path, content) {
            eprintln!("  error  .agents/skills/{name}/SKILL.md: {e}");
            return;
        }
        println!("  create  .agents/skills/{name}/SKILL.md");
    }
}

fn is_claude_available(root: &Path) -> bool {
    if root.join(".claude").exists() {
        return true;
    }
    if let Ok(home) = std::env::var("HOME") {
        if Path::new(&home).join(".claude").exists() {
            return true;
        }
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

#[cfg(unix)]
fn link_skill_for_claude(root: &Path, name: &str) {
    let link_dir = root.join(".claude").join("skills");
    let link_path = link_dir.join(name);
    let target = Path::new("..")
        .join("..")
        .join(".agents")
        .join("skills")
        .join(name);

    if link_path.is_symlink() {
        if let Ok(current) = fs::read_link(&link_path) {
            if current == target {
                println!("  skip  .claude/skills/{name} (link up to date)");
                return;
            }
        }
        let _ = fs::remove_file(&link_path);
    } else if link_path.exists() {
        println!("  skip  .claude/skills/{name} (exists, not a symlink)");
        return;
    }

    if let Err(e) = fs::create_dir_all(&link_dir) {
        eprintln!("  error  creating .claude/skills/: {e}");
        return;
    }
    match std::os::unix::fs::symlink(&target, &link_path) {
        Ok(()) => println!("  link  .claude/skills/{name} -> .agents/skills/{name}"),
        Err(e) => eprintln!("  error  .claude/skills/{name}: {e}"),
    }
}

#[cfg(not(unix))]
fn link_skill_for_claude(_root: &Path, name: &str) {
    println!("  skip  .claude/skills/{name} (symlinks not supported on this platform)");
}

fn install_agent_docs(root: &Path) {
    let mut installed = false;

    for name in AGENT_MD_FILES {
        let path = root.join(name);
        if !path.is_file() {
            continue;
        }
        let content = match fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  reading {name}: {e}");
                continue;
            }
        };
        if content.contains(SECTION_START) {
            let start = content.find(SECTION_START).unwrap();
            let end_marker = match content[start..].find(SECTION_END) {
                Some(pos) => pos,
                None => {
                    eprintln!("  error  malformed agent-store section in {name} (missing end marker)");
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
            return;
        }
        println!("  create  {name} (with agent-store section)");
    }
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
        Err(_) => PathBuf::from(".agent-store"),
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
    match Connection::open(&db_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to open database: {e}");
            process::exit(1);
        }
    }
}

fn ensure_gitignore(root: &Path) {
    // Only add .gitignore protection in git repos
    if !root.join(".git").exists() {
        return;
    }

    let gitignore_path = root.join(".gitignore");
    let entry = ".agent-store/";

    if gitignore_path.exists() {
        let content = match fs::read_to_string(&gitignore_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  error  reading .gitignore: {e}");
                return;
            }
        };

        // Check if already ignored (match .agent-store/ or .agent-store as a line)
        let already_ignored = content.lines().any(|line| {
            let trimmed = line.trim();
            trimmed == ".agent-store/" || trimmed == ".agent-store"
        });

        if already_ignored {
            println!("  skip  .gitignore (.agent-store/ already ignored)");
            return;
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
            return;
        }
        println!("  update  .gitignore (added .agent-store/)");
    } else {
        // Create new .gitignore
        let content = format!("{entry}\n");
        if let Err(e) = fs::write(&gitignore_path, content) {
            eprintln!("  error  creating .gitignore: {e}");
            return;
        }
        println!("  create  .gitignore (added .agent-store/)");
    }
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

    ensure_gitignore(&root);

    for (name, content) in INSTALLABLE_SKILLS {
        install_skill(&root, name, content);
    }

    if is_claude_available(&root) {
        for (name, _) in INSTALLABLE_SKILLS {
            link_skill_for_claude(&root, name);
        }
    }

    install_agent_docs(&root);
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

fn push(labels: Vec<String>, entity_type: Option<String>, quiet: bool, attrs: Vec<String>) {
    // Validate empty strings before any DB work
    for label in &labels {
        if label.trim().is_empty() {
            eprintln!("error: label cannot be empty");
            process::exit(1);
        }
    }
    if let Some(ref t) = entity_type {
        if t.trim().is_empty() {
            eprintln!("error: type cannot be empty");
            process::exit(1);
        }
    }
    let parsed_attrs: Vec<(&str, &str)> = attrs.iter().map(|a| parse_attr(a)).collect();
    for (key, _) in &parsed_attrs {
        if key.trim().is_empty() {
            eprintln!("error: attribute key cannot be empty");
            process::exit(1);
        }
    }

    let mut data = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut data) {
        eprintln!("error: failed to read stdin: {e}");
        process::exit(1);
    }

    if data.is_empty() {
        eprintln!("error: no data provided on stdin");
        process::exit(1);
    }

    let id = Uuid::new_v4().to_string();
    let conn = open_db();

    // Wrap entire push in a transaction for atomicity
    if let Err(e) = conn.execute("BEGIN", []) {
        eprintln!("error: failed to begin transaction: {e}");
        process::exit(1);
    }

    if let Err(e) = conn.execute(
        "INSERT INTO entries (id, data, entity_type) VALUES (?1, ?2, ?3)",
        rusqlite::params![id, data, entity_type],
    ) {
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

    if quiet {
        println!("{id}");
    } else {
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

fn query(label: Option<String>, entity_type: Option<String>, attrs: Vec<String>, json: bool) {
    let conn = open_db();

    // Parse attribute filters
    let parsed_attrs: Vec<(&str, &str)> = attrs.iter().map(|a| parse_attr(a)).collect();

    // Build query dynamically — select all fields when --json, only data otherwise
    let select_cols = if json {
        "e.id, e.data, e.entity_type, e.created_at"
    } else {
        "DISTINCT e.data"
    };
    let mut sql = format!("SELECT {select_cols} FROM entries e");
    let mut conditions: Vec<String> = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
    let mut param_idx = 1u32;

    // Label join + condition
    if let Some(ref l) = label {
        sql.push_str(" JOIN labels l ON e.id = l.entry_id");
        conditions.push(format!("l.label = ?{param_idx}"));
        params.push(Box::new(l.clone()));
        param_idx += 1;
    }

    // Entity type condition
    if let Some(ref t) = entity_type {
        conditions.push(format!("e.entity_type = ?{param_idx}"));
        params.push(Box::new(t.clone()));
        param_idx += 1;
    }

    // Attribute joins + conditions (one join per attr filter, AND logic)
    for (i, (key, value)) in parsed_attrs.iter().enumerate() {
        let alias = format!("a{i}");
        sql.push_str(&format!(
            " JOIN attributes {alias} ON e.id = {alias}.entry_id"
        ));
        conditions.push(format!("{alias}.key = ?{param_idx}"));
        params.push(Box::new(key.to_string()));
        param_idx += 1;
        conditions.push(format!("{alias}.value = ?{param_idx}"));
        params.push(Box::new(value.to_string()));
        param_idx += 1;
    }

    if !conditions.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&conditions.join(" AND "));
    }

    if json {
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

fn pull(id: &str) {
    let conn = open_db();

    let result: Result<String, _> = conn.query_row(
        "SELECT data FROM entries WHERE id = ?1",
        rusqlite::params![id],
        |row| row.get(0),
    );

    match result {
        Ok(data) => print!("{data}"),
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

fn stats() {
    let conn = open_db();

    // Total entry count
    let count: i64 = match conn.query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to count entries: {e}");
            process::exit(1);
        }
    };

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

    // Entity type count
    let type_count: i64 = match conn.query_row(
        "SELECT COUNT(DISTINCT entity_type) FROM entries WHERE entity_type IS NOT NULL",
        [],
        |row| row.get(0),
    ) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: failed to count entity types: {e}");
            process::exit(1);
        }
    };
    println!("{type_count} entity types");

    // Label count
    let label_count: i64 =
        match conn.query_row("SELECT COUNT(DISTINCT label) FROM labels", [], |row| {
            row.get(0)
        }) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("error: failed to count labels: {e}");
                process::exit(1);
            }
        };
    println!("{label_count} labels");
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Command::Init => init(),
        Command::Push {
            label,
            entity_type,
            quiet,
            attr,
        } => push(label, entity_type, quiet, attr),
        Command::Pull { id } => pull(&id),
        Command::Query {
            label,
            entity_type,
            attr,
            json,
        } => query(label, entity_type, attr, json),
        Command::Schema => schema(),
        Command::Stats => stats(),
        Command::Skills { action } => match action {
            SkillsAction::List => skills_list(),
            SkillsAction::Get { name, full } => skills_get(&name, full),
            SkillsAction::Path { name } => skills_path(&name),
        },
    }
}
