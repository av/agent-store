use clap::{Parser, Subcommand};
use rusqlite::Connection;
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
    },
    /// Pull an entry by ID and print to stdout
    Pull,
    /// List and filter entries
    Query {
        /// Filter by label
        #[arg(long)]
        label: Option<String>,
        /// Filter by entity type
        #[arg(long = "type")]
        entity_type: Option<String>,
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

fn push(labels: Vec<String>, entity_type: Option<String>, quiet: bool) {
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

    if quiet {
        println!("{id}");
    } else {
        println!("stored entry {id}");
    }
}

fn query(label: Option<String>, entity_type: Option<String>) {
    let conn = open_db();

    let (sql, params): (String, Vec<Box<dyn rusqlite::types::ToSql>>) = match (&label, &entity_type) {
        (Some(l), Some(t)) => (
            "SELECT DISTINCT e.data FROM entries e JOIN labels l ON e.id = l.entry_id WHERE l.label = ?1 AND e.entity_type = ?2".to_string(),
            vec![Box::new(l.clone()) as Box<dyn rusqlite::types::ToSql>, Box::new(t.clone())],
        ),
        (Some(l), None) => (
            "SELECT DISTINCT e.data FROM entries e JOIN labels l ON e.id = l.entry_id WHERE l.label = ?1".to_string(),
            vec![Box::new(l.clone()) as Box<dyn rusqlite::types::ToSql>],
        ),
        (None, Some(t)) => (
            "SELECT data FROM entries WHERE entity_type = ?1".to_string(),
            vec![Box::new(t.clone()) as Box<dyn rusqlite::types::ToSql>],
        ),
        (None, None) => (
            "SELECT data FROM entries".to_string(),
            vec![],
        ),
    };

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: failed to prepare query: {e}");
            process::exit(1);
        }
    };

    let params_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let rows = match stmt.query_map(params_refs.as_slice(), |row| {
        row.get::<_, String>(0)
    }) {
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

fn not_implemented(name: &str) {
    eprintln!("{name}: not yet implemented");
    process::exit(1);
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Command::Init => init(),
        Command::Push {
            label,
            entity_type,
            quiet,
        } => push(label, entity_type, quiet),
        Command::Pull => not_implemented("pull"),
        Command::Query { label, entity_type } => query(label, entity_type),
        Command::Schema => not_implemented("schema"),
        Command::Stats => not_implemented("stats"),
    }
}
