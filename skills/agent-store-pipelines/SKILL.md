---
name: agent-store-pipelines
description: >
  Shell composition and batch operations — import, export, tool chaining,
  aggregation, multi-store sync, and large data strategies.
---

# agent-store-pipelines

Patterns for composing agent-store with shell tools. Each section is
self-contained — jump to the one you need.

## Batch import

### Line-by-line from a file

```bash
while IFS= read -r line; do
  echo "$line" | agent-store push --type log --label imported
done < data.txt
```

### JSON array — one entry per element

```bash
jq -c '.[]' items.json | while IFS= read -r item; do
  echo "$item" | agent-store push --type item --label batch
done
```

### CSV — columns as attributes

```bash
# Skip header, map columns to attributes
tail -n +2 data.csv | while IFS=, read -r name email role; do
  echo "$name" | agent-store push --type contact \
    --attr email="$email" --attr role="$role"
done
```

### Directory contents — one entry per file

```bash
for f in src/*.rs; do
  cat "$f" | agent-store push --type source \
    --label "$(basename "$f")" --attr path="$f"
done
```

### Command output

```bash
# Store each test failure as its own entry
cargo test 2>&1 | grep "^test .* FAILED" | while IFS= read -r line; do
  echo "$line" | agent-store push --type test-failure --label ci
done
```

### Import with deduplication

Check before pushing to avoid duplicates (see also Idempotent operations below):

```bash
while IFS= read -r line; do
  EXISTS=$(agent-store query --type log --json | jq -r --arg d "$line" '[.[] | select(.data | rtrimstr("\n") == $d)] | length')
  if [ "$EXISTS" = "0" ]; then
    echo "$line" | agent-store push --type log --label imported
  fi
done < data.txt
```

## Export and backup

### Full store to JSON file

```bash
# JSONL format (default — each line is independent, streamable)
agent-store export > backup.jsonl

# JSON array (proper JSON, pretty-printed)
agent-store export --format json > backup.json

# CSV (headers: id,created_at,entity_type,labels,data)
agent-store export --format csv > backup.csv

# Legacy approach via query
agent-store query --json > backup.json
```

### Filtered export

```bash
# Export only tasks
agent-store export --type task > tasks.jsonl

# Export by label
agent-store export --label critical > critical.jsonl

# Export with compound filters
agent-store export --type task --not-label done > open-tasks.jsonl
agent-store export --after "2024-06-01" --before "2024-07-01" > june.jsonl

# Full-text search export
agent-store export --search "database migration" > migrations.jsonl

# Export in different formats
agent-store export --type task --format json > tasks.json
agent-store export --type task --format csv > tasks.csv
```

### One file per entry

```bash
agent-store query --json | jq -c '.[]' | while IFS= read -r entry; do
  ID=$(echo "$entry" | jq -r '.id')
  echo "$entry" | jq '.' > "export/${ID}.json"
done
```

### Data-only export (no metadata)

```bash
agent-store query --json | jq -r '.[].data' > data-only.txt
```

### Restore from backup

```bash
# From JSONL backup (preserves timestamps, labels, attributes)
cat backup.jsonl | agent-store import

# From JSON array backup (legacy format)
jq -c '.[]' backup.json | agent-store import
```

## Round-trip processing

Pull an entry, transform it, push the result back.

### Transform and re-store

```bash
ID=$(agent-store query --type config --json | jq -r '.[0].id')
agent-store pull "$ID" | jq '.version = "2.0"' | \
  agent-store push --type config --label migrated --attr source="$ID"
```

### Batch transform

```bash
agent-store query --type raw-data --json | jq -c '.[]' | while IFS= read -r entry; do
  ID=$(echo "$entry" | jq -r '.id')
  echo "$entry" | jq -r '.data' | python3 transform.py | \
    agent-store push --type processed --attr source="$ID"
done
```

### Enrich entries with external data

