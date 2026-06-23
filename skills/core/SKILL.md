---
name: core
description: Core agent-store usage guide. Read this before using agent-store. Covers initializing stores, pushing data, pulling by ID, querying with filters, inspecting schema and stats, and composing CLI pipelines.
---

# agent-store core

CLI-first unstructured data store for agents. Push, pull, and query
arbitrary data with no schema, no migrations, no boilerplate. SQLite
backend, per-project storage.

Start here (for AI agents):
  agent-store skills get core --full

## The core loop

```bash
agent-store init                              # 1. Initialize store
echo "data" | agent-store push --label tag    # 2. Store data
agent-store query --label tag                 # 3. Find it
agent-store schema                            # 4. See what's in the store
```

## Quickstart

```bash
# Initialize a store in the current directory
agent-store init

# Store arbitrary data from stdin
echo '{"task": "review PR #42", "status": "pending"}' | agent-store push --type task --label review

# Store with attributes for structured filtering
echo "fix auth bug" | agent-store push --type task --label urgent --attr priority=high --attr assignee=agent

# Get the ID for later retrieval
ID=$(echo "important data" | agent-store push --quiet)

# Retrieve by ID
agent-store pull $ID

# Find entries by label, type, or attributes
agent-store query --label urgent
agent-store query --type task
agent-store query --attr priority=high

# Combine filters (AND logic)
agent-store query --label urgent --type task --attr priority=high

# List everything
agent-store query

# JSON output for structured processing
agent-store query --json | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))"

# Inspect the store
agent-store schema    # entity types and label counts
agent-store stats     # entry count and store size
```

## Commands

| Command | What it does |
|---------|-------------|
| `init` | Create `.agent-store/store.db` in current directory |
| `push` | Read stdin, store as entry. Flags: `--label`, `--type`, `--attr key=value`, `--quiet` |
| `pull <id>` | Retrieve entry by ID, print data to stdout |
| `query` | List entries. Filter: `--label`, `--type`, `--attr key=value`, `--json` |
| `schema` | Show entity types and label counts |
| `stats` | Show entry count and store size |
| `skills` | List and read built-in usage guides |

## Pushing data

```bash
# Basic push — reads all of stdin
echo "any text or JSON" | agent-store push

# With metadata
echo "data" | agent-store push --label important --type note --attr priority=high

# Multiple labels
echo "data" | agent-store push --label urgent --label review

# Multiple attributes
echo "data" | agent-store push --attr key1=value1 --attr key2=value2

# Quiet mode — only prints the entry ID (for scripting)
ID=$(echo "data" | agent-store push --quiet)
```

## Querying data

```bash
# All entries
agent-store query

# Filter by label
agent-store query --label important

# Filter by entity type
agent-store query --type task

# Filter by attribute
agent-store query --attr priority=high

# Combine filters (AND)
agent-store query --label review --attr status=open

# JSON output — array of objects with id, data, entity_type, created_at, labels, attributes
agent-store query --json
```

## Pipeline patterns

```bash
# Pipe query results to another tool
agent-store query --label logs | grep "error"

# Store command output
ls -la | agent-store push --type listing --label project-files

# Round-trip: push then pull
ID=$(echo "roundtrip" | agent-store push --quiet)
agent-store pull $ID

# Process JSON output
agent-store query --json | jq '.[].data'

# Batch store from a file
while IFS= read -r line; do
  echo "$line" | agent-store push --label imported
done < data.txt
```

## Configuration

```bash
# Default: store lives at .agent-store/store.db in current directory
agent-store init

# Override with environment variable
export AGENT_STORE_PATH=/path/to/shared/store
agent-store init
```

## Common agent workflows

### Persistent scratchpad
```bash
# Store intermediate results
echo "$ANALYSIS_RESULT" | agent-store push --type scratch --label step1
echo "$NEXT_RESULT" | agent-store push --type scratch --label step2

# Retrieve later
agent-store query --type scratch --label step1
```

### Task tracking
```bash
echo "implement feature X" | agent-store push --type task --attr status=pending --attr priority=high
echo "fix bug Y" | agent-store push --type task --attr status=pending --attr priority=low

# Find pending high-priority tasks
agent-store query --type task --attr status=pending --attr priority=high
```

### Decision log
```bash
echo "chose SQLite over Postgres: simpler, no daemon, sufficient for single-agent use" | \
  agent-store push --type decision --label architecture
```
