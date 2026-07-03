# Examples

Runnable shell scripts demonstrating real agent-store workflows. Each script
is self-contained: it creates a throwaway store in a temp directory
(`mktemp -d`), cleans up after itself, is safe to re-run, and exits non-zero
on failure (`set -euo pipefail`).

Requirements: `agent-store` on your `PATH` (or point the `AGENT_STORE`
environment variable at a binary) and `jq`.

```bash
./examples/task-tracker.sh
# or, with a locally built binary:
AGENT_STORE=target/release/agent-store ./examples/task-tracker.sh
```

| Script | What it shows |
| --- | --- |
| [task-tracker.sh](task-tracker.sh) | Task lifecycle: create, query open work, sort/limit/count, update status, close out |
| [decision-log.sh](decision-log.sh) | Queryable decision log: filter by area, latest decisions with timestamps, link a decision to the task it resolves |
| [session-handoff.sh](session-handoff.sh) | Session handoff: one session leaves breadcrumbs, the next reorients with `ctx` and targeted queries |
| [jsonl-pipeline.sh](jsonl-pipeline.sh) | Export/transform/import: `find --json` to JSONL, jq transforms, bulk `create --stdin`, validate-before-import |
| [hooks-audit.sh](hooks-audit.sh) | Audit logging with hooks: `AGENT_STORE_*` env vars, query-scoped hooks, `hook runs` history |
