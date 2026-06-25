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

# Get the ID for later retrieval
ID=$(echo "important data" | agent-store push | awk '{print $3}')

# Retrieve by ID
agent-store pull $ID

# Retrieve full entry as JSON (with labels, attributes, timestamps)
agent-store pull $ID --json | jq .labels

# Binary-safe pull (omit trailing newline)
agent-store pull $ID --raw | sha256sum

# Find entries by label, type, or attributes
agent-store query --label urgent
agent-store query --type task
agent-store query --attr priority=high

# Exclude entries with a label
agent-store query --label todo --not-label done       # open todos
agent-store query --not-label done --not-label archived  # exclude multiple

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
| `push` | Read stdin, store as entry. Flags: `--label`, `--type`, `--attr key=value`, `-q`/`--quiet`, `--id-only` |
| `pull <id>` | Retrieve entry by ID, print data to stdout. Flags: `--json` (full entry as JSON object), `--raw` (omit trailing newline for binary-safe piping) |
| `query` | List entries. Filter: `--label` (repeat), `--not-label` (repeat, exclude), `--type`, `--attr key=value` (repeat), `--data <substring>`, `--after <datetime>`, `--before <datetime>`, `--json`, `--count`, `--latest`, `--limit N`, `--offset N`, `-r`/`--reverse` |
| `schema` | Show entity types and label counts |
| `stats` | Show entry count and store size. Flags: `--json` |
| `skills` | List and read built-in usage guides |
| `export` | Export entries as JSONL (one JSON object per line). Filter: `--id`, `--label` (repeat), `--not-label` (repeat), `--type`, `--attr key=value` (repeat), `--data`, `--after`, `--before` |
| `import` | Import entries from JSONL on stdin (complement of export). Generates fresh IDs. Flags: `--dry-run` |
| `purge` | Delete ALL entries (destructive). Requires `--confirm` flag. |
| `completions <shell>` | Generate shell completions (bash, zsh, fish, elvish, powershell) |

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

# Quiet mode — suppresses all output (for scripts that don't need feedback)
echo "data" | agent-store push --quiet

# Get the ID for later retrieval (scripting-friendly)
ID=$(echo "data" | agent-store push --id-only)

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

# Most recent entry with a label (the most common agent pattern)
agent-store query --label config --latest --json

# Oldest-first ordering
agent-store query --label log --reverse

# Oldest single entry
agent-store query --label log --latest --reverse

# Search by data content (substring match)
agent-store query --data "error"              # entries containing "error"
agent-store query --data "error" --label logs # combine with other filters

# Exclude entries by label (repeatable, AND semantics)
agent-store query --label todo --not-label done         # open todos
agent-store query --not-label done --not-label archived # exclude multiple labels
agent-store query --label todo --not-label done --json  # combine with --json

# Date filters
agent-store query --after "2024-06-01"                # entries after date
agent-store query --before "2024-06-30"               # entries before date
agent-store query --after "2024-06-01" --before "2024-06-30"  # date range
agent-store query --label log --after "2024-06-01 09:00:00"   # combine with filters

# Pagination
agent-store query --limit 10                  # first 10 entries
agent-store query --limit 10 --offset 20      # entries 21-30
agent-store query --count --limit 10          # count within page (respects limit)
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

## Export

Dump entries as JSONL (one JSON object per line) for backup and migration:

```bash
# Export all entries
agent-store export > backup.jsonl

# Export a single entry by ID
agent-store export --id <uuid>

# Export filtered entries
agent-store export --label important > important.jsonl
agent-store export --type note --label active > notes.jsonl

# Exclude entries with a label
agent-store export --not-label archived > active.jsonl

# Export entries matching a data substring
agent-store export --data "error" > errors.jsonl

# Export entries from a date range
agent-store export --after "2024-06-01" --before "2024-07-01" > june.jsonl

# Count exported entries
agent-store export | wc -l

# Pipe to jq for processing
agent-store export | jq -r '.id'
```

Each line is a complete JSON object with the same fields as `query --json`:
`id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`.

## Import

Import entries from JSONL on stdin. This is the complement of `export` —
together they enable backup/restore, migration, and cross-store data transfer.

```bash
# Round-trip: export then re-import
agent-store export --label important | agent-store import

# Import from a backup file
cat backup.jsonl | agent-store import

# Import with error tolerance (errors are reported but don't abort)
cat mixed-data.jsonl | agent-store import

# Dry run: validate JSONL without inserting anything
cat data.jsonl | agent-store import --dry-run
```

Each input line must be a JSON object. The `data` field is required; `entity_type`,
`labels`, and `attributes` are optional (default to null, [], and {} respectively).
The `id` and `created_at` fields from the input are ignored — fresh values are
always generated to prevent ID conflicts and preserve append-only semantics.

Output: `Imported N entries (M errors)` on stderr.
With `--dry-run`: `Dry run: N entries would be imported (M errors)` on stderr. Nothing is inserted.

## Purge

Delete all entries from the store. This is a destructive operation that requires
explicit confirmation:

```bash
# Preview what will happen (prints warning, exits 1)
agent-store purge

# Actually delete everything
agent-store purge --confirm
```

Useful for testing and resetting stores. Deletes attributes, labels, and entries
in FK-safe order.

## Shell completions

Generate tab-completion scripts for your shell:

```bash
agent-store completions bash > ~/.bash_completion.d/agent-store
agent-store completions zsh > ~/.zfunc/_agent-store
agent-store completions fish > ~/.config/fish/completions/agent-store.fish
```