```bash
agent-store query --type url --json | jq -c '.[]' | while IFS= read -r entry; do
  URL=$(echo "$entry" | jq -r '.data')
  SRC_ID=$(echo "$entry" | jq -r '.id')
  curl -sL "$URL" | agent-store push --type fetched \
    --label crawl --attr source-url="$URL" --attr source-id="$SRC_ID"
done
```

## Tool chaining

### jq — filter and reshape JSON output

```bash
# Extract specific fields
agent-store query --json | jq '[.[] | {id, data, type: .entity_type}]'

# Filter in jq (more flexible than CLI filters)
agent-store query --json | jq '[.[] | select(.attributes.priority == "high")]'

# Count by type
agent-store query --json | jq 'group_by(.entity_type) | map({type: .[0].entity_type, count: length})'

# Get newest entry
agent-store query --json | jq 'sort_by(.created_at) | last'

# Pluck all unique label values
agent-store query --json | jq '[.[].labels[]] | unique'
```

### grep — search entry data

```bash
# Find entries containing a pattern
agent-store query --type log | grep -i "error"

# Find entries and show context
agent-store query --type note | grep -B2 -A2 "TODO"
```

For structured search, prefer `--search` (FTS5) over grep — it
tokenizes content, supports phrases and boolean operators, and returns
results ranked by relevance:

```bash
agent-store query --search "database connection" --type log
agent-store query --search "error NOT timeout" --json
```

### awk — structured text processing

```bash
# Count entries per line of output
agent-store query --type metric | awk '{sum += $1} END {print "total:", sum}'

# Extract fields from structured text entries
agent-store query --type csv-row | awk -F, '{print $2}'
```

### sed — transform on the fly

```bash
# Sanitize output before piping elsewhere
agent-store query --type secret | sed 's/password=.*/password=***/'
```

### python — complex transforms

```bash
# Parse and analyze JSON entries
agent-store query --json | python3 -c "
import sys, json
entries = json.load(sys.stdin)
by_type = {}
for e in entries:
    t = e.get('entity_type') or '(none)'
    by_type.setdefault(t, []).append(e)
for t, es in sorted(by_type.items()):
    print(f'{t}: {len(es)} entries')
"
```

### Chained pipeline

```bash
# Find high-priority open tasks, extract just the descriptions, sort
agent-store query --type task --attr status=open --json \
  | jq -r '.[] | select(.attributes.priority == "high") | .data' \
  | sort
```

## Aggregation

### Count entries

```bash
# Total count
agent-store query --count

# Count by type
agent-store query --json | jq 'group_by(.entity_type) | .[] | {type: .[0].entity_type, count: length}'

# Count by label
agent-store query --json | jq '[.[].labels[]] | group_by(.) | .[] | {label: .[0], count: length}'
```

### Group and summarize

```bash
# Group tasks by status
agent-store query --type task --json | jq '
  group_by(.attributes.status) | .[] | {
    status: .[0].attributes.status,
    count: length,
    items: [.[].data]
  }'
```

### Time-based analysis

```bash
# Entries created today
TODAY=$(date +%Y-%m-%d)
agent-store query --json | jq --arg d "$TODAY" '[.[] | select(.created_at | startswith($d))]'

# Simpler: use --after filter
agent-store query --after "$(date +%Y-%m-%d)"

# Entries per day
agent-store query --json | jq '
  group_by(.created_at | split(" ")[0]) | .[] | {
    date: .[0].created_at | split(" ")[0],
    count: length
  }'
```

### Store aggregation results

```bash
agent-store query --type task --json \
  | jq '{total: length, open: [.[] | select(.attributes.status == "open")] | length, done: [.[] | select(.attributes.status == "done")] | length}' \
  | agent-store push --type summary --label tasks --attr generated-by=pipeline
```

## Tally pipelines

`tally --by` produces tab-separated `value\tcount` output, sorted by
count descending. This composes cleanly with standard text tools.

### Sort and filter tally output

```bash
# Top 5 labels by entry count
agent-store tally --by label | head -5

# Reverse sort (ascending) — find rare values
agent-store tally --by label | sort -t$'\t' -k2 -n

# Filter tally to values with 10+ entries
agent-store tally --by type | awk -F'\t' '$2 >= 10'
```

