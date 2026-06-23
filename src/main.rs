use clap::{Parser, Subcommand};
use rusqlite::Connection;
use std::fs;
use std::path::PathBuf;
use std::process;

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
    Push,
    /// Pull an entry by ID and print to stdout
    Pull,
    /// List and filter entries
    Query,
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

fn not_implemented(name: &str) {
    eprintln!("{name}: not yet implemented");
    process::exit(1);
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Command::Init => init(),
        Command::Push => not_implemented("push"),
        Command::Pull => not_implemented("pull"),
        Command::Query => not_implemented("query"),
        Command::Schema => not_implemented("schema"),
        Command::Stats => not_implemented("stats"),
    }
}
