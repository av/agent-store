---
name: agent-store
description: >
  Core agent-store reference. Read this first. Covers the data model,
  initializing stores, pushing data, pulling by ID, querying with filters,
  inspecting schema and stats, and the skills system.
---

# agent-store

CLI-first unstructured data store for agents. Push, pull, and query
arbitrary data with no schema, no migrations, no boilerplate. SQLite
backend, per-project storage.

For the full command reference, run:
  agent-store skills get agent-store --full

Related skills:
  agent-store skills get agent-store-patterns   — workflow recipes for common agent tasks
  agent-store skills get agent-store-pipelines  — shell composition and batch operations

## Data model

Every piece of data in the store is an **entry**. An entry has:

| Field        | What it is                                 | Set via              |
|--------------|--------------------------------------------|----------------------|
| **id**       | UUID, assigned on push                     | automatic            |
| **data**     | Arbitrary text or JSON blob (the payload)  | stdin                |
| **type**     | Optional entity classification             | `--type`             |
| **labels**   | Zero or more tags                          | `--label` (repeat)   |
| **attributes** | Zero or more key-value pairs             | `--attr k=v` (repeat)|
| **created_at** | Timestamp                                | automatic            |

**When to use what:**
- **type** — what the entry *is* (task, decision, note, config, artifact)
- **labels** — cross-cutting tags (urgent, reviewed, step-1, session-a)
- **attributes** — structured metadata for filtering (status=pending, priority=high, assignee=agent)

Types and labels are for broad categorization. Attributes are for precise filtering with AND logic.

## The core loop

```bash
agent-store init                              # 1. Create the store
echo "data" | agent-store push --label tag    # 2. Store something
agent-store query --label tag                 # 3. Find it
agent-store pull <id>                         # 4. Retrieve by ID
agent-store schema                            # 5. See what's in the store
```

## Quickstart

```bash
# Initialize a store in the current directory
agent-store init

# Store arbitrary data from stdin
echo '{"task": "review PR #42", "status": "pending"}' | agent-store push --type task --label review

# Store with attributes for structured filtering
echo "fix auth bug" | agent-store push --type task --label urgent --attr priority=high --attr assignee=agent

# Get the ID for later retrieval (quiet mode)
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
agent-store query --json | jq '.[].data'

# Inspect the store
agent-store schema    # entity types and label counts
agent-store stats     # entry count and store size
```

## Commands

| Command | What it does |
|---------|-------------|
| `init` | Create `.agent-store/store.db`, install skills to `.agents/skills/`, set up project docs |
| `push` | Read stdin, store as entry. Flags: `--label`, `--type`, `--attr key=value`, `--quiet` |
| `pull <id>` | Retrieve entry by ID, print data to stdout |
| `query` | List entries. Filter: `--label` (repeat), `--type`, `--attr key=value` (repeat), `--json`, `--count`, `--limit N`, `--offset N` |
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

# Multi-line data (heredoc)
agent-store push --type note --label meeting <<'EOF'
Sprint review notes:
- Auth service migration complete
- Dashboard redesign blocked on API changes
- Next sprint: focus on performance
EOF
```

## Querying data

```bash
# All entries (raw data output)
agent-store query

# Filter by label
agent-store query --label important

# Filter by multiple labels (AND logic — entry must have all)
agent-store query --label urgent --label backend

# Filter by entity type
agent-store query --type task

# Filter by attribute
agent-store query --attr priority=high

# Combine filters (AND logic — all conditions must match)
agent-store query --label review --type task --attr status=open

# JSON output — array of objects with id, data, entity_type, created_at, labels, attributes
agent-store query --json

# Count matching entries (outputs just a number — useful for scripting)
agent-store query --label urgent --count

# Pagination
agent-store query --limit 10                  # first 10 entries
agent-store query --limit 10 --offset 20      # entries 21-30
```

**Default output** is raw entry data (just the payloads) concatenated with no
separator. Entries only appear on separate lines if their data contains trailing
newlines. For structured or predictable output, use `--json`.

**JSON output** (`--json`) returns the full entry objects including metadata,
useful when you need IDs, timestamps, labels, or attributes.

## Configuration

```bash
# Default: store lives at .agent-store/store.db in current directory
agent-store init

# Override with environment variable
AGENT_STORE_PATH=/path/to/custom/store agent-store init

# Persist the override for the session
export AGENT_STORE_PATH=/shared/team-store
agent-store push --type note <<< "now writing to the shared store"
```

The store is always a single SQLite file. No daemon, no network, no config files.

## Skills system

Skills are usage guides embedded in the binary. They're always version-matched
to the CLI and install into `.agents/skills/` on `agent-store init`.

```bash
agent-store skills list                        # See all available skills
agent-store skills get agent-store             # This guide (overview)
agent-store skills get agent-store --full      # This guide + command reference
agent-store skills get agent-store-patterns    # Workflow recipes
agent-store skills get agent-store-pipelines   # Shell composition
agent-store skills path agent-store            # Print skill data directory
```
