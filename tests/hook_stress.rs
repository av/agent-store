//! Hook timeout and failure stress tests.
//!
//! Each test drives one heavy hook scenario implemented in
//! `tests/facts/cli_hooks.sh`. These scenarios wait out the real 30-second
//! hook timeout (some more than once), so they are `#[ignore]`d to keep the
//! default suite fast. Run them with:
//!
//! ```sh
//! cargo test --test hook_stress -- --ignored
//! ```

use std::path::PathBuf;
use std::process::Command;

fn run_hook_case(case: &str) {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script = repo.join("tests/facts/cli_hooks.sh");
    let status = Command::new("bash")
        .arg(&script)
        .arg(case)
        .current_dir(&repo)
        .status()
        .unwrap_or_else(|error| panic!("failed to launch hook stress case {case}: {error}"));
    assert!(status.success(), "hook stress case {case} failed: {status}");
}

macro_rules! hook_stress_case {
    ($name:ident) => {
        #[test]
        #[ignore = "waits out real 30-second hook timeouts; run with: cargo test --test hook_stress -- --ignored"]
        fn $name() {
            run_hook_case(stringify!($name));
        }
    };
}

hook_stress_case!(hook_failure_or_timeout_reports_committed_mutation);
hook_stress_case!(json_mutation_hook_failure_or_timeout_reports_committed_without_success_json);
hook_stress_case!(json_multiple_matching_hooks_stop_after_failure_or_timeout);
hook_stress_case!(hooks_run_sequentially_from_project_root_with_timeout);
hook_stress_case!(hook_output_capture_caps_and_help);
hook_stress_case!(hook_timeout_terminates_process_group);
