use crate::query::Query;
use crate::value::FieldValue;
use rand::Rng;
use rusqlite::{params, Connection, ErrorCode, OptionalExtension, Transaction};
use serde_json::json;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::hash::Hasher;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const STORE_DIR: &str = ".agent-store";
const STORE_DB_FILE: &str = "store.sqlite";
const ID_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
const ID_LEN: usize = 6;
const ID_RETRIES: usize = 16;

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

struct Migration {
    version: i64,
    name: &'static str,
    sql: &'static str,
}

const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    name: "initial_schema",
    sql: INITIAL_SCHEMA,
}];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub id: String,
    pub kind: String,
    pub fields: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub from_record_id: String,
    pub rel: String,
    pub to_record_id: String,
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

pub struct Store {
    conn: Connection,
}

#[derive(Debug)]
pub enum StoreError {
    Io(std::io::Error),
    Sql(rusqlite::Error),
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
    NotFound(String),
    AmbiguousId(String),
    HookNotFound(String),
    AmbiguousHookId(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::Sql(error) => write!(f, "{error}"),
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
            Self::NotFound(id) => write!(f, "record '{id}' was not found"),
            Self::AmbiguousId(id) => write!(f, "record ID prefix '{id}' matches multiple records"),
            Self::HookNotFound(id) => write!(f, "hook '{id}' was not found"),
            Self::AmbiguousHookId(id) => {
                write!(f, "hook ID prefix '{id}' matches multiple hooks")
            }
        }
    }
}

