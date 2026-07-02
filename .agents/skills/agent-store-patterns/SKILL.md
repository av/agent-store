---
name: agent-store-patterns
description: >
  Workflow recipes for using agent-store as a scratchpad, task tracker,
  decision log, and handoff memory.
---

# agent-store-patterns

Use records as small, queryable notes rather than long append-only logs.

Scratchpad:

```bash
agent-store create scratch task=refactor step=1 note="parsed current API"
agent-store find 'kind=scratch and task=refactor'
```

Task tracking:

```bash
agent-store create task title="Fix parser" status=pending priority=high
agent-store find 'kind=task and status!=done'
agent-store find kind=task status=pending --sort created_at --limit 5   # oldest open work first
agent-store find 'kind=task and status!=done' --count
agent-store set <id> status=done
```

Decision log:

```bash
agent-store create decision area=storage choice=sqlite reason="single-file project-local store"
agent-store find 'kind=decision and area=storage'
agent-store find kind=decision --sort created_at --desc --limit 3 --timestamps   # latest decisions
```

Chronology is built in: listings default to creation order (oldest first),
and the `created_at`/`updated_at` timestamps are sortable and queryable, so
records do not need a manual date field.
