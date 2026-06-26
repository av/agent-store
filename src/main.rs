use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::process;

const STORE_DIR: &str = ".agent-store";
const GITIGNORE_PATH: &str = ".gitignore";
const GITIGNORE_RULE: &str = ".agent-store/";

const USAGE: &str = "\
Usage: agent-store [OPTIONS] <COMMAND>

A project-local store for agent-facing records, links, hooks, and context.

Options:
  -h, --help    Print help
  -V, --version Print version

Commands:
  init          Initialize a project-local store
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
    ensure_gitignore_rule(Path::new(GITIGNORE_PATH), GITIGNORE_RULE)
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
