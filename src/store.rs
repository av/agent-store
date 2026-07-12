use crate::query::Query;
use crate::value::FieldValue;
use rand::Rng;
use rusqlite::{
    params, Connection, ErrorCode, OptionalExtension, Transaction, TransactionBehavior,
};
use serde_json::json;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::hash::Hasher;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

pub const STORE_DIR: &str = ".agent-store";
const STORE_DB_FILE: &str = "store.sqlite";
const ID_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
const ID_LEN: usize = 6;
const ID_RETRIES: usize = 16;
const SQLITE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const OPEN_BUSY_RETRY_ATTEMPTS: usize = 8;
const OPEN_BUSY_RETRY_BASE: Duration = Duration::from_millis(25);

const INITIAL_SCHEMA: &str = r#"
CREATE TABLE records (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE record_fields (
    record_id TEXT NOT NULL,
    key TEXT NOT NULL,
    raw_value TEXT NOT NULL,
    text_value TEXT,
    number_value REAL,
    timestamp_value TEXT,
    boolean_value INTEGER,
    is_null INTEGER NOT NULL DEFAULT 0 CHECK (is_null IN (0, 1)),
    PRIMARY KEY (record_id, key),
    FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE
);

CREATE INDEX record_fields_key_raw_value_idx ON record_fields(key, raw_value);
CREATE INDEX record_fields_key_text_value_idx ON record_fields(key, text_value);
CREATE INDEX record_fields_key_number_value_idx ON record_fields(key, number_value);
CREATE INDEX record_fields_key_timestamp_value_idx ON record_fields(key, timestamp_value);
CREATE INDEX record_fields_key_boolean_value_idx ON record_fields(key, boolean_value);

CREATE TABLE record_links (
    from_record_id TEXT NOT NULL,
    rel TEXT NOT NULL,
    to_record_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (from_record_id, rel, to_record_id),
    FOREIGN KEY (from_record_id) REFERENCES records(id) ON DELETE CASCADE,
    FOREIGN KEY (to_record_id) REFERENCES records(id) ON DELETE CASCADE
);

CREATE TABLE store_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    record_id TEXT,
    record_snapshot TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE hooks (
    id TEXT PRIMARY KEY NOT NULL,
    event TEXT NOT NULL,
    query TEXT,
    command TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE hook_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hook_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    record_id TEXT,
    exit_status INTEGER,
    stdout_summary TEXT,
    stderr_summary TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (hook_id) REFERENCES hooks(id) ON DELETE CASCADE
);
"#;

const PRESERVE_HOOK_RUNS_AFTER_HOOK_DELETE: &str = r#"
CREATE TABLE hook_runs_rebuilt (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hook_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    record_id TEXT,
    exit_status INTEGER,
    stdout_summary TEXT,
    stderr_summary TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

INSERT INTO hook_runs_rebuilt (
    id,
    hook_id,
    event_type,
    record_id,
    exit_status,
    stdout_summary,
    stderr_summary,
    created_at
)
SELECT
    id,
    hook_id,
    event_type,
    record_id,
    exit_status,
    stdout_summary,
    stderr_summary,
    created_at
FROM hook_runs;

DROP TABLE hook_runs;
ALTER TABLE hook_runs_rebuilt RENAME TO hook_runs;
"#;

struct Migration {
    version: i64,
    name: &'static str,
    sql: &'static str,
}

const ADD_SCHEDULES: &str = r#"
CREATE TABLE schedules (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    expression TEXT NOT NULL,
    interval_seconds INTEGER,
    query TEXT,
    command TEXT NOT NULL,
    next_run_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE schedule_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    schedule_id TEXT NOT NULL,
    record_id TEXT,
    exit_status INTEGER,
    stdout_summary TEXT,
    stderr_summary TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
"#;

const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "initial_schema",
        sql: INITIAL_SCHEMA,
    },
    Migration {
        version: 2,
        name: "preserve_hook_runs_after_hook_delete",
        sql: PRESERVE_HOOK_RUNS_AFTER_HOOK_DELETE,
    },
    Migration {
        version: 3,
        name: "add_schedules",
        sql: ADD_SCHEDULES,
    },
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub id: String,
    pub kind: String,
    pub created_at: String,
    pub updated_at: String,
    pub fields: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub from_record_id: String,
    pub rel: String,
    pub to_record_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkMutation {
    pub link: Link,
    pub source: Record,
    pub source_links: Vec<LinkEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldChange {
    pub key: String,
    pub old_value: Option<String>,
    pub new_value: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordMutation {
    pub record: Record,
    pub record_links: Vec<LinkEdge>,
    pub field_changes: Vec<FieldChange>,
    /// False when the mutation was a no-op (every field already held the
    /// requested value, or none of the unset keys existed), in which case
    /// `updated_at` was left untouched and no store event was recorded.
    pub changed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkDirection {
    Out,
    In,
}

impl LinkDirection {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Out => "out",
            Self::In => "in",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkEdge {
    pub direction: LinkDirection,
    pub rel: String,
    pub peer_record_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordLinks {
    pub record_id: String,
    pub links: Vec<LinkEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hook {
    pub id: String,
    pub event: String,
    pub query: Option<String>,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookRun {
    pub id: i64,
    pub hook_id: String,
    pub event_type: String,
    pub record_id: String,
    pub exit_status: i32,
    pub stdout_summary: String,
    pub stderr_summary: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScheduleKind {
    At,
    Every,
}

impl ScheduleKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::At => "at",
            Self::Every => "every",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "at" => Some(Self::At),
            "every" => Some(Self::Every),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScheduleStatus {
    Active,
    Completed,
}

impl ScheduleStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Completed => "completed",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "active" => Some(Self::Active),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Schedule {
    pub id: String,
    pub kind: ScheduleKind,
    pub expression: String,
    pub interval_seconds: Option<i64>,
    pub query: Option<String>,
    pub command: String,
    pub next_run_at: String,
    pub status: ScheduleStatus,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduleRun {
    pub id: i64,
    pub schedule_id: String,
    pub record_id: Option<String>,
    pub exit_status: i32,
    pub stdout_summary: String,
    pub stderr_summary: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickContextSummary {
    pub record_count: i64,
    pub records_by_kind: BTreeMap<String, i64>,
    pub fields_by_kind: BTreeMap<String, Vec<String>>,
    pub status_counts_by_kind: BTreeMap<String, BTreeMap<String, i64>>,
    pub date_windows_by_kind: BTreeMap<String, BTreeMap<String, DateWindow>>,
    pub link_count: i64,
    pub links_by_relation: BTreeMap<String, i64>,
    pub hook_count: i64,
    pub schedule_summary: ScheduleSummary,
    pub latest_activity_at: Option<String>,
    pub recent_records: Vec<Record>,
}

pub const QUICK_CONTEXT_RECENT_RECORDS_LIMIT: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DateWindow {
    pub earliest: String,
    pub latest: String,
}

pub struct Store {
    conn: Connection,
    project_root: PathBuf,
}

#[derive(Debug)]
pub enum StoreError {
    Io(std::io::Error),
    StoreDirectory {
        path: PathBuf,
        source: std::io::Error,
    },
    Sql(rusqlite::Error),
    OpenStore {
        path: PathBuf,
        source: Box<StoreError>,
    },
    Json(serde_json::Error),
    MigrationChecksum {
        version: i64,
        name: String,
        expected: String,
        actual: String,
    },
    IdCollisionExhausted,
    HookIdCollisionExhausted,
    InvalidId(String),
    InvalidRelation(String),
    InvalidHookId(String),
    InvalidHookEvent(String),
    EmptyHookCommand,
    NotInitialized,
    StoreDirConflict(PathBuf),
    NotFound(String),
    LinkNotFound {
        from: String,
        rel: String,
        to: String,
    },
    SelfLink(String),
    AmbiguousId(String),
    HookNotFound(String),
    HookRunNotFound(i64),
    AmbiguousHookId(String),
    InvalidScheduleId(String),
    InvalidScheduleKind(String),
    InvalidScheduleExpression(String),
    EmptyScheduleCommand,
    ScheduleNotFound(String),
    ScheduleRunNotFound(i64),
    AmbiguousScheduleId(String),
    ScheduleIdCollisionExhausted,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::StoreDirectory { path, source } => {
                write!(
                    f,
                    "could not create store directory at {}: {source}",
                    path.display()
                )
            }
            Self::Sql(error) => write!(f, "{error}"),
            Self::OpenStore { path, source } => {
                write!(
                    f,
                    "could not open SQLite store at {}: {source}",
                    path.display()
                )
            }
            Self::Json(error) => write!(f, "{error}"),
            Self::MigrationChecksum {
                version,
                name,
                expected,
                actual,
            } => write!(
                f,
                "migration {version} ({name}) checksum mismatch: expected {expected}, found {actual}"
            ),
            Self::IdCollisionExhausted => write!(f, "could not generate a unique record ID"),
            Self::HookIdCollisionExhausted => write!(f, "could not generate a unique hook ID"),
            Self::InvalidId(id) => write!(f, "'{id}' is not a valid record ID prefix"),
            Self::InvalidRelation(rel) if rel.is_empty() => {
                write!(f, "link relation cannot be empty")
            }
            Self::InvalidRelation(rel) => {
                write!(f, "link relation '{rel}' cannot contain whitespace")
            }
            Self::InvalidHookId(id) => write!(f, "'{id}' is not a valid hook ID prefix"),
            Self::InvalidHookEvent(event) => write!(
                f,
                "hook event '{event}' is not supported; expected create, set, unset, rm, link, or unlink"
            ),
            Self::EmptyHookCommand => write!(f, "hook command cannot be empty"),
            Self::NotInitialized => {
                write!(f, "no agent-store found; run 'agent-store init' first")
            }
            Self::StoreDirConflict(path) => write!(
                f,
                "{} exists but is not a directory; remove or rename it, then run 'agent-store init'",
                path.display()
            ),
            Self::NotFound(id) => write!(f, "record '{id}' was not found"),
            Self::LinkNotFound { from, rel, to } => {
                write!(f, "no such link {from} {rel} {to}")
            }
            Self::SelfLink(id) => {
                write!(f, "cannot link a record to itself ({id})")
            }
            Self::AmbiguousId(id) => write!(f, "record ID prefix '{id}' matches multiple records"),
            Self::HookNotFound(id) => write!(f, "hook '{id}' was not found"),
            Self::HookRunNotFound(id) => write!(f, "hook run {id} was not found"),
            Self::AmbiguousHookId(id) => {
                write!(f, "hook ID prefix '{id}' matches multiple hooks")
            }
            Self::InvalidScheduleId(id) => {
                write!(f, "'{id}' is not a valid schedule ID prefix")
            }
            Self::InvalidScheduleKind(kind) => {
                write!(f, "schedule kind '{kind}' is not supported; expected at or every")
            }
            Self::InvalidScheduleExpression(expr) => write!(
                f,
                "invalid schedule expression '{expr}'; expected a duration (e.g. 5m, 1h, 2d) or timestamp"
            ),
            Self::EmptyScheduleCommand => write!(f, "schedule command cannot be empty"),
            Self::ScheduleNotFound(id) => write!(f, "schedule '{id}' was not found"),
            Self::ScheduleRunNotFound(id) => write!(f, "schedule run {id} was not found"),
            Self::AmbiguousScheduleId(id) => {
                write!(f, "schedule ID prefix '{id}' matches multiple schedules")
            }
            Self::ScheduleIdCollisionExhausted => {
                write!(f, "could not generate a unique schedule ID")
            }
        }
    }
}

impl Error for StoreError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::StoreDirectory { source, .. } => Some(source),
            Self::Sql(error) => Some(error),
            Self::OpenStore { source, .. } => Some(source.as_ref()),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl StoreError {
    fn open_store_context(path: &Path, source: StoreError) -> Self {
        Self::OpenStore {
            path: path.to_path_buf(),
            source: Box::new(source),
        }
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sql(error)
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub type StoreResult<T> = Result<T, StoreError>;

fn find_project_root(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .find(|candidate| candidate.join(STORE_DIR).is_dir())
        .map(Path::to_path_buf)
}

/// Finds a `.agent-store` path on the walk up from `start` that exists but is
/// not a directory (e.g. a stray file), so commands can explain the conflict
/// instead of pointing users at `agent-store init` in a loop.
fn find_store_dir_conflict(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .map(|candidate| candidate.join(STORE_DIR))
        .find(|path| !path.is_dir() && path.symlink_metadata().is_ok())
}

impl Store {
    pub fn open_project() -> StoreResult<Self> {
        let current_dir = std::env::current_dir()?;
        let project_root = match find_project_root(&current_dir) {
            Some(root) => root,
            None => {
                if let Some(conflict) = find_store_dir_conflict(&current_dir) {
                    return Err(StoreError::StoreDirConflict(conflict));
                }
                return Err(StoreError::NotInitialized);
            }
        };
        Self::open_project_root(project_root)
    }

    pub fn open_project_root(project_root: impl AsRef<Path>) -> StoreResult<Self> {
        let project_root = project_root.as_ref().to_path_buf();
        let store_dir = project_root.join(STORE_DIR);
        fs::create_dir_all(&store_dir).map_err(|source| StoreError::StoreDirectory {
            path: store_dir,
            source,
        })?;
        Self::open_at(project_root)
    }

    #[cfg(test)]
    fn open(path: PathBuf) -> StoreResult<Self> {
        let project_root = path
            .parent()
            .map(|db_dir| {
                if db_dir.file_name().is_some_and(|name| name == STORE_DIR) {
                    db_dir.parent().unwrap_or_else(|| Path::new("."))
                } else {
                    db_dir
                }
            })
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        Self::open_db(path, project_root)
    }

    fn open_at(project_root: PathBuf) -> StoreResult<Self> {
        Self::open_db(
            project_root.join(STORE_DIR).join(STORE_DB_FILE),
            project_root,
        )
    }

    fn open_db(path: PathBuf, project_root: PathBuf) -> StoreResult<Self> {
        for attempt in 0..OPEN_BUSY_RETRY_ATTEMPTS {
            match Self::open_db_once(&path, &project_root) {
                Ok(store) => return Ok(store),
                Err(error)
                    if attempt + 1 < OPEN_BUSY_RETRY_ATTEMPTS
                        && is_transient_open_error(&error) =>
                {
                    thread::sleep(open_retry_delay(attempt));
                }
                Err(error) => return Err(error),
            }
        }

        unreachable!("open_db retry loop always returns before exhausting attempts")
    }

    fn open_db_once(path: &Path, project_root: &Path) -> StoreResult<Self> {
        let mut conn = Connection::open(path)
            .map_err(|source| StoreError::open_store_context(path, StoreError::Sql(source)))?;
        conn.busy_timeout(SQLITE_BUSY_TIMEOUT)
            .map_err(|source| StoreError::open_store_context(path, StoreError::Sql(source)))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|source| StoreError::open_store_context(path, StoreError::Sql(source)))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|source| StoreError::open_store_context(path, StoreError::Sql(source)))?;
        run_migrations(&mut conn).map_err(|source| StoreError::open_store_context(path, source))?;
        Ok(Self {
            conn,
            project_root: project_root.to_path_buf(),
        })
    }

    pub fn project_root(&self) -> &Path {
        &self.project_root
    }

    pub fn create_record(
        &mut self,
        kind: &str,
        fields: BTreeMap<String, String>,
    ) -> StoreResult<Record> {
        self.create_record_with_id_generator(kind, fields, generate_id)
    }

    fn create_record_with_id_generator(
        &mut self,
        kind: &str,
        fields: BTreeMap<String, String>,
        mut next_id: impl FnMut() -> String,
    ) -> StoreResult<Record> {
        for _ in 0..ID_RETRIES {
            let id = next_id();
            let tx = self
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)?;
            match insert_record(&tx, &id, kind, &fields) {
                Ok(()) => {
                    let record = get_record_by_id(&tx, &id)?;
                    insert_store_event(&tx, "create", &record)?;
                    tx.commit()?;
                    return Ok(record);
                }
                Err(error) if is_constraint_violation(&error) => continue,
                Err(error) => return Err(StoreError::Sql(error)),
            }
        }

        Err(StoreError::IdCollisionExhausted)
    }

    pub fn get_record(&self, id_prefix: &str) -> StoreResult<Record> {
        validate_id_prefix(id_prefix)?;
        let tx = self.conn.unchecked_transaction()?;
        let id = resolve_id(&tx, id_prefix)?;
        let record = get_record_by_id(&tx, &id)?;
        tx.commit()?;

        Ok(record)
    }

    pub fn find_records(&self, query: Option<&Query>) -> StoreResult<Vec<Record>> {
        let tx = self.conn.unchecked_transaction()?;
        let mut stmt = tx.prepare("SELECT id FROM records ORDER BY created_at, rowid")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let ids: Vec<String> = rows.collect::<Result<_, _>>()?;
        let mut records = Vec::new();
        let uses_links = query.is_some_and(Query::uses_links);

        for id in ids {
            let record = get_record_by_id(&tx, &id)?;
            let matches = match query {
                None => true,
                Some(query) if uses_links => {
                    let links = links_for_record_id(&tx, &id)?;
                    query.matches_with_links(&record, &links)
                }
                Some(query) => query.matches(&record),
            };

            if matches {
                records.push(record);
            }
        }

        drop(stmt);
        tx.commit()?;

        Ok(records)
    }

    pub fn quick_context_summary(&self) -> StoreResult<QuickContextSummary> {
        let tx = self.conn.unchecked_transaction()?;
        let record_count = tx.query_row("SELECT COUNT(*) FROM records", [], |row| row.get(0))?;

        let mut records_by_kind = BTreeMap::new();
        let mut stmt = tx.prepare(
            r#"
            SELECT kind, COUNT(*)
            FROM records
            GROUP BY kind
            ORDER BY kind
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        for row in rows {
            let (kind, count) = row?;
            records_by_kind.insert(kind, count);
        }
        drop(stmt);

        let mut fields_by_kind = records_by_kind
            .keys()
            .map(|kind| (kind.clone(), Vec::new()))
            .collect::<BTreeMap<_, _>>();
        let mut stmt = tx.prepare(
            r#"
            SELECT records.kind, record_fields.key
            FROM records
            JOIN record_fields ON record_fields.record_id = records.id
            GROUP BY records.kind, record_fields.key
            ORDER BY records.kind, record_fields.key
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (kind, field_name) = row?;
            fields_by_kind.entry(kind).or_default().push(field_name);
        }
        drop(stmt);

        let mut status_counts_by_kind = BTreeMap::new();
        let mut stmt = tx.prepare(
            r#"
            SELECT records.kind, record_fields.raw_value, COUNT(*)
            FROM records
            JOIN record_fields ON record_fields.record_id = records.id
            WHERE record_fields.key = 'status'
            GROUP BY records.kind, record_fields.raw_value
            ORDER BY records.kind, record_fields.raw_value
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;
        for row in rows {
            let (kind, status, count) = row?;
            status_counts_by_kind
                .entry(kind)
                .or_insert_with(BTreeMap::new)
                .insert(status, count);
        }
        drop(stmt);

        let mut date_windows_by_kind = BTreeMap::new();
        let mut stmt = tx.prepare(
            r#"
            SELECT records.kind, record_fields.key, MIN(record_fields.timestamp_value), MAX(record_fields.timestamp_value)
            FROM records
            JOIN record_fields ON record_fields.record_id = records.id
            WHERE record_fields.key IN ('due', 'start')
              AND record_fields.timestamp_value IS NOT NULL
            GROUP BY records.kind, record_fields.key
            ORDER BY records.kind, record_fields.key
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                DateWindow {
                    earliest: row.get(2)?,
                    latest: row.get(3)?,
                },
            ))
        })?;
        for row in rows {
            let (kind, field, window) = row?;
            date_windows_by_kind
                .entry(kind)
                .or_insert_with(BTreeMap::new)
                .insert(field, window);
        }
        drop(stmt);

        let link_count = tx.query_row("SELECT COUNT(*) FROM record_links", [], |row| row.get(0))?;
        let mut links_by_relation = BTreeMap::new();
        let mut stmt = tx.prepare(
            r#"
            SELECT rel, COUNT(*)
            FROM record_links
            GROUP BY rel
            ORDER BY rel
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        for row in rows {
            let (rel, count) = row?;
            links_by_relation.insert(rel, count);
        }
        drop(stmt);

        let mut recent_records = Vec::new();
        let mut stmt = tx.prepare(
            r#"
            SELECT id
            FROM records
            ORDER BY updated_at DESC, rowid DESC
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map([QUICK_CONTEXT_RECENT_RECORDS_LIMIT as i64], |row| {
            row.get::<_, String>(0)
        })?;
        let recent_ids: Vec<String> = rows.collect::<Result<_, _>>()?;
        drop(stmt);
        for id in recent_ids {
            recent_records.push(get_record_by_id(&tx, &id)?);
        }

        let hook_count = tx.query_row("SELECT COUNT(*) FROM hooks", [], |row| row.get(0))?;

        let active_schedule_count = tx.query_row(
            "SELECT COUNT(*) FROM schedules WHERE status = 'active'",
            [],
            |row| row.get(0),
        )?;
        let completed_schedule_count = tx.query_row(
            "SELECT COUNT(*) FROM schedules WHERE status = 'completed'",
            [],
            |row| row.get(0),
        )?;
        let next_schedule_run_at: Option<String> = tx
            .query_row(
                "SELECT MIN(next_run_at) FROM schedules WHERE status = 'active'",
                [],
                |row| row.get(0),
            )
            .optional()?
            .flatten();

        let latest_activity_at = tx
            .query_row(
                "SELECT created_at FROM store_events ORDER BY id DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .optional()?;

        tx.commit()?;

        Ok(QuickContextSummary {
            record_count,
            records_by_kind,
            fields_by_kind,
            status_counts_by_kind,
            date_windows_by_kind,
            link_count,
            links_by_relation,
            hook_count,
            schedule_summary: ScheduleSummary {
                active_count: active_schedule_count,
                completed_count: completed_schedule_count,
                next_run_at: next_schedule_run_at,
            },
            latest_activity_at,
            recent_records,
        })
    }

    pub fn set_record(
        &mut self,
        id_prefix: &str,
        fields: BTreeMap<String, String>,
    ) -> StoreResult<Record> {
        Ok(self.set_record_with_snapshot(id_prefix, fields)?.record)
    }

    pub fn set_record_with_snapshot(
        &mut self,
        id_prefix: &str,
        fields: BTreeMap<String, String>,
    ) -> StoreResult<RecordMutation> {
        validate_id_prefix(id_prefix)?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = resolve_id(&tx, id_prefix)?;
        let before = get_record_by_id(&tx, &id)?;
        let field_changes = fields
            .iter()
            .map(|(key, value)| FieldChange {
                key: key.clone(),
                old_value: before.fields.get(key).cloned(),
                new_value: Some(value.clone()),
            })
            .collect();

        let changed = fields
            .iter()
            .any(|(key, value)| before.fields.get(key) != Some(value));
        let record = if changed {
            for (key, value) in &fields {
                upsert_field(&tx, &id, key, value)?;
            }
            tx.execute(
                "UPDATE records SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
                params![&id],
            )?;
            let record = get_record_by_id(&tx, &id)?;
            insert_store_event(&tx, "set", &record)?;
            record
        } else {
            before
        };
        let record_links = links_for_record_id(&tx, &id)?;
        tx.commit()?;

        Ok(RecordMutation {
            record,
            record_links,
            field_changes,
            changed,
        })
    }

    pub fn unset_record(&mut self, id_prefix: &str, keys: Vec<String>) -> StoreResult<Record> {
        Ok(self.unset_record_with_snapshot(id_prefix, keys)?.record)
    }

    pub fn unset_record_with_snapshot(
        &mut self,
        id_prefix: &str,
        keys: Vec<String>,
    ) -> StoreResult<RecordMutation> {
        validate_id_prefix(id_prefix)?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = resolve_id(&tx, id_prefix)?;
        let before = get_record_by_id(&tx, &id)?;
        let field_changes = keys
            .iter()
            .map(|key| FieldChange {
                key: key.clone(),
                old_value: before.fields.get(key).cloned(),
                new_value: None,
            })
            .collect();

        let changed = keys.iter().any(|key| before.fields.contains_key(key));
        let record = if changed {
            for key in &keys {
                tx.execute(
                    "DELETE FROM record_fields WHERE record_id = ?1 AND key = ?2",
                    params![&id, key],
                )?;
            }
            tx.execute(
                "UPDATE records SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
                params![&id],
            )?;
            let record = get_record_by_id(&tx, &id)?;
            insert_store_event(&tx, "unset", &record)?;
            record
        } else {
            before
        };
        let record_links = links_for_record_id(&tx, &id)?;
        tx.commit()?;

        Ok(RecordMutation {
            record,
            record_links,
            field_changes,
            changed,
        })
    }

    pub fn delete_record(&mut self, id_prefix: &str) -> StoreResult<Record> {
        Ok(self.delete_record_with_snapshot(id_prefix)?.record)
    }

    pub fn delete_record_with_snapshot(&mut self, id_prefix: &str) -> StoreResult<RecordMutation> {
        validate_id_prefix(id_prefix)?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = resolve_id(&tx, id_prefix)?;
        let record = get_record_by_id(&tx, &id)?;
        let record_links = links_for_record_id(&tx, &id)?;

        insert_store_event(&tx, "rm", &record)?;
        tx.execute("DELETE FROM records WHERE id = ?1", params![&record.id])?;
        tx.commit()?;

        Ok(RecordMutation {
            record,
            record_links,
            field_changes: Vec::new(),
            changed: true,
        })
    }

    pub fn link_records(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<Link> {
        Ok(self
            .link_records_with_snapshot(from_prefix, rel, to_prefix)?
            .link)
    }

    pub fn link_records_with_snapshot(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<LinkMutation> {
        validate_id_prefix(from_prefix)?;
        validate_id_prefix(to_prefix)?;
        validate_relation(rel)?;

        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let from_id = resolve_id(&tx, from_prefix)?;
        let to_id = resolve_id(&tx, to_prefix)?;
        if from_id == to_id {
            return Err(StoreError::SelfLink(from_id));
        }
        tx.execute(
            r#"
            INSERT OR IGNORE INTO record_links (from_record_id, rel, to_record_id)
            VALUES (?1, ?2, ?3)
            "#,
            params![&from_id, rel, &to_id],
        )?;
        let source = get_record_by_id(&tx, &from_id)?;
        let source_links = links_for_record_id(&tx, &from_id)?;
        insert_store_event(&tx, "link", &source)?;
        tx.commit()?;

        let link = Link {
            from_record_id: from_id,
            rel: rel.to_owned(),
            to_record_id: to_id,
        };

        Ok(LinkMutation {
            link,
            source,
            source_links,
        })
    }

    pub fn unlink_records(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<Link> {
        Ok(self
            .unlink_records_with_snapshot(from_prefix, rel, to_prefix)?
            .link)
    }

    pub fn unlink_records_with_snapshot(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<LinkMutation> {
        validate_id_prefix(from_prefix)?;
        validate_id_prefix(to_prefix)?;
        validate_relation(rel)?;

        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let from_id = resolve_id(&tx, from_prefix)?;
        let to_id = resolve_id(&tx, to_prefix)?;
        let deleted = tx.execute(
            r#"
            DELETE FROM record_links
            WHERE from_record_id = ?1 AND rel = ?2 AND to_record_id = ?3
            "#,
            params![&from_id, rel, &to_id],
        )?;
        if deleted == 0 {
            return Err(StoreError::LinkNotFound {
                from: from_id,
                rel: rel.to_owned(),
                to: to_id,
            });
        }
        let source = get_record_by_id(&tx, &from_id)?;
        let source_links = links_for_record_id(&tx, &from_id)?;
        insert_store_event(&tx, "unlink", &source)?;
        tx.commit()?;

        let link = Link {
            from_record_id: from_id,
            rel: rel.to_owned(),
            to_record_id: to_id,
        };

        Ok(LinkMutation {
            link,
            source,
            source_links,
        })
    }

    pub fn links_for_record(&self, id_prefix: &str) -> StoreResult<RecordLinks> {
        validate_id_prefix(id_prefix)?;
        let tx = self.conn.unchecked_transaction()?;
        let record_id = resolve_id(&tx, id_prefix)?;
        let links = links_for_record_id(&tx, &record_id)?;
        tx.commit()?;

        Ok(RecordLinks { record_id, links })
    }

    pub fn add_hook(
        &mut self,
        event: &str,
        query: Option<String>,
        command: &str,
    ) -> StoreResult<Hook> {
        validate_hook_event(event)?;
        validate_hook_command(command)?;

        for _ in 0..ID_RETRIES {
            let id = generate_id();
            let tx = self
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)?;
            match tx.execute(
                r#"
                INSERT INTO hooks (id, event, query, command)
                VALUES (?1, ?2, ?3, ?4)
                "#,
                params![&id, event, query.as_deref(), command],
            ) {
                Ok(_) => {
                    tx.commit()?;
                    return Ok(Hook {
                        id,
                        event: event.to_owned(),
                        query,
                        command: command.to_owned(),
                    });
                }
                Err(error) if is_constraint_violation(&error) => continue,
                Err(error) => return Err(StoreError::Sql(error)),
            }
        }

        Err(StoreError::IdCollisionExhausted)
    }

    pub fn list_hooks(&self) -> StoreResult<Vec<Hook>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, event, query, command
            FROM hooks
            ORDER BY rowid
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Hook {
                id: row.get(0)?,
                event: row.get(1)?,
                query: row.get(2)?,
                command: row.get(3)?,
            })
        })?;

        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn delete_hook(&mut self, id_prefix: &str) -> StoreResult<Hook> {
        validate_hook_id_prefix(id_prefix)?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = resolve_hook_id(&tx, id_prefix)?;
        let hook = get_hook_by_id(&tx, &id)?;
        tx.execute("DELETE FROM hooks WHERE id = ?1", params![&hook.id])?;
        tx.commit()?;

        Ok(hook)
    }

    pub fn record_hook_run(
        &mut self,
        hook_id: &str,
        event_type: &str,
        record_id: &str,
        exit_status: i32,
        stdout_summary: &str,
        stderr_summary: &str,
    ) -> StoreResult<HookRun> {
        validate_hook_id_prefix(hook_id)?;
        validate_hook_event(event_type)?;
        validate_id_prefix(record_id)?;

        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            r#"
            INSERT INTO hook_runs (
                hook_id,
                event_type,
                record_id,
                exit_status,
                stdout_summary,
                stderr_summary
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                hook_id,
                event_type,
                record_id,
                exit_status,
                stdout_summary,
                stderr_summary
            ],
        )?;
        let id = tx.last_insert_rowid();
        let run = get_hook_run_by_id(&tx, id)?;
        tx.commit()?;

        Ok(run)
    }

    pub fn list_hook_runs(&self) -> StoreResult<Vec<HookRun>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary, created_at
            FROM hook_runs
            ORDER BY id
            "#,
        )?;
        let rows = stmt.query_map([], hook_run_from_row)?;

        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Returns the most recent hook runs, newest first.
    pub fn list_recent_hook_runs(&self, limit: usize) -> StoreResult<Vec<HookRun>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary, created_at
            FROM hook_runs
            ORDER BY id DESC
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map(params![limit as i64], hook_run_from_row)?;

        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn get_hook_run(&self, id: i64) -> StoreResult<HookRun> {
        match get_hook_run_by_id(&self.conn, id) {
            Err(StoreError::Sql(rusqlite::Error::QueryReturnedNoRows)) => {
                Err(StoreError::HookRunNotFound(id))
            }
            result => result,
        }
    }

    pub fn now_plus_seconds(&self, seconds: i64) -> StoreResult<String> {
        self.conn
            .query_row(
                "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now', printf('+%d seconds', ?1))",
                params![seconds],
                |row| row.get(0),
            )
            .map_err(StoreError::from)
    }

    pub fn add_schedule(
        &mut self,
        kind: &str,
        expression: &str,
        interval_seconds: Option<i64>,
        next_run_at: &str,
        query: Option<String>,
        command: &str,
    ) -> StoreResult<Schedule> {
        validate_schedule_kind(kind)?;
        validate_schedule_command(command)?;

        for _ in 0..ID_RETRIES {
            let id = generate_id();
            let tx = self
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)?;
            match tx.execute(
                r#"
                INSERT INTO schedules (id, kind, expression, interval_seconds, query, command, next_run_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                "#,
                params![
                    &id,
                    kind,
                    expression,
                    interval_seconds,
                    query.as_deref(),
                    command,
                    next_run_at
                ],
            ) {
                Ok(_) => {
                    let schedule = get_schedule_by_id(&tx, &id)?;
                    tx.commit()?;
                    return Ok(schedule);
                }
                Err(error) if is_constraint_violation(&error) => continue,
                Err(error) => return Err(StoreError::Sql(error)),
            }
        }

        Err(StoreError::ScheduleIdCollisionExhausted)
    }

    pub fn list_schedules(&self) -> StoreResult<Vec<Schedule>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, kind, expression, interval_seconds, query, command, next_run_at, status, created_at
            FROM schedules
            ORDER BY created_at, rowid
            "#,
        )?;
        let rows = stmt.query_map([], schedule_from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn delete_schedule(&mut self, id_prefix: &str) -> StoreResult<Schedule> {
        validate_schedule_id_prefix(id_prefix)?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = resolve_schedule_id(&tx, id_prefix)?;
        let schedule = get_schedule_by_id(&tx, &id)?;
        tx.execute("DELETE FROM schedules WHERE id = ?1", params![&schedule.id])?;
        tx.commit()?;
        Ok(schedule)
    }

    pub fn tick_due_schedules(&mut self) -> StoreResult<Vec<Schedule>> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;

        let mut stmt = tx.prepare(
            r#"
            SELECT id, kind, expression, interval_seconds, query, command, next_run_at, status, created_at
            FROM schedules
            WHERE status = 'active'
              AND next_run_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            ORDER BY next_run_at
            "#,
        )?;
        let rows = stmt.query_map([], schedule_from_row)?;
        let due: Vec<Schedule> = rows.collect::<Result<_, _>>()?;
        drop(stmt);

        for schedule in &due {
            match schedule.kind {
                ScheduleKind::At => {
                    tx.execute(
                        "UPDATE schedules SET status = 'completed' WHERE id = ?1",
                        params![&schedule.id],
                    )?;
                }
                ScheduleKind::Every => {
                    let interval = schedule.interval_seconds.unwrap_or(0);
                    tx.execute(
                        r#"
                        UPDATE schedules
                        SET next_run_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', printf('+%d seconds', ?2))
                        WHERE id = ?1
                        "#,
                        params![&schedule.id, interval],
                    )?;
                }
            }
        }

        tx.commit()?;
        Ok(due)
    }

    pub fn record_schedule_run(
        &mut self,
        schedule_id: &str,
        record_id: Option<&str>,
        exit_status: i32,
        stdout_summary: &str,
        stderr_summary: &str,
    ) -> StoreResult<ScheduleRun> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            r#"
            INSERT INTO schedule_runs (
                schedule_id, record_id, exit_status, stdout_summary, stderr_summary
            )
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                schedule_id,
                record_id,
                exit_status,
                stdout_summary,
                stderr_summary
            ],
        )?;
        let id = tx.last_insert_rowid();
        let run = get_schedule_run_by_id(&tx, id)?;
        tx.commit()?;
        Ok(run)
    }

    pub fn list_recent_schedule_runs(&self, limit: usize) -> StoreResult<Vec<ScheduleRun>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, schedule_id, record_id, exit_status, stdout_summary, stderr_summary, created_at
            FROM schedule_runs
            ORDER BY id DESC
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map(params![limit as i64], schedule_run_from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn get_schedule_run(&self, id: i64) -> StoreResult<ScheduleRun> {
        match get_schedule_run_by_id(&self.conn, id) {
            Err(StoreError::Sql(rusqlite::Error::QueryReturnedNoRows)) => {
                Err(StoreError::ScheduleRunNotFound(id))
            }
            result => result,
        }
    }

    pub fn schedule_summary(&self) -> StoreResult<ScheduleSummary> {
        let tx = self.conn.unchecked_transaction()?;
        let active_count = tx.query_row(
            "SELECT COUNT(*) FROM schedules WHERE status = 'active'",
            [],
            |row| row.get(0),
        )?;
        let completed_count = tx.query_row(
            "SELECT COUNT(*) FROM schedules WHERE status = 'completed'",
            [],
            |row| row.get(0),
        )?;
        let next_run_at: Option<String> = tx
            .query_row(
                "SELECT MIN(next_run_at) FROM schedules WHERE status = 'active'",
                [],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        tx.commit()?;
        Ok(ScheduleSummary {
            active_count,
            completed_count,
            next_run_at,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduleSummary {
    pub active_count: i64,
    pub completed_count: i64,
    pub next_run_at: Option<String>,
}

fn get_hook_by_id(conn: &Connection, id: &str) -> StoreResult<Hook> {
    conn.query_row(
        r#"
        SELECT id, event, query, command
        FROM hooks
        WHERE id = ?1
        "#,
        params![id],
        |row| {
            Ok(Hook {
                id: row.get(0)?,
                event: row.get(1)?,
                query: row.get(2)?,
                command: row.get(3)?,
            })
        },
    )
    .map_err(StoreError::from)
}

fn get_hook_run_by_id(conn: &Connection, id: i64) -> StoreResult<HookRun> {
    conn.query_row(
        r#"
        SELECT id, hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary, created_at
        FROM hook_runs
        WHERE id = ?1
        "#,
        params![id],
        hook_run_from_row,
    )
    .map_err(StoreError::from)
}

fn hook_run_from_row(row: &rusqlite::Row<'_>) -> Result<HookRun, rusqlite::Error> {
    Ok(HookRun {
        id: row.get(0)?,
        hook_id: row.get(1)?,
        event_type: row.get(2)?,
        record_id: row.get(3)?,
        exit_status: row.get(4)?,
        stdout_summary: row.get(5)?,
        stderr_summary: row.get(6)?,
        created_at: row.get(7)?,
    })
}

fn get_schedule_by_id(conn: &Connection, id: &str) -> StoreResult<Schedule> {
    conn.query_row(
        r#"
        SELECT id, kind, expression, interval_seconds, query, command, next_run_at, status, created_at
        FROM schedules
        WHERE id = ?1
        "#,
        params![id],
        schedule_from_row,
    )
    .map_err(StoreError::from)
}

fn schedule_from_row(row: &rusqlite::Row<'_>) -> Result<Schedule, rusqlite::Error> {
    let kind_str: String = row.get(1)?;
    let status_str: String = row.get(7)?;
    Ok(Schedule {
        id: row.get(0)?,
        kind: ScheduleKind::parse(&kind_str).unwrap_or(ScheduleKind::At),
        expression: row.get(2)?,
        interval_seconds: row.get(3)?,
        query: row.get(4)?,
        command: row.get(5)?,
        next_run_at: row.get(6)?,
        status: ScheduleStatus::parse(&status_str).unwrap_or(ScheduleStatus::Active),
        created_at: row.get(8)?,
    })
}

fn get_schedule_run_by_id(conn: &Connection, id: i64) -> StoreResult<ScheduleRun> {
    conn.query_row(
        r#"
        SELECT id, schedule_id, record_id, exit_status, stdout_summary, stderr_summary, created_at
        FROM schedule_runs
        WHERE id = ?1
        "#,
        params![id],
        schedule_run_from_row,
    )
    .map_err(StoreError::from)
}

fn schedule_run_from_row(row: &rusqlite::Row<'_>) -> Result<ScheduleRun, rusqlite::Error> {
    Ok(ScheduleRun {
        id: row.get(0)?,
        schedule_id: row.get(1)?,
        record_id: row.get(2)?,
        exit_status: row.get(3)?,
        stdout_summary: row.get(4)?,
        stderr_summary: row.get(5)?,
        created_at: row.get(6)?,
    })
}

fn resolve_schedule_id(conn: &Connection, id_prefix: &str) -> StoreResult<String> {
    let pattern = format!("{id_prefix}%");
    let mut stmt = conn.prepare("SELECT id FROM schedules WHERE id LIKE ?1 ORDER BY id LIMIT 2")?;
    let rows = stmt.query_map(params![pattern], |row| row.get::<_, String>(0))?;
    let ids: Vec<String> = rows.collect::<Result<_, _>>()?;

    match ids.as_slice() {
        [] => Err(StoreError::ScheduleNotFound(id_prefix.to_owned())),
        [id] => Ok(id.clone()),
        _ => Err(StoreError::AmbiguousScheduleId(id_prefix.to_owned())),
    }
}

fn validate_schedule_id_prefix(id_prefix: &str) -> StoreResult<()> {
    if id_prefix.is_empty()
        || id_prefix.len() > 8
        || !id_prefix
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit())
    {
        return Err(StoreError::InvalidScheduleId(id_prefix.to_owned()));
    }
    Ok(())
}

fn validate_schedule_kind(kind: &str) -> StoreResult<()> {
    match kind {
        "at" | "every" => Ok(()),
        _ => Err(StoreError::InvalidScheduleKind(kind.to_owned())),
    }
}

fn validate_schedule_command(command: &str) -> StoreResult<()> {
    if command.trim().is_empty() {
        return Err(StoreError::EmptyScheduleCommand);
    }
    Ok(())
}

fn get_record_by_id(conn: &Connection, id: &str) -> StoreResult<Record> {
    let (kind, created_at, updated_at) = conn.query_row(
        r#"
        SELECT
            kind,
            COALESCE(NULLIF(created_at, ''), strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            COALESCE(NULLIF(updated_at, ''), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        FROM records
        WHERE id = ?1
        "#,
        params![id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        },
    )?;

    let mut fields = BTreeMap::new();
    let mut stmt =
        conn.prepare("SELECT key, raw_value FROM record_fields WHERE record_id = ?1 ORDER BY key")?;
    let rows = stmt.query_map(params![id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (key, value) = row?;
        fields.insert(key, value);
    }

    Ok(Record {
        id: id.to_owned(),
        kind,
        created_at,
        updated_at,
        fields,
    })
}

fn links_for_record_id(conn: &Connection, record_id: &str) -> StoreResult<Vec<LinkEdge>> {
    let mut stmt = conn.prepare(
        r#"
        SELECT direction, rel, peer_record_id
        FROM (
            SELECT
                0 AS direction_order,
                'out' AS direction,
                rel,
                to_record_id AS peer_record_id
            FROM record_links
            WHERE from_record_id = ?1
            UNION ALL
            SELECT
                1 AS direction_order,
                'in' AS direction,
                rel,
                from_record_id AS peer_record_id
            FROM record_links
            WHERE to_record_id = ?1
        )
        ORDER BY direction_order, rel, peer_record_id
        "#,
    )?;
    let rows = stmt.query_map(params![record_id], |row| {
        let direction_text: String = row.get(0)?;
        let direction = match direction_text.as_str() {
            "out" => LinkDirection::Out,
            "in" => LinkDirection::In,
            _ => unreachable!("record link query returns only known directions"),
        };
        Ok(LinkEdge {
            direction,
            rel: row.get(1)?,
            peer_record_id: row.get(2)?,
        })
    })?;

    Ok(rows.collect::<Result<_, _>>()?)
}

fn resolve_id(conn: &Connection, id_prefix: &str) -> StoreResult<String> {
    let pattern = format!("{id_prefix}%");
    let mut stmt = conn.prepare("SELECT id FROM records WHERE id LIKE ?1 ORDER BY id LIMIT 2")?;
    let rows = stmt.query_map(params![pattern], |row| row.get::<_, String>(0))?;
    let ids: Vec<String> = rows.collect::<Result<_, _>>()?;

    match ids.as_slice() {
        [] => Err(StoreError::NotFound(id_prefix.to_owned())),
        [id] => Ok(id.clone()),
        _ => Err(StoreError::AmbiguousId(id_prefix.to_owned())),
    }
}

fn resolve_hook_id(conn: &Connection, id_prefix: &str) -> StoreResult<String> {
    let pattern = format!("{id_prefix}%");
    let mut stmt = conn.prepare("SELECT id FROM hooks WHERE id LIKE ?1 ORDER BY id LIMIT 2")?;
    let rows = stmt.query_map(params![pattern], |row| row.get::<_, String>(0))?;
    let ids: Vec<String> = rows.collect::<Result<_, _>>()?;

    match ids.as_slice() {
        [] => Err(StoreError::HookNotFound(id_prefix.to_owned())),
        [id] => Ok(id.clone()),
        _ => Err(StoreError::AmbiguousHookId(id_prefix.to_owned())),
    }
}

fn record_snapshot_json(record: &Record) -> StoreResult<String> {
    Ok(serde_json::to_string(&json!({
        "id": record.id,
        "kind": record.kind,
        "fields": record.fields,
    }))?)
}

fn insert_store_event(tx: &Transaction<'_>, event_type: &str, record: &Record) -> StoreResult<()> {
    let snapshot = record_snapshot_json(record)?;
    tx.execute(
        r#"
        INSERT INTO store_events (event_type, record_id, record_snapshot)
        VALUES (?1, ?2, ?3)
        "#,
        params![event_type, &record.id, &snapshot],
    )?;
    Ok(())
}

fn run_migrations(conn: &mut Connection) -> StoreResult<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            checksum TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );
        "#,
    )?;

    for migration in MIGRATIONS {
        let checksum = migration_checksum(migration.sql);
        let applied = tx
            .query_row(
                "SELECT name, checksum FROM schema_migrations WHERE version = ?1",
                params![migration.version],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;

        if let Some((name, applied_checksum)) = applied {
            if applied_checksum != checksum {
                return Err(StoreError::MigrationChecksum {
                    version: migration.version,
                    name,
                    expected: checksum,
                    actual: applied_checksum,
                });
            }
            continue;
        }

        tx.execute_batch(migration.sql)?;
        tx.execute(
            "INSERT INTO schema_migrations (version, name, checksum) VALUES (?1, ?2, ?3)",
            params![migration.version, migration.name, checksum],
        )?;
    }

    tx.commit()?;
    Ok(())
}

fn insert_record(
    tx: &Transaction<'_>,
    id: &str,
    kind: &str,
    fields: &BTreeMap<String, String>,
) -> Result<(), rusqlite::Error> {
    tx.execute(
        r#"
        INSERT INTO records (id, kind, created_at, updated_at)
        VALUES (
            ?1,
            ?2,
            strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
            strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        )
        "#,
        params![id, kind],
    )?;

    for (key, value) in fields {
        insert_field(tx, id, key, value)?;
    }

    Ok(())
}

fn insert_field(
    tx: &Transaction<'_>,
    record_id: &str,
    key: &str,
    raw_value: &str,
) -> Result<(), rusqlite::Error> {
    let parsed = FieldValue::parse(raw_value);
    tx.execute(
        r#"
        INSERT INTO record_fields (
            record_id,
            key,
            raw_value,
            text_value,
            number_value,
            timestamp_value,
            boolean_value,
            is_null
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            record_id,
            key,
            raw_value,
            parsed.text_value(),
            parsed.number_value(),
            parsed.timestamp_value(),
            parsed.boolean_value(),
            parsed.is_null()
        ],
    )?;
    Ok(())
}

fn upsert_field(
    tx: &Transaction<'_>,
    record_id: &str,
    key: &str,
    raw_value: &str,
) -> Result<(), rusqlite::Error> {
    let parsed = FieldValue::parse(raw_value);
    tx.execute(
        r#"
        INSERT INTO record_fields (
            record_id,
            key,
            raw_value,
            text_value,
            number_value,
            timestamp_value,
            boolean_value,
            is_null
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(record_id, key) DO UPDATE SET
            raw_value = excluded.raw_value,
            text_value = excluded.text_value,
            number_value = excluded.number_value,
            timestamp_value = excluded.timestamp_value,
            boolean_value = excluded.boolean_value,
            is_null = excluded.is_null
        "#,
        params![
            record_id,
            key,
            raw_value,
            parsed.text_value(),
            parsed.number_value(),
            parsed.timestamp_value(),
            parsed.boolean_value(),
            parsed.is_null()
        ],
    )?;
    Ok(())
}

fn generate_id() -> String {
    let mut rng = rand::thread_rng();
    (0..ID_LEN)
        .map(|_| {
            let index = rng.gen_range(0..ID_CHARS.len());
            char::from(ID_CHARS[index])
        })
        .collect()
}

fn validate_id_prefix(id_prefix: &str) -> StoreResult<()> {
    if id_prefix.is_empty()
        || id_prefix.len() > 8
        || !id_prefix
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit())
    {
        return Err(StoreError::InvalidId(id_prefix.to_owned()));
    }
    Ok(())
}

fn validate_relation(rel: &str) -> StoreResult<()> {
    if rel.is_empty() || rel.chars().any(char::is_whitespace) {
        return Err(StoreError::InvalidRelation(rel.to_owned()));
    }
    Ok(())
}

fn validate_hook_id_prefix(id_prefix: &str) -> StoreResult<()> {
    if id_prefix.is_empty()
        || id_prefix.len() > 8
        || !id_prefix
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit())
    {
        return Err(StoreError::InvalidHookId(id_prefix.to_owned()));
    }
    Ok(())
}

fn validate_hook_event(event: &str) -> StoreResult<()> {
    match event {
        "create" | "set" | "unset" | "rm" | "link" | "unlink" => Ok(()),
        _ => Err(StoreError::InvalidHookEvent(event.to_owned())),
    }
}

fn validate_hook_command(command: &str) -> StoreResult<()> {
    if command.trim().is_empty() {
        return Err(StoreError::EmptyHookCommand);
    }
    Ok(())
}

fn is_constraint_violation(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(sqlite_error, _)
            if sqlite_error.code == ErrorCode::ConstraintViolation
    )
}

fn is_transient_open_error(error: &StoreError) -> bool {
    match error {
        StoreError::OpenStore { source, .. } => is_transient_open_error(source),
        StoreError::Sql(error) => is_sqlite_busy_or_locked(error),
        _ => false,
    }
}

fn is_sqlite_busy_or_locked(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseBusy) | Some(ErrorCode::DatabaseLocked)
    )
}

fn open_retry_delay(attempt: usize) -> Duration {
    Duration::from_millis(OPEN_BUSY_RETRY_BASE.as_millis() as u64 * (attempt as u64 + 1))
}

fn migration_checksum(sql: &str) -> String {
    let mut hasher = Fnv1a64::default();
    hasher.write(sql.as_bytes());
    format!("{:016x}", hasher.finish())
}

struct Fnv1a64(u64);

impl Default for Fnv1a64 {
    fn default() -> Self {
        Self(0xcbf29ce484222325)
    }
}

impl Hasher for Fnv1a64 {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x100000001b3);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_dir_conflict_is_detected_on_the_walk_up() {
        let root = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        let nested = root.join("a/b");
        fs::create_dir_all(&nested).unwrap();
        let conflict_path = root.join(STORE_DIR);
        fs::write(&conflict_path, "not a directory").unwrap();

        // A stray .agent-store file on an ancestor is reported as a conflict
        // instead of being treated as "not initialized".
        assert_eq!(
            find_store_dir_conflict(&nested),
            Some(conflict_path.clone())
        );
        assert_eq!(find_project_root(&nested), None);
        let message = StoreError::StoreDirConflict(conflict_path.clone()).to_string();
        assert!(
            message.contains("exists but is not a directory"),
            "{message}"
        );

        // A real store directory is not a conflict.
        fs::remove_file(&conflict_path).unwrap();
        fs::create_dir(&conflict_path).unwrap();
        assert_eq!(find_store_dir_conflict(&nested), None);
        assert_eq!(find_project_root(&nested), Some(root.clone()));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn record_id_generation_uses_lowercase_base36() {
        let id = generate_id();

        assert_eq!(id.len(), ID_LEN);
        assert!(id
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit()));
    }

    #[test]
    fn record_id_generation_retries_collisions() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");
        let mut store = Store::open(db_path).unwrap();
        let existing_id = "aaaaaa";

        store
            .conn
            .execute(
                "INSERT INTO records (id, kind, created_at, updated_at) VALUES (?1, 'seed', 'now', 'now')",
                params![existing_id],
            )
            .unwrap();

        let mut ids = [existing_id.to_owned(), "bbbbbb".to_owned()].into_iter();
        let record = store
            .create_record_with_id_generator(
                "task",
                BTreeMap::from([("title".into(), "write".into())]),
                || {
                    ids.next()
                        .expect("test ID sequence should not be exhausted")
                },
            )
            .unwrap();

        assert_eq!(record.id, "bbbbbb");
        let fetched = store.get_record("bbbbbb").unwrap();
        assert_eq!(fetched.kind, "task");
        assert_eq!(
            fetched.fields,
            BTreeMap::from([("title".into(), "write".into())])
        );
        assert_eq!(fetched, record);

        drop(store);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn record_id_generation_reports_collision_exhaustion() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");
        let mut store = Store::open(db_path).unwrap();
        let existing_id = "aaaaaa";

        store
            .conn
            .execute(
                "INSERT INTO records (id, kind, created_at, updated_at) VALUES (?1, 'seed', 'now', 'now')",
                params![existing_id],
            )
            .unwrap();

        let error = store
            .create_record_with_id_generator("task", BTreeMap::new(), || existing_id.to_owned())
            .unwrap_err();

        assert!(matches!(error, StoreError::IdCollisionExhausted));

        drop(store);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn create_sets_timestamps_and_set_unset_bump_updated_at() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");
        let mut store = Store::open(db_path).unwrap();

        let created = store
            .create_record("task", BTreeMap::from([("title".into(), "write".into())]))
            .unwrap();
        assert!(
            is_utc_rfc3339(&created.created_at),
            "{}",
            created.created_at
        );
        assert!(
            is_utc_rfc3339(&created.updated_at),
            "{}",
            created.updated_at
        );
        assert_eq!(created.created_at, created.updated_at);

        thread::sleep(Duration::from_millis(5));
        let updated = store
            .set_record(
                &created.id,
                BTreeMap::from([("status".into(), "open".into())]),
            )
            .unwrap();
        assert_eq!(updated.created_at, created.created_at);
        assert!(updated.updated_at > created.updated_at);

        thread::sleep(Duration::from_millis(5));
        let unset = store
            .unset_record(&created.id, vec!["status".to_owned()])
            .unwrap();
        assert_eq!(unset.created_at, created.created_at);
        assert!(unset.updated_at > updated.updated_at);

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn noop_set_and_unset_leave_updated_at_untouched() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");
        let mut store = Store::open(db_path).unwrap();

        let created = store
            .create_record("task", BTreeMap::from([("title".into(), "write".into())]))
            .unwrap();

        thread::sleep(Duration::from_millis(5));
        let same_value = store
            .set_record_with_snapshot(
                &created.id,
                BTreeMap::from([("title".into(), "write".into())]),
            )
            .unwrap();
        assert!(!same_value.changed);
        assert_eq!(same_value.record.updated_at, created.updated_at);

        let missing_key = store
            .unset_record_with_snapshot(&created.id, vec!["nonexistent".to_owned()])
            .unwrap();
        assert!(!missing_key.changed);
        assert_eq!(missing_key.record.updated_at, created.updated_at);

        // A real change still bumps updated_at and reports changed.
        let real_change = store
            .set_record_with_snapshot(
                &created.id,
                BTreeMap::from([("title".into(), "ship".into())]),
            )
            .unwrap();
        assert!(real_change.changed);
        assert!(real_change.record.updated_at > created.updated_at);

        fs::remove_dir_all(dir).unwrap();
    }

    fn is_utc_rfc3339(value: &str) -> bool {
        let bytes = value.as_bytes();
        bytes.len() > 20
            && bytes[..10]
                .iter()
                .enumerate()
                .all(|(index, byte)| match index {
                    4 | 7 => *byte == b'-',
                    _ => byte.is_ascii_digit(),
                })
            && bytes[10] == b'T'
            && value.ends_with('Z')
    }

    #[test]
    fn hook_runs_persist_invocation_results() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");

        let run = {
            let mut store = Store::open(db_path.clone()).unwrap();
            let hook = store
                .add_hook("create", None, "printf 'hook ran\\n'")
                .unwrap();
            let record = store
                .create_record("task", BTreeMap::from([("title".into(), "write".into())]))
                .unwrap();

            let run = store
                .record_hook_run(
                    &hook.id,
                    "create",
                    &record.id,
                    7,
                    "stdout summary",
                    "stderr summary",
                )
                .unwrap();

            assert_eq!(run.hook_id, hook.id);
            assert_eq!(run.event_type, "create");
            assert_eq!(run.record_id, record.id);
            assert_eq!(run.exit_status, 7);
            assert_eq!(run.stdout_summary, "stdout summary");
            assert_eq!(run.stderr_summary, "stderr summary");
            assert!(!run.created_at.is_empty());
            assert_eq!(store.list_hook_runs().unwrap(), vec![run.clone()]);
            run
        };

        let reopened = Store::open(db_path).unwrap();
        assert_eq!(reopened.list_hook_runs().unwrap(), vec![run]);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn hook_runs_survive_hook_deletion() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");
        let mut store = Store::open(db_path).unwrap();

        let hook = store.add_hook("create", None, "printf ok").unwrap();
        let record = store
            .create_record("task", BTreeMap::from([("title".into(), "write".into())]))
            .unwrap();
        let removed = store.delete_hook(&hook.id).unwrap();
        assert_eq!(removed, hook);
        assert!(store.list_hooks().unwrap().is_empty());

        let run = store
            .record_hook_run(&hook.id, "create", &record.id, 0, "ok", "")
            .unwrap();
        assert_eq!(run.hook_id, hook.id);
        assert_eq!(store.list_hook_runs().unwrap(), vec![run]);

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn migration_preserves_existing_hook_runs_after_hook_deletion() {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("store.sqlite");

        {
            let conn = Connection::open(&db_path).unwrap();
            conn.pragma_update(None, "foreign_keys", "ON").unwrap();
            conn.execute_batch(INITIAL_SCHEMA).unwrap();
            conn.execute_batch(
                r#"
                CREATE TABLE schema_migrations (
                    version INTEGER PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                );
                "#,
            )
            .unwrap();
            conn.execute(
                "INSERT INTO schema_migrations (version, name, checksum) VALUES (1, 'initial_schema', ?1)",
                params![migration_checksum(INITIAL_SCHEMA)],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO hooks (id, event, query, command) VALUES ('aaaaaa', 'create', NULL, 'printf ok')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO records (id, kind, created_at, updated_at) VALUES ('bbbbbb', 'task', 'now', 'now')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO hook_runs (hook_id, event_type, record_id, exit_status, stdout_summary, stderr_summary) VALUES ('aaaaaa', 'create', 'bbbbbb', 0, 'ok', '')",
                [],
            )
            .unwrap();
        }

        let mut store = Store::open(db_path).unwrap();
        let migration_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(migration_count, MIGRATIONS.len() as i64);
        store.delete_hook("aaaaaa").unwrap();

        let runs = store.list_hook_runs().unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].hook_id, "aaaaaa");
        assert_eq!(runs[0].record_id, "bbbbbb");

        fs::remove_dir_all(dir).unwrap();
    }

    fn open_temp_store() -> (Store, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("agent-store-test-{}", generate_id()));
        fs::create_dir_all(dir.join(STORE_DIR)).unwrap();
        let store = Store::open(dir.join(STORE_DIR).join(STORE_DB_FILE)).unwrap();
        (store, dir)
    }

    #[test]
    fn schedule_add_list_delete_lifecycle() {
        let (mut store, dir) = open_temp_store();

        let s = store
            .add_schedule(
                "every",
                "5m",
                Some(300),
                "2026-07-06T12:00:00.000Z",
                None,
                "echo tick",
            )
            .unwrap();
        assert_eq!(s.kind, ScheduleKind::Every);
        assert_eq!(s.expression, "5m");
        assert_eq!(s.interval_seconds, Some(300));
        assert_eq!(s.command, "echo tick");
        assert_eq!(s.status, ScheduleStatus::Active);
        assert!(s.query.is_none());

        let all = store.list_schedules().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].id, s.id);

        let deleted = store.delete_schedule(&s.id).unwrap();
        assert_eq!(deleted.id, s.id);

        let all = store.list_schedules().unwrap();
        assert!(all.is_empty());

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_at_completes_on_tick() {
        let (mut store, dir) = open_temp_store();

        store
            .add_schedule(
                "at",
                "2020-01-01T00:00:00Z",
                None,
                "2020-01-01T00:00:00Z",
                None,
                "echo once",
            )
            .unwrap();

        let due = store.tick_due_schedules().unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].kind, ScheduleKind::At);

        let all = store.list_schedules().unwrap();
        assert_eq!(all[0].status, ScheduleStatus::Completed);

        let due2 = store.tick_due_schedules().unwrap();
        assert!(due2.is_empty());

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_every_advances_next_run_at_on_tick() {
        let (mut store, dir) = open_temp_store();

        store
            .add_schedule(
                "every",
                "5m",
                Some(300),
                "2020-01-01T00:00:00.000Z",
                None,
                "echo tick",
            )
            .unwrap();

        let due = store.tick_due_schedules().unwrap();
        assert_eq!(due.len(), 1);

        let all = store.list_schedules().unwrap();
        assert_eq!(all[0].status, ScheduleStatus::Active);
        assert_ne!(all[0].next_run_at, "2020-01-01T00:00:00.000Z");

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_runs_are_recorded_and_retrieved() {
        let (mut store, dir) = open_temp_store();

        let s = store
            .add_schedule(
                "every",
                "1h",
                Some(3600),
                "2020-01-01T00:00:00.000Z",
                None,
                "echo hello",
            )
            .unwrap();

        let run = store
            .record_schedule_run(&s.id, None, 0, "hello\n", "")
            .unwrap();
        assert_eq!(run.schedule_id, s.id);
        assert_eq!(run.exit_status, 0);
        assert_eq!(run.stdout_summary, "hello\n");

        let runs = store.list_recent_schedule_runs(10).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].id, run.id);

        let fetched = store.get_schedule_run(run.id).unwrap();
        assert_eq!(fetched.id, run.id);

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_summary_reflects_state() {
        let (mut store, dir) = open_temp_store();

        let summary = store.schedule_summary().unwrap();
        assert_eq!(summary.active_count, 0);
        assert_eq!(summary.completed_count, 0);
        assert!(summary.next_run_at.is_none());

        store
            .add_schedule(
                "every",
                "1h",
                Some(3600),
                "2026-12-01T00:00:00.000Z",
                None,
                "echo a",
            )
            .unwrap();
        store
            .add_schedule(
                "at",
                "2020-01-01T00:00:00Z",
                None,
                "2020-01-01T00:00:00Z",
                None,
                "echo b",
            )
            .unwrap();
        store.tick_due_schedules().unwrap();

        let summary = store.schedule_summary().unwrap();
        assert_eq!(summary.active_count, 1);
        assert_eq!(summary.completed_count, 1);
        assert_eq!(
            summary.next_run_at,
            Some("2026-12-01T00:00:00.000Z".to_owned())
        );

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_with_query_is_stored() {
        let (mut store, dir) = open_temp_store();

        let s = store
            .add_schedule(
                "every",
                "30m",
                Some(1800),
                "2026-07-06T12:00:00.000Z",
                Some("kind=task and status=open".to_owned()),
                "echo $AGENT_STORE_RECORD_ID",
            )
            .unwrap();
        assert_eq!(s.query.as_deref(), Some("kind=task and status=open"));

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_delete_by_prefix() {
        let (mut store, dir) = open_temp_store();

        let s = store
            .add_schedule(
                "every",
                "1h",
                Some(3600),
                "2026-07-06T12:00:00.000Z",
                None,
                "echo a",
            )
            .unwrap();
        let prefix = &s.id[..3];
        let deleted = store.delete_schedule(prefix).unwrap();
        assert_eq!(deleted.id, s.id);
        assert!(store.list_schedules().unwrap().is_empty());

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_invalid_kind_is_rejected() {
        let (mut store, dir) = open_temp_store();
        let err = store
            .add_schedule(
                "weekly",
                "1h",
                Some(3600),
                "2026-07-06T12:00:00.000Z",
                None,
                "echo a",
            )
            .unwrap_err();
        assert!(err.to_string().contains("at"), "{err}");
        assert!(err.to_string().contains("every"), "{err}");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_empty_command_is_rejected() {
        let (mut store, dir) = open_temp_store();
        let err = store
            .add_schedule(
                "every",
                "1h",
                Some(3600),
                "2026-07-06T12:00:00.000Z",
                None,
                "",
            )
            .unwrap_err();
        assert!(err.to_string().contains("empty"), "{err}");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn schedule_ctx_includes_schedule_summary() {
        let (mut store, dir) = open_temp_store();

        store
            .add_schedule(
                "every",
                "1h",
                Some(3600),
                "2026-12-01T00:00:00.000Z",
                None,
                "echo tick",
            )
            .unwrap();

        let ctx = store.quick_context_summary().unwrap();
        assert_eq!(ctx.schedule_summary.active_count, 1);
        assert_eq!(ctx.schedule_summary.completed_count, 0);
        assert_eq!(
            ctx.schedule_summary.next_run_at,
            Some("2026-12-01T00:00:00.000Z".to_owned())
        );

        fs::remove_dir_all(dir).unwrap();
    }
}