impl Error for StoreError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Sql(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
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

impl Store {
    pub fn open_project() -> StoreResult<Self> {
        fs::create_dir_all(STORE_DIR)?;
        Self::open(Path::new(STORE_DIR).join(STORE_DB_FILE))
    }

    fn open(path: PathBuf) -> StoreResult<Self> {
        let mut conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        run_migrations(&mut conn)?;
        Ok(Self { conn })
    }

    pub fn create_record(
        &mut self,
        kind: &str,
        fields: BTreeMap<String, String>,
    ) -> StoreResult<Record> {
        for _ in 0..ID_RETRIES {
            let id = generate_id();
            let tx = self.conn.transaction()?;
            match insert_record(&tx, &id, kind, &fields) {
                Ok(()) => {
                    let record = Record {
                        id,
                        kind: kind.to_owned(),
                        fields,
                    };
                    insert_store_event(&tx, "create", &record)?;
                    tx.commit()?;
                    return Ok(record);
                }
                Err(error) if is_constraint_violation(&error) => continue,
                Err(error) => return Err(StoreError::Sql(error)),
            }
        }

        Err(StoreError::HookIdCollisionExhausted)
    }

    pub fn get_record(&self, id_prefix: &str) -> StoreResult<Record> {
        validate_id_prefix(id_prefix)?;
        let id = self.resolve_id(id_prefix)?;
        get_record_by_id(&self.conn, &id)
    }

    pub fn find_records(&self, query: &Query) -> StoreResult<Vec<Record>> {
        let mut stmt = self.conn.prepare("SELECT id FROM records ORDER BY id")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let ids: Vec<String> = rows.collect::<Result<_, _>>()?;
        let mut records = Vec::new();
        let uses_links = query.uses_links();

        for id in ids {
            let record = get_record_by_id(&self.conn, &id)?;
            let matches = if uses_links {
                let links = links_for_record_id(&self.conn, &id)?;
                query.matches_with_links(&record, &links)
            } else {
                query.matches(&record)
            };

            if matches {
                records.push(record);
            }
        }

        Ok(records)
    }

    pub fn set_record(
        &mut self,
        id_prefix: &str,
        fields: BTreeMap<String, String>,
    ) -> StoreResult<Record> {
        validate_id_prefix(id_prefix)?;
        let tx = self.conn.transaction()?;
        let id = resolve_id(&tx, id_prefix)?;

        for (key, value) in &fields {
            upsert_field(&tx, &id, key, value)?;
        }
        tx.execute(
            "UPDATE records SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
            params![&id],
        )?;
        let record = get_record_by_id(&tx, &id)?;
        insert_store_event(&tx, "set", &record)?;
        tx.commit()?;

        Ok(record)
    }

    pub fn unset_record(&mut self, id_prefix: &str, keys: Vec<String>) -> StoreResult<Record> {
        validate_id_prefix(id_prefix)?;
        let tx = self.conn.transaction()?;
        let id = resolve_id(&tx, id_prefix)?;

        for key in keys {
            tx.execute(
                "DELETE FROM record_fields WHERE record_id = ?1 AND key = ?2",
                params![&id, &key],
            )?;
        }
        tx.execute(
            "UPDATE records SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
            params![&id],
        )?;
        let record = get_record_by_id(&tx, &id)?;
        insert_store_event(&tx, "unset", &record)?;
        tx.commit()?;

        Ok(record)
    }

    pub fn delete_record(&mut self, id_prefix: &str) -> StoreResult<Record> {
        validate_id_prefix(id_prefix)?;
        let tx = self.conn.transaction()?;
        let id = resolve_id(&tx, id_prefix)?;
        let record = get_record_by_id(&tx, &id)?;

        insert_store_event(&tx, "rm", &record)?;
        tx.execute("DELETE FROM records WHERE id = ?1", params![&record.id])?;
        tx.commit()?;

        Ok(record)
    }

    pub fn link_records(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<Link> {
        validate_id_prefix(from_prefix)?;
        validate_id_prefix(to_prefix)?;
        validate_relation(rel)?;

        let tx = self.conn.transaction()?;
        let from_id = resolve_id(&tx, from_prefix)?;
        let to_id = resolve_id(&tx, to_prefix)?;
        tx.execute(
            r#"
            INSERT OR IGNORE INTO record_links (from_record_id, rel, to_record_id)
            VALUES (?1, ?2, ?3)
            "#,
            params![&from_id, rel, &to_id],
        )?;
        let source = get_record_by_id(&tx, &from_id)?;
        insert_store_event(&tx, "link", &source)?;
        tx.commit()?;

        Ok(Link {
            from_record_id: from_id,
            rel: rel.to_owned(),
            to_record_id: to_id,
        })
    }

    pub fn unlink_records(
        &mut self,
        from_prefix: &str,
        rel: &str,
        to_prefix: &str,
    ) -> StoreResult<Link> {
        validate_id_prefix(from_prefix)?;
        validate_id_prefix(to_prefix)?;
        validate_relation(rel)?;

        let tx = self.conn.transaction()?;
        let from_id = resolve_id(&tx, from_prefix)?;
        let to_id = resolve_id(&tx, to_prefix)?;
        tx.execute(
            r#"
            DELETE FROM record_links
            WHERE from_record_id = ?1 AND rel = ?2 AND to_record_id = ?3
            "#,
            params![&from_id, rel, &to_id],
        )?;
        let source = get_record_by_id(&tx, &from_id)?;
        insert_store_event(&tx, "unlink", &source)?;
        tx.commit()?;

        Ok(Link {
            from_record_id: from_id,
            rel: rel.to_owned(),
            to_record_id: to_id,
        })
    }

    pub fn links_for_record(&self, id_prefix: &str) -> StoreResult<RecordLinks> {
        validate_id_prefix(id_prefix)?;
        let record_id = self.resolve_id(id_prefix)?;
        let links = links_for_record_id(&self.conn, &record_id)?;

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
            let tx = self.conn.transaction()?;
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
            ORDER BY id
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
        let tx = self.conn.transaction()?;
        let id = resolve_hook_id(&tx, id_prefix)?;
        let hook = get_hook_by_id(&tx, &id)?;
        tx.execute("DELETE FROM hooks WHERE id = ?1", params![&hook.id])?;
        tx.commit()?;

        Ok(hook)
    }

    fn resolve_id(&self, id_prefix: &str) -> StoreResult<String> {
        resolve_id(&self.conn, id_prefix)
    }
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

fn get_record_by_id(conn: &Connection, id: &str) -> StoreResult<Record> {
    let kind = conn.query_row(
        "SELECT kind FROM records WHERE id = ?1",
        params![id],
        |row| row.get::<_, String>(0),
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
    conn.execute_batch(
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
        let applied = conn
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

        let tx = conn.transaction()?;
        tx.execute_batch(migration.sql)?;
        tx.execute(
            "INSERT INTO schema_migrations (version, name, checksum) VALUES (?1, ?2, ?3)",
            params![migration.version, migration.name, checksum],
        )?;
        tx.commit()?;
    }

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
    fn generated_ids_are_lowercase_base36() {
        let id = generate_id();

        assert_eq!(id.len(), ID_LEN);
        assert!(id
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit()));
    }
}
