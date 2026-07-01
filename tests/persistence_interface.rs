use agent_store::query::Query;
use agent_store::store::Store;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT_TEST_DIR: AtomicUsize = AtomicUsize::new(0);

struct TestProject {
    root: PathBuf,
}

impl TestProject {
    fn new(name: &str) -> Self {
        let unique = NEXT_TEST_DIR.fetch_add(1, Ordering::Relaxed);
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
            "target/test-stores/{name}-{}-{unique}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create test project root");
        Self { root }
    }
}

impl Drop for TestProject {
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

#[test]
fn persistence_interface_allows_behavior_tests_without_sqlite_layout() {
    let project = TestProject::new("persistence-interface");
    let mut store = Store::open_project_root(&project.root).expect("open store at project root");

    let task = store
        .create_record(
            "task",
            fields(&[("title", "Write"), ("status", "open"), ("score", "2")]),
        )
        .expect("create task through Store API");
    let note = store
        .create_record("note", fields(&[("title", "Reference")]))
        .expect("create note through Store API");

    let query = Query::parse("kind=task and status=open and score<3").expect("parse query");
    assert_eq!(
        store.find_records(Some(&query)).expect("find records"),
        vec![task.clone()]
    );

    let updated = store
        .set_record(&task.id, fields(&[("status", "done")]))
        .expect("update task through Store API");
    assert_eq!(
        updated.fields.get("title").map(String::as_str),
        Some("Write")
    );
    assert_eq!(
        updated.fields.get("status").map(String::as_str),
        Some("done")
    );

    let link = store
        .link_records(&updated.id, "mentions", &note.id)
        .expect("link records through Store API");
    assert_eq!(link.from_record_id, updated.id);
    assert_eq!(link.to_record_id, note.id);

    let links = store
        .links_for_record(&link.from_record_id)
        .expect("load links through Store API");
    assert_eq!(links.record_id, link.from_record_id);
    assert_eq!(links.links.len(), 1);
    assert_eq!(links.links[0].rel, "mentions");
    assert_eq!(links.links[0].peer_record_id, link.to_record_id);

    let summary = store
        .quick_context_summary()
        .expect("summarize store through Store API");
    assert_eq!(summary.record_count, 2);
    assert_eq!(summary.records_by_kind.get("task"), Some(&1));
    assert_eq!(summary.records_by_kind.get("note"), Some(&1));
    assert_eq!(summary.link_count, 1);
    assert_eq!(summary.links_by_relation.get("mentions"), Some(&1));
}