### Tally with query filters — scoped counts

```bash
# Count labels only among high-priority entries
agent-store tally --by label --attr priority=high

# Count types created this week
agent-store tally --by type --after "$(date -d '7 days ago' +%Y-%m-%d)"

# Count status values for tasks only
agent-store tally --by attr:status --type task
```

### Tally to JSON for downstream processing

```bash
# Pipe tally JSON into jq for further reshaping
agent-store tally --by label --json | jq '[.[] | select(.count > 5)]'

# Store a tally snapshot as a summary entry
agent-store tally --by type --json | agent-store push --type summary \
  --label tally-snapshot --attr dimension=type
```

### Tally-driven drill-down

```bash
# Find the most common label, then list its entries
TOP=$(agent-store tally --by label | head -1 | cut -f1)
agent-store query --label "$TOP"

# Find types with only 1 entry (candidates for cleanup)
agent-store tally --by type | awk -F'\t' '$2 == 1 {print $1}' | while read -r t; do
  agent-store query --type "$t"
done
```

## Update pipelines

Bulk metadata mutations via `update` with query filters. Always preview
with `--dry-run` before applying with `--confirm`.

### Tag all entries matching a query

```bash
# Tag all pending tasks as stale if created before this month
agent-store update --type task --attr status=pending \
  --before "$(date +%Y-%m-01)" --tag stale --confirm

# Tag search results — flag entries mentioning "deprecated"
agent-store update --search "deprecated" --tag needs-review --confirm
```

### Batch status transition

```bash
# Move all in-progress tasks to done
agent-store update --type task --attr status=in-progress \
  --set status=done --tag done --confirm

# Reset stale entries — untag stale, set status back to pending
agent-store update --label stale --untag stale --set status=pending --confirm
```

### Preview before applying

```bash
# Dry-run shows affected entries without changing anything
agent-store update --type cache --before "2024-01-01" --tag expired --dry-run

# Dry-run with JSON — get full entry objects for inspection
agent-store update --label old --set status=archived --dry-run --json \
  | jq '.[].id'
```

### Combine tally + update — find a dimension, act on it

```bash
# Find the most common label, then tag all its entries
TOP=$(agent-store tally --by label | head -1 | cut -f1)
agent-store update --label "$TOP" --tag bulk-reviewed --confirm

# Find types with many entries and archive them
agent-store tally --by type | awk -F'\t' '$2 > 100 {print $1}' | while read -r t; do
  agent-store update --type "$t" --tag high-volume --confirm
done
```

### Bulk link/unlink via update

```bash
# Link all tasks in a sprint to the sprint entry
SPRINT=$(agent-store query --label sprint --attr name=Q3 --json | jq -r '.[0].id')
agent-store update --label task --attr sprint=Q3 --link "sprint:$SPRINT" --confirm

# Unlink all entries from a deprecated target
agent-store update --label task --unlink "depends:$OLD_ID" --confirm

# Combine link + tag in one atomic operation
agent-store update $ID --link "blocks:$OTHER" --tag blocking --json
```

## Links pipelines

Directional typed edges between entries. Use `link`/`unlink` for
post-creation, `push --link rel:id` at creation, `update --link`/`--unlink`
for batch operations, and `--linked-to`/`--linked-from` for traversal.

### Build a dependency graph

```bash
# Create tasks and link them
TASK_A=$(echo "design API" | agent-store push --type task --label backend --id-only)
TASK_B=$(echo "implement API" | agent-store push --type task --label backend --id-only)
TASK_C=$(echo "write tests" | agent-store push --type task --label backend --id-only)

agent-store link "$TASK_B" "$TASK_A" depends-on
agent-store link "$TASK_C" "$TASK_B" depends-on
```

### Create linked entries at push time

