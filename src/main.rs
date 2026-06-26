use std::env;
use std::process;

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
