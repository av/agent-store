# Examples

Runnable shell scripts demonstrating real agent-store workflows. Each script
is self-contained: it creates a throwaway store in a temp directory
(`mktemp -d`), cleans up after itself, is safe to re-run, and exits non-zero
on failure (`set -euo pipefail`).

Requirements: `agent-store` on your `PATH` (or point the `AGENT_STORE`
environment variable at a binary) and `jq`. The scripts live in this
repository's `examples/` directory, so clone it and run them from the
repository root:

```bash
git clone https://github.com/av/agent-store && cd agent-store
./examples/task-tracker.sh
# or, with a locally built binary:
AGENT_STORE=target/release/agent-store ./examples/task-tracker.sh
```

| Script | What it shows |
| --- | --- |
| [task-tracker.sh](task-tracker.sh) | Task lifecycle: create, query open work, sort/limit/count, update status, close out |
| [decision-log.sh](decision-log.sh) | Queryable decision log: filter by area, latest decisions with timestamps, link a decision to the task it resolves |
| [session-handoff.sh](session-handoff.sh) | Session handoff: one session leaves breadcrumbs, the next reorients with `ctx` and targeted queries |
| [import-memory-md.sh](import-memory-md.sh) | Migrate an existing MEMORY.md: the one-line import, a structured pass that turns headings into a queryable `topic` field, and the `find`/`ctx` payoff |
| [jsonl-pipeline.sh](jsonl-pipeline.sh) | Export/transform/import: `find --json` to JSONL, jq transforms, bulk `create --stdin`, validate-before-import |
| [hooks-audit.sh](hooks-audit.sh) | Audit logging with hooks: `AGENT_STORE_*` env vars, query-scoped hooks, `hook runs` history |
| [memory-graph.sh](memory-graph.sh) | Linked memory graph: findings `supports` a conclusion, a task `implements` it, `link.in`/`link.out`/`link.out.<rel>=<id>` traversal, `ctx` relation counts, self-link rejection, `--json` error envelope |
