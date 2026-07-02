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

Bulk import JSONL with `create --stdin` (one `{"kind":...,"fields":{...}}`
object per line, the `find --json` record shape; extra keys like `id` and
timestamps are ignored, so exports round-trip):

```bash
agent-store find kind=task --json | jq -c '.records[]' | agent-store create --stdin
```

Every line is validated before any record is created; an invalid line exits
non-zero naming the line number with nothing imported.

Filter and format: `--json` list output wraps records in a
`{"records":[...]}` envelope, so iterate with `.records[]`:

```bash
agent-store find 'kind=task and status=pending' --json | jq -r '.records[].id'
```

JSON records include `created_at` and `updated_at` timestamps. Prefer the
built-in `--sort`, `--desc`, `--limit`, and `--count` flags over shell-side
`sort`, `head`, or `wc -l`:

```bash
agent-store find kind=log --sort updated_at --desc --limit 10
agent-store find kind=note --count
```

Capture command output:

```bash
agent-store create log command=test output="$(cargo test 2>&1)"
```
