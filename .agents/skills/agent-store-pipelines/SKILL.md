---
name: agent-store-pipelines
description: >
  Shell composition patterns for importing, exporting, and transforming
  agent-store records.
---

# agent-store-pipelines

agent-store is designed to compose with ordinary shell tools.

Batch create from lines:

```bash
while IFS= read -r line; do
  agent-store create note text="$line"
done < notes.txt
```

Filter and format: `--json` list output wraps records in a
`{"records":[...]}` envelope, so iterate with `.records[]`:

```bash
agent-store find 'kind=task and status=pending' --json | jq -r '.records[].id'
```

Capture command output:

```bash
agent-store create log command=test output="$(cargo test 2>&1)"
```