```bash
# Push a subtask that links to its parent in one command
PARENT=$(agent-store query --type epic --label auth --last --json | jq -r '.[0].id')
echo "add OAuth provider" | agent-store push --type task \
  --link "child-of:$PARENT" --label auth --id-only
```

### Walk link chains — find all dependencies

```bash
# Direct dependencies of an entry
agent-store query --linked-from "$TASK_B" --link-rel depends-on

# Recursive walk — collect the full dependency tree
walk_deps() {
  local id="$1"
  agent-store query --linked-from "$id" --link-rel depends-on --json \
    | jq -r '.[].id' | while read -r dep; do
      agent-store pull "$dep"
      walk_deps "$dep"
    done
}
walk_deps "$TASK_C"
```

### Find orphan entries — no incoming or outgoing links

```bash
# Entries of a type that nothing links to and that link to nothing
agent-store query --type task --json | jq -r '.[].id' | while read -r id; do
  FROM=$(agent-store query --linked-from "$id" --json | jq 'length')
  TO=$(agent-store query --linked-to "$id" --json | jq 'length')
  if [ "$FROM" = "0" ] && [ "$TO" = "0" ]; then
    echo "orphan: $id"
    agent-store pull "$id"
  fi
done
```

### Inspect the link graph for an entry

```bash
# Show an entry with all its links
agent-store pull "$ID" --json --with-links | jq '{
  data: .data,
  links_from: [.links_from[] | {to, rel}],
  links_to: [.links_to[] | {from, rel}]
}'
```

### Bulk link — connect a set of entries to a parent

```bash
# Link all tasks with a label to an epic
EPIC=$(agent-store query --type epic --label auth --last --json | jq -r '.[0].id')
agent-store query --type task --label auth --json | jq -r '.[].id' | while read -r id; do
  agent-store link "$id" "$EPIC" child-of
done
```

## Changelog pipelines

`log` shows the audit trail of metadata mutations (tag, untag, set-attr,
unset-attr, delete). Use it to review activity, detect patterns, and
build dashboards.

### Recent activity dashboard

```bash
# Last 20 changes across the store
agent-store log --limit 20

# Changes in the last hour
agent-store log --since "$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')"

# Changes on entries with a specific label
agent-store log --label deploy --limit 10
```

### Entry-level audit

```bash
# Full mutation history for a single entry
agent-store log "$ID"

# Entry history as JSON for processing
agent-store log "$ID" --json | jq '.[] | {op: .operation, key, old: .old_value, new: .new_value}'
```

### Change frequency analysis

```bash
# Most frequently changed entries (by entry ID)
agent-store log --limit 500 --json \
  | jq '[group_by(.entry_id)[] | {id: .[0].entry_id, changes: length}]
        | sort_by(.changes) | reverse | .[:10]'

# Count changes by operation type
agent-store log --limit 500 --json \
  | jq 'group_by(.operation)[] | {op: .[0].operation, count: length}'
```

### Links + log — audit linked entries

```bash
# Show changelog for all entries linked from a parent
agent-store query --linked-from "$PARENT" --json | jq -r '.[].id' | while read -r id; do
  echo "=== $id ==="
  agent-store log "$id" --limit 5
done

# Find entries that were recently modified AND are linked to a target
agent-store log --since "$(date -d '1 day ago' '+%Y-%m-%d %H:%M:%S')" --json \
  | jq -r '[.[].entry_id] | unique[]' | while read -r id; do
    LINKED=$(agent-store query --linked-to "$id" --json | jq 'length')
    if [ "$LINKED" -gt "0" ]; then
      echo "linked + recently changed: $id"
    fi
  done
```

## Cross-feature pipelines

Combining tally, update, links, and log for multi-step workflows.

### Tally + update — find and act on a dimension

```bash
# Find labels with only 1 entry and tag them for review
agent-store tally --by label | awk -F'\t' '$2 == 1 {print $1}' | while read -r lbl; do
  agent-store update --label "$lbl" --tag singleton-review --confirm
done

# Find the busiest status and log those entries
TOP_STATUS=$(agent-store tally --by attr:status | head -1 | cut -f1)
agent-store query --attr status="$TOP_STATUS" --json | jq -r '.[].id' | while read -r id; do
  agent-store log "$id" --limit 3
done
```

