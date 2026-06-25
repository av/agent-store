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
agent-store query --json > backup.json

# JSONL format (preferred — each line is independent, streamable)
agent-store export > backup.jsonl
```

### Filtered export

```bash
# Export only tasks
agent-store query --type task --json > tasks.json

# Export by label
agent-store query --label critical --json > critical.json

# Export with compound filters
agent-store query --type task --attr status=open --json > open-tasks.json

# Using export command (native JSONL, with all filters)
agent-store export --type task > tasks.jsonl
agent-store export --label critical > critical.jsonl
agent-store export --type task --not-label done > open-tasks.jsonl
agent-store export --after "2024-06-01" --before "2024-07-01" > june.jsonl
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

### Poll for new entries

```bash
LAST_COUNT=0
while true; do
  COUNT=$(agent-store query --type event --json | jq 'length')
  if [ "$COUNT" -gt "$LAST_COUNT" ]; then
    echo "New events detected: $((COUNT - LAST_COUNT))"
    # Process new entries
    agent-store query --type event --json \
      | jq -c ".[-$((COUNT - LAST_COUNT)):][]" \
      | while IFS= read -r entry; do
          echo "Processing: $(echo "$entry" | jq -r '.id')"
        done
    LAST_COUNT=$COUNT
  fi
  sleep 5
done
```

### Trigger on specific content

```bash
# Watch for high-priority entries
while true; do
  agent-store query --type alert --attr status=new --json | jq -c '.[]' | \
    while IFS= read -r alert; do
      ID=$(echo "$alert" | jq -r '.id')
      echo "ALERT: $(echo "$alert" | jq -r '.data')"
      # Mark as processed (push a new version with updated status)
      echo "$alert" | jq -r '.data' | agent-store push --type alert --attr status=processed --attr source="$ID"
    done
  sleep 10
done
```

### Wait for a condition

```bash
# Block until a specific entry exists
until agent-store query --type signal --label ready --json | jq -e 'length > 0' > /dev/null 2>&1; do
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

Since agent-store is append-only, "update" means pushing a new version and
querying for the latest:

```bash
# Push new version
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

Agent-store has no built-in delete, but you can manage growth by using
separate stores for ephemeral vs. persistent data:

```bash
# Ephemeral data in a throwaway store
AGENT_STORE_PATH=./scratch agent-store init
echo "temp result" | AGENT_STORE_PATH=./scratch agent-store push --type temp

# When done, just remove it
rm -rf ./scratch

# Persistent data stays in the default store
echo "important finding" | agent-store push --type finding --label permanent
```
