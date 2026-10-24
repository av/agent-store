---
name: agent-store-patterns
description: >
  Recipes for agent-store project memory: a decision log, tasks tracked
  across sessions, scratch notes, linked records, and a handoff note for the
  next session. Use when recording or looking up a project decision, when
  tracking or resuming multi-session work, at session start, and at the end
  of a session or when handing work to another agent.
---

# agent-store-patterns

Use records as small, queryable notes rather than long append-only logs.
Keep one field convention per kind so later sessions can query it.

Session start (or resume): read the summary, then the open work and the
latest handoff:

```bash
agent-store ctx
agent-store find 'kind=task and status!=done'
agent-store find kind=handoff --sort created_at --desc --limit 1
```

Decision log. Always use `area` (a short topic such as `auth`, `database` or
`ci`), `choice` (what was decided) and `reason` (why), so
`find kind=decision area=<topic>` finds every decision on a topic:

```bash
agent-store create decision area=auth choice="session cookies" reason="no token refresh to manage"
agent-store find kind=decision area=auth
agent-store find kind=decision --sort created_at --desc --limit 3 --timestamps   # latest decisions
```

When a decision is replaced, record the new one, link it to the old one, and
mark the old one:

```bash
agent-store link <new-id> supersedes <old-id>
agent-store set <old-id> status=superseded
```

Task tracking:

```bash
agent-store create task title="Fix parser" status=pending priority=high
agent-store find 'kind=task and status!=done'
agent-store find kind=task status=pending --sort created_at --limit 5   # oldest open work first
agent-store find 'kind=task and status!=done' --count
agent-store set <id> status=done
agent-store unset <id> priority     # drop a field that no longer applies
agent-store rm <id>                 # delete a task created by mistake
```

Link related records, e.g. a task to the decision it implements:

```bash
agent-store link <task-id> implements <decision-id>
agent-store links <decision-id>
agent-store unlink <task-id> implements <decision-id>
```

Scratchpad:

```bash
agent-store create scratch task=refactor step=1 note="parsed current API"
agent-store find 'kind=scratch and task=refactor'
```

Handoff, before ending a session or passing work on: update the tasks you
touched, then leave one note saying where things stand:

```bash
agent-store set <task-id> status=in-progress next="wire the parser into main"
agent-store create handoff summary="parser half done; tests pass" next="wire the parser into main"
```

The next session picks it up with the session-start commands above.

Chronology is built in: listings default to creation order (oldest first),
and the `created_at`/`updated_at` timestamps are sortable and queryable, so
records do not need a manual date field.