### Links + tally — count by relationship

```bash
# For each entry linked from a parent, tally their labels
agent-store query --linked-from "$PARENT" --json | jq -r '.[].id' | while read -r id; do
  echo "--- $id ---"
  # Tally scoped to entries linked from this child
  agent-store tally --by label --linked-from "$id"
done
```

### Upsert in pipelines — idempotent batch import

```bash
# Import rows, creating or updating by unique key
while IFS=, read -r name email role; do
  echo "$name" | agent-store push --upsert --type contact \
    --attr email="$email" --attr role="$role"
done < contacts.csv
```

### Log-driven alerting — detect recent bulk changes

```bash
# Alert if more than 10 changes happened in the last 5 minutes
COUNT=$(agent-store log --since "$(date -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S')" --json | jq 'length')
if [ "$COUNT" -gt 10 ]; then
  echo "ALERT: $COUNT mutations in last 5 minutes"
  agent-store log --since "$(date -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S')" --limit 5
fi
```

## Multi-store operations

Use `AGENT_STORE_PATH` to point at different stores.

### Work with a specific store

```bash
AGENT_STORE_PATH=/path/to/other agent-store query --json
```

### Copy entries between stores

```bash
# Export from source, import to destination (preserves all metadata)
AGENT_STORE_PATH=./source agent-store export --type task | AGENT_STORE_PATH=./dest agent-store import
```

### Sync with label and attribute preservation

```bash
# Export/import preserves labels, attributes, and timestamps automatically
AGENT_STORE_PATH=./source agent-store export --label shared | AGENT_STORE_PATH=./dest agent-store import
```

### Shared team store

```bash
# Point all agents at the same store
export AGENT_STORE_PATH=/shared/team-store
agent-store init  # first time only
echo "finding from agent-1" | agent-store push --type finding --attr agent=agent-1
```

## Templated push

### Generate entries from a list

```bash
for env in dev staging prod; do
  echo '{"environment": "'$env'", "status": "unknown"}' | \
    agent-store push --type env-status --label "$env" --attr env="$env"
done
```

### Generate from a template

```bash
TEMPLATE='{"task": "%s", "status": "pending", "created": "%s"}'
NOW=$(date -Iseconds)

for task in "build" "test" "deploy"; do
  printf "$TEMPLATE" "$task" "$NOW" | \
    agent-store push --type task --label pipeline --attr step="$task"
done
```

### Scaffold from config

```bash
# Read a YAML/JSON config and create entries for each item
jq -c '.services[]' config.json | while IFS= read -r svc; do
  NAME=$(echo "$svc" | jq -r '.name')
  echo "$svc" | agent-store push --type service --label inventory --attr name="$NAME"
done
```

## Watch and poll patterns

### Live watch with tail

The `tail` command streams new entries as they arrive — no manual
polling loop needed.

```bash
# Watch all new entries (Ctrl+C to stop)
agent-store tail

# Watch specific entry types with JSON output
agent-store tail --type event --json

# Watch with filters
agent-store tail --label deploy --attr env=production --json

# Pipe to processing
agent-store tail --type alert --json | jq -r '.data' | while IFS= read -r alert; do
  echo "ALERT: $alert"
done

# Custom poll interval (default: 1 second)
agent-store tail --interval 5 --type metric

# Start from a past timestamp
agent-store tail --since "2024-06-01 09:00:00" --json

# Full-text search on live entries
agent-store tail --search "error" --type log --json
```

### Trigger on specific content

```bash
# Watch for high-priority entries and mark as processed
agent-store tail --type alert --attr status=new --json | jq -c '.' | \
  while IFS= read -r alert; do
    ID=$(echo "$alert" | jq -r '.id')
    echo "ALERT: $(echo "$alert" | jq -r '.data')"
    # Mark as processed using set-attr (no new entry needed)
    agent-store set-attr "$ID" status processed
  done
```

