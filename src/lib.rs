//! Core library behind the [`agent-store`](https://github.com/av/agent-store) CLI —
//! a project-local, SQLite-backed memory and context store for AI coding agents.
//!
//! `agent-store` gives agents (and humans) a durable, queryable scratchpad inside a
//! repository: typed records with arbitrary fields, directional links between records,
//! shell hooks on mutations, and a byte-capped context summary suitable for pasting
//! into a prompt. The primary interface is the CLI; this library exposes the pieces
//! it is built from:
//!
//! - [`store`] — opening/initializing the `.agent-store/` SQLite store and CRUD for
//!   records, links, and hooks.
//! - [`query`] — the `find` query language: parsing and evaluating comparison
//!   expressions with `and`/`or`/`not`, link predicates, and sorting.
//! - [`value`] — the dynamic field value model (null, boolean, number, date,
//!   timestamp, text) and its parsing/ordering rules.
//!
//! These APIs exist to serve the CLI and are not currently semver-stable; if you want
//! the tool, see the [README](https://github.com/av/agent-store#readme) for
//! installation and usage.

pub mod query;
pub mod store;
pub mod value;
