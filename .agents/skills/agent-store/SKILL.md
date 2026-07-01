---
name: agent-store
description: >
  Core agent-store guide for initializing stores, creating records, querying,
  and reading compact project context.
---

# agent-store

Use `agent-store init` once per project to create `.agent-store/`, install
these skills, and add project instructions when `AGENTS.md` or `CLAUDE.md`
already exists.

Core loop:

```bash
agent-store init
agent-store create task title="Write tests" status=pending
agent-store find 'kind=task and status=pending'
agent-store get <id>
agent-store ctx
```

Records have a kind plus arbitrary `key=value` fields. Use short IDs printed
by mutation commands to retrieve or update specific records.

Queries join comparisons with `and`, `or`, `not`, and parentheses. Quote
comparison values that contain spaces (`title='Write tests'`, single or
double quotes; backslash escapes an embedded quote), use `field=''` to match
empty-string fields, and run bare `agent-store find` (or `ls`) to list every
record.