### Wait for a condition

```bash
# Block until a specific entry exists (using tail + head)
agent-store tail --type signal --label ready | head -1
echo "Ready signal received"

# Alternative: poll with query --last
until agent-store query --type signal --label ready --last 2>/dev/null; do
  sleep 2
done
echo "Ready signal received"
```

## Idempotent operations

### Push only if no matching entry exists

```bash
push_unique() {
  local data="$1" type="$2" label="$3"
  local exists
  exists=$(agent-store query --type "$type" --label "$label" --json \
    | jq -r --arg d "$data" '[.[] | select(.data | rtrimstr("\n") == $d)] | length')
  if [ "$exists" = "0" ]; then
    echo "$data" | agent-store push --type "$type" --label "$label"
  fi
}

push_unique "config v1" config current
push_unique "config v1" config current  # no-op, already exists
```

### Upsert pattern (latest-wins)

Use `push --update` for true in-place replacement, or push a new entry and
query `--latest` for append-only versioning:

```bash
# In-place update (no new entry, replaces data)
ID=$(echo "v1 config" | agent-store push --type config --label current --id-only)
echo "v2 config" | agent-store push --update "$ID"

# Append-only versioning (preserves history)
echo "v2 config" | agent-store push --type config --label current --attr version=2

# Always get the newest entry of a type+label
agent-store query --type config --label current --latest
```

### Deduplicate existing entries

```bash
# Find and report duplicates (same data + type)
agent-store query --json | jq '
  group_by(.data + (.entity_type // "")) 
  | map(select(length > 1)) 
  | .[] | {data: .[0].data, count: length, ids: [.[].id]}'
```

## Large data handling

### Check store size before and after

```bash
agent-store stats  # before
cat large-file.bin | agent-store push --type blob --label backup
agent-store stats  # after — compare sizes
```

### Chunk large files

```bash
# Split into 1MB chunks, store each with sequence number
split -b 1M large-file.bin /tmp/chunk_
SEQ=0
for chunk in /tmp/chunk_*; do
  cat "$chunk" | agent-store push --type chunk \
    --label large-file --attr seq="$SEQ" --attr filename="large-file.bin"
  SEQ=$((SEQ + 1))
  rm "$chunk"
done
echo "Stored in $SEQ chunks"
```

### Reassemble chunks

```bash
agent-store query --type chunk --label large-file --json \
  | jq -r 'sort_by(.attributes.seq | tonumber) | .[].id' \
  | while IFS= read -r id; do
      agent-store pull "$id"
    done > reassembled-file.bin
```

### Size-aware import

```bash
MAX_ENTRY_KB=512

for f in data/*; do
  SIZE_KB=$(du -k "$f" | cut -f1)
  if [ "$SIZE_KB" -gt "$MAX_ENTRY_KB" ]; then
    echo "Skipping $f (${SIZE_KB}KB > ${MAX_ENTRY_KB}KB limit)"
    continue
  fi
  cat "$f" | agent-store push --type file --label import --attr path="$f" --attr size-kb="$SIZE_KB"
done
```

### Prune old entries

```bash
# Delete entries by filter — preview first
agent-store delete --type cache --before "2024-01-01" --dry-run
agent-store delete --type cache --before "2024-01-01" --confirm

# Collect expired entries (those past their --ttl)
agent-store gc

# Aggressive: delete ALL entries older than 7 days
agent-store gc --ttl 7d

# Preview gc before running
agent-store gc --dry-run

# Reclaim disk space after large deletes
agent-store compact

# Delete scratch entries from a completed task
agent-store delete --type scratch --attr task=refactor-auth --confirm

# Full-text search delete
agent-store delete --search "deprecated" --confirm

# For ephemeral data, use separate stores
AGENT_STORE_PATH=./scratch agent-store init
echo "temp result" | AGENT_STORE_PATH=./scratch agent-store push --type temp
rm -rf ./scratch   # when done, just remove the store
```
