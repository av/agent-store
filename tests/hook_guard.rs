//! Hook recursion-guard and failure-output behavior tests.
//!
//! Each test drives one scenario implemented in `tests/facts/cli_hooks.sh`.
//! Unlike the `hook_stress` scenarios these terminate quickly, so they run
//! in the default suite.

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
        .unwrap_or_else(|error| panic!("failed to launch hook guard case {case}: {error}"));
    assert!(status.success(), "hook guard case {case} failed: {status}");
}

/// A hook that mutates records matched by its own query stops recursing at
/// the depth cap of 3: the chain terminates promptly, every mutation still
/// commits, and the skipped dispatch is noted on the parent hook's captured
/// stderr.
#[test]
fn hook_recursion_depth_capped() {
    run_hook_case("hook_recursion_depth_capped");
}

/// A failing hook never hides the committed mutation's stdout output: the
/// record ID (or JSON envelope) is printed before hooks run and the hook
/// failure is reported on stderr with exit status 1.
#[test]
fn hook_failure_prints_mutation_output() {
    run_hook_case("hook_failure_prints_mutation_output");
}
