use clap::{Parser, Subcommand};
use rusqlite::Connection;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process;
use uuid::Uuid;

/// CLI-first unstructured data store for agents
#[derive(Parser)]
#[command(name = "agent-store")]
#[command(
    about = "CLI-first unstructured data store for agents. Push, pull, and query arbitrary data with no schema."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Initialize a new store in .agent-store/store.db
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
    ";

    if let Err(e) = conn.execute_batch(schema) {
        eprintln!("error: failed to initialize schema: {e}");
        process::exit(1);
    }

    println!("initialized store at {}", db_path.display());
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

    if let Err(e) = conn.execute(
        "INSERT INTO entries (id, data, entity_type) VALUES (?1, ?2, ?3)",
        rusqlite::params![id, data, entity_type],
    ) {
        eprintln!("error: failed to insert entry: {e}");
        process::exit(1);
    }

    for label in &labels {
        if let Err(e) = conn.execute(
            "INSERT INTO labels (entry_id, label) VALUES (?1, ?2)",
            rusqlite::params![id, label],
        ) {
            eprintln!("error: failed to insert label: {e}");
            process::exit(1);
        }
    }

    for attr in &attrs {
        let (key, value) = parse_attr(attr);
        if let Err(e) = conn.execute(
            "INSERT INTO attributes (entry_id, key, value) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, key, value],
        ) {
            eprintln!("error: failed to insert attribute: {e}");
            process::exit(1);
        }
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
    if label.is_some() {
        sql.push_str(" JOIN labels l ON e.id = l.entry_id");
        conditions.push(format!("l.label = ?{param_idx}"));
        params.push(Box::new(label.clone().unwrap()));
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
        sql.push_str(&format!(" JOIN attributes {alias} ON e.id = {alias}.entry_id"));
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
                        let mut lstmt = conn
                            .prepare("SELECT label FROM labels WHERE entry_id = ?1")
                            .unwrap();
                        lstmt
                            .query_map(rusqlite::params![id], |r| r.get::<_, String>(0))
                            .unwrap()
                            .filter_map(|r| r.ok())
                            .collect()
                    };

                    // Fetch attributes for this entry
                    let attributes = {
                        let mut astmt = conn
                            .prepare("SELECT key, value FROM attributes WHERE entry_id = ?1")
                            .unwrap();
                        astmt
                            .query_map(rusqlite::params![id], |r| {
                                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                            })
                            .unwrap()
                            .filter_map(|r| r.ok())
                            .collect()
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

    let types: Vec<(String, i64)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .filter_map(|r| r.ok())
        .collect();

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
    let mut stmt = match conn.prepare(
        "SELECT label, COUNT(*) FROM labels GROUP BY label ORDER BY COUNT(*) DESC",
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: failed to query labels: {e}");
            process::exit(1);
        }
    };

    let labels: Vec<(String, i64)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .filter_map(|r| r.ok())
        .collect();

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
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0))
        .unwrap_or(0);

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
    let type_count: i64 = conn
        .query_row("SELECT COUNT(DISTINCT entity_type) FROM entries WHERE entity_type IS NOT NULL", [], |row| row.get(0))
        .unwrap_or(0);
    println!("{type_count} entity types");

    // Label count
    let label_count: i64 = conn
        .query_row("SELECT COUNT(DISTINCT label) FROM labels", [], |row| row.get(0))
        .unwrap_or(0);
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
        Command::Query { label, entity_type, attr, json } => query(label, entity_type, attr, json),
        Command::Schema => schema(),
        Command::Stats => stats(),
    }
}
