//! Opens stores written by the real released binaries (see
//! tests/fixtures/make-upgrade-fixtures.sh) with the current code.

use agent_store::query::Query;
use agent_store::store::{Record, ScheduleKind, ScheduleStatus, Store};
use rusqlite::Connection;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const MIGRATIONS: [(i64, &str); 3] = [
    (1, "initial_schema"),
    (2, "preserve_hook_runs_after_hook_delete"),
    (3, "add_schedules"),
];

const PLAN_BODY: &str = "Step one: open the old store.\nStep two: check every field.\n\nTrailing line after a blank line.";

struct UpgradedProject {
    root: PathBuf,
}

impl UpgradedProject {
    fn from_fixture(version: &str) -> Self {
        let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
        let root = manifest.join(format!(
            "target/test-stores/upgrade-{version}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".agent-store")).expect("create project dir");
        fs::copy(
            manifest.join(format!("tests/fixtures/upgrade/{version}.sqlite")),
            root.join(".agent-store/store.sqlite"),
        )
        .expect("copy fixture store");
        Self { root }
    }

    fn migrations(&self) -> Vec<(i64, String, String, String)> {
        let conn = Connection::open(self.root.join(".agent-store/store.sqlite"))
            .expect("open store with sqlite");
        let mut stmt = conn
            .prepare("SELECT version, name, checksum, applied_at FROM schema_migrations ORDER BY version")
            .expect("prepare schema_migrations query");
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .expect("query schema_migrations");
        rows.collect::<Result<_, _>>()
            .expect("read schema_migrations")
    }
}

impl Drop for UpgradedProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn fields(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn only(store: &Store, query: &str) -> Record {
    let query = Query::parse(query).expect("parse query");
    let mut records = store.find_records(Some(&query)).expect("find records");
    assert_eq!(records.len(), 1, "{records:?}");
    records.remove(0)
}

fn assert_upgrade(version: &str, versions_before: &[i64]) {
    let project = UpgradedProject::from_fixture(version);

    let before = project.migrations();
    assert_eq!(
        before.iter().map(|row| row.0).collect::<Vec<_>>(),
        versions_before,
        "{version} fixture migrations"
    );

    let mut store = Store::open_project_root(&project.root).expect("open old store with HEAD");

    let after = project.migrations();
    assert_eq!(
        after
            .iter()
            .map(|row| (row.0, row.1.as_str()))
            .collect::<Vec<_>>(),
        MIGRATIONS.to_vec(),
        "{version} migrations after upgrade"
    );
    for row in &after {
        assert_eq!(row.2.len(), 16, "{row:?}");
        assert!(!row.3.is_empty(), "{row:?}");
        if let Some(old) = before.iter().find(|old| old.0 == row.0) {
            assert_eq!(
                old, row,
                "{version} already-applied migration was rewritten"
            );
        }
    }

    let records = store.find_records(None).expect("find all records");
    assert_eq!(records.len(), 3, "{records:?}");

    let plan = only(&store, "kind=task");
    assert_eq!(
        plan.fields,
        fields(&[
            ("title", "Ship the upgrade"),
            ("status", "doing"),
            ("priority", "2"),
            ("body", PLAN_BODY),
        ])
    );
    assert!(plan.updated_at > plan.created_at, "{plan:?}");
    let note = only(&store, "kind=note");
    assert_eq!(
        note.fields,
        fields(&[
            ("title", "Release checklist"),
            ("text", &format!("written by agent-store {version}")),
        ])
    );
    let bug = only(&store, "kind=bug");
    assert_eq!(
        bug.fields,
        fields(&[
            ("title", "Hook output survives upgrades"),
            ("status", "open")
        ])
    );
    assert_eq!(only(&store, "priority<3 and status=doing").id, plan.id);

    let plan_links = store.links_for_record(&plan.id).expect("plan links");
    let mut edges: Vec<_> = plan_links
        .links
        .iter()
        .map(|edge| {
            (
                edge.direction.as_str(),
                edge.rel.as_str(),
                edge.peer_record_id.as_str(),
            )
        })
        .collect();
    edges.sort();
    assert_eq!(
        edges,
        vec![
            ("in", "references", note.id.as_str()),
            ("out", "blocks", bug.id.as_str()),
        ]
    );

    let hooks = store.list_hooks().expect("list hooks");
    assert_eq!(hooks.len(), 1, "{hooks:?}");
    assert_eq!(hooks[0].event, "set");
    assert_eq!(hooks[0].query.as_deref(), Some("kind=task"));
    assert_eq!(
        hooks[0].command,
        r#"printf "hooked %s %s\n" "$AGENT_STORE_EVENT" "$AGENT_STORE_FIELD""#
    );
    let hook_runs = store.list_hook_runs().expect("list hook runs");
    assert_eq!(hook_runs.len(), 1, "{hook_runs:?}");
    assert_eq!(hook_runs[0].hook_id, hooks[0].id);
    assert_eq!(hook_runs[0].event_type, "set");
    assert_eq!(hook_runs[0].record_id, plan.id);
    assert_eq!(hook_runs[0].exit_status, 0);
    assert_eq!(hook_runs[0].stdout_summary, "hooked set status\n");

    let schedules = store.list_schedules().expect("list schedules");
    let schedule_runs = store
        .list_recent_schedule_runs(10)
        .expect("list schedule runs");
    if version == "v0.1.0" {
        assert!(schedules.is_empty(), "{schedules:?}");
        assert!(schedule_runs.is_empty(), "{schedule_runs:?}");
    } else {
        assert_eq!(schedules.len(), 2, "{schedules:?}");
        let daily = schedules
            .iter()
            .find(|schedule| schedule.kind == ScheduleKind::Every)
            .expect("recurring schedule");
        assert_eq!(daily.expression, "1d");
        assert_eq!(daily.interval_seconds, Some(86_400));
        assert_eq!(daily.query.as_deref(), Some("kind=bug"));
        assert_eq!(daily.command, r#"printf "daily %s\n" "$AGENT_STORE_ID""#);
        assert_eq!(daily.status, ScheduleStatus::Active);
        let once = schedules
            .iter()
            .find(|schedule| schedule.kind == ScheduleKind::At)
            .expect("one-shot schedule");
        assert_eq!(once.status, ScheduleStatus::Completed);
        assert_eq!(schedule_runs.len(), 1, "{schedule_runs:?}");
        assert_eq!(schedule_runs[0].schedule_id, once.id);
        assert_eq!(schedule_runs[0].exit_status, 0);
        assert_eq!(schedule_runs[0].stdout_summary, "one-shot ran\n");
    }

    let added = store
        .create_record("note", fields(&[("title", "Written after upgrade")]))
        .expect("create record after upgrade");
    store
        .link_records(&added.id, "follows", &plan.id)
        .expect("link after upgrade");
    store
        .set_record(&bug.id, fields(&[("status", "fixed")]))
        .expect("set after upgrade");
    let hook = store
        .add_hook("create", None, "true")
        .expect("add hook after upgrade");
    store
        .record_hook_run(&hook.id, "create", &added.id, 0, "ok", "")
        .expect("record hook run after upgrade");
    store
        .add_schedule(
            "every",
            "1h",
            Some(3_600),
            "2999-01-01T00:00:00.000Z",
            None,
            "true",
        )
        .expect("add schedule after upgrade");
    drop(store);

    let reopened = Store::open_project_root(&project.root).expect("reopen upgraded store");
    assert_eq!(project.migrations(), after, "reopen reapplied migrations");
    assert_eq!(reopened.find_records(None).expect("find").len(), 4);
    assert_eq!(only(&reopened, "kind=bug").fields["status"], "fixed");
    assert_eq!(
        reopened.links_for_record(&added.id).expect("links").links[0].peer_record_id,
        plan.id
    );
    assert_eq!(reopened.list_hook_runs().expect("hook runs").len(), 2);
    assert_eq!(
        reopened.list_schedules().expect("schedules").len(),
        if version == "v0.1.0" { 1 } else { 3 }
    );
}

#[test]
fn upgrades_v0_1_0_store_and_applies_add_schedules() {
    assert_upgrade("v0.1.0", &[1, 2]);
}

#[test]
fn upgrades_v0_1_1_store() {
    assert_upgrade("v0.1.1", &[1, 2, 3]);
}

#[test]
fn upgrades_v0_1_2_store() {
    assert_upgrade("v0.1.2", &[1, 2, 3]);
}
