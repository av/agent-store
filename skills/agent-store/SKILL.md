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
| **created_at** | Timestamp                                | automatic / `--timestamp` |

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

# Exclude entries with a type (NULL-safe: entries with no type are kept)
agent-store query --not-type log                      # everything except logs
agent-store query --not-type log --not-type debug     # exclude multiple types

# Exclude entries with a specific attribute
agent-store query --not-attr status=archived          # exclude archived
agent-store query --label todo --not-attr status=done # open todos by attr

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
| `push` | Read stdin (or `--file`), store as entry. Flags: `--label`, `--type`, `--attr key=value`, `--timestamp`, `-f`/`--file`, `-q`/`--quiet`, `--id-only`, `--strip` |
| `pull <id>` | Retrieve entry by ID, print data to stdout. Flags: `--json` (full entry as JSON object), `--raw` (omit trailing newline for binary-safe piping) |
| `query` | List entries. Filter: `--label` (repeat), `--not-label` (repeat, exclude), `--type`, `--not-type` (repeat, exclude, NULL-safe), `--attr key=value` (repeat), `--not-attr key=value` (repeat, exclude), `--data <substring>`, `--search <query>` (FTS5 full-text search), `--after <datetime>`, `--before <datetime>`, `--json`, `--count`, `--latest`, `--limit N`, `--offset N`, `-r`/`--reverse` |
| `schema` | Show entity types and label counts |
| `stats` | Show entry count and store size. Flags: `--json` |
| `skills` | List and read built-in usage guides |
| `export` | Export entries as JSONL (one JSON object per line). Filter: `--id`, `--label` (repeat), `--not-label` (repeat), `--type`, `--not-type` (repeat, exclude), `--attr key=value` (repeat), `--not-attr key=value` (repeat, exclude), `--data`, `--search <query>` (FTS5), `--after`, `--before` |
| `import` | Import entries from JSONL on stdin (complement of export). Generates fresh IDs, preserves timestamps. Flags: `--dry-run` |
| `delete [id]` | Delete entries by ID or by filters. Filters: `--label`, `--not-label`, `--type`, `--not-type`, `--attr`, `--not-attr`, `--data`, `--search` (FTS5), `--after`, `--before`. Single-ID delete needs no confirmation; filter-based delete requires `--confirm` |
| `purge` | Delete ALL entries (destructive). Requires `--confirm` flag. |
| `labels` | List all unique labels in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `types` | List all unique entity types in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `attrs` | List all unique attribute keys in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `info` | Show store configuration and environment. Flags: `--json` |
| `tag <id> <label>...` | Add labels to an existing entry. Idempotent (duplicate labels are ignored). |
| `untag <id> <label>...` | Remove labels from an existing entry. Idempotent (missing labels are ignored). |
| `history <label>` | Show chronological history of entries with a given label (oldest first). Flags: `--json`, `--limit N`, `--data <substring>` |
| `completions <shell>` | Generate shell completions (bash, zsh, fish, elvish, powershell) |

## Tagging

Labels can be added or removed after push using `tag` and `untag`. Both are
idempotent — tagging with an already-present label or untagging a missing label
is a no-op.

```bash
# Add labels to an existing entry
ID=$(echo "data" | agent-store push --id-only)
agent-store tag $ID urgent
agent-store tag $ID review backend    # multiple labels at once

# Remove labels
agent-store untag $ID urgent
agent-store untag $ID review backend  # multiple labels at once

# Verify
agent-store query --label backend --json | jq '.[].data'
```

## History

Since agent-store is append-only, a common pattern is pushing multiple entries with the same label to track changes over time. The `history` subcommand makes this explicit.

```bash
# Show all entries labeled "config" in chronological order
agent-store history config

# Output format:
# [2024-01-15 10:30:00] abc1234
#   First value
#
# [2024-01-15 11:00:00] def4567
#   Updated value

# JSON output (same format as query --json)
agent-store history config --json

# Last 5 entries only
agent-store history config --limit 5

# Search within history
agent-store history config --data "database"
```

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

# Read data from a file instead of stdin
agent-store push --label config --file config.json
agent-store push --type artifact -f output.txt

# Override the created_at timestamp (for migrations, imports)
echo "historical data" | agent-store push --type note --timestamp "2020-01-15 10:30:00"

# Strip trailing whitespace/newlines from data before storing
echo "data" | agent-store push --label x --strip    # stores "data", not "data\n"
agent-store push --file output.txt --strip           # strip works with --file too
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

# Exclude entries by type (repeatable, NULL-safe)
agent-store query --not-type log                        # everything except logs
agent-store query --not-type log --not-type debug       # exclude multiple types

# Exclude entries by attribute (repeatable, AND semantics)
agent-store query --not-attr status=archived            # exclude archived
agent-store query --not-attr status=archived --not-attr priority=low  # exclude both

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

# Exclude entries with a type (NULL-safe)
agent-store export --not-type debug > no-debug.jsonl

# Exclude entries with an attribute
agent-store export --not-attr status=archived > active-by-attr.jsonl

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
Fresh IDs are always generated to prevent conflicts. The `created_at` field from
the input is preserved when present (enabling true backup/restore); when missing,
the current time is used.

Output: `Imported N entries (M errors)` on stderr.
With `--dry-run`: `Dry run: N entries would be imported (M errors)` on stderr. Nothing is inserted.

## Delete

Delete entries selectively — by ID or by filter. For bulk deletion of all
entries, see `purge`.

```bash
# Delete a single entry by ID (no --confirm needed)
agent-store delete $ID

# Preview what a filter-based delete would do (prints count, exits 1)
agent-store delete --label old-tag

# Delete matching entries (requires --confirm)
agent-store delete --label old-tag --confirm

# Delete with combined filters
agent-store delete --type log --before "2024-01-01" --confirm

# All query filters are supported
agent-store delete --label todo --not-label important --attr status=done --confirm
```

Single-ID delete validates that the entry exists (exits 1 if not found) and
removes the entry plus its labels and attributes. No `--confirm` needed.

Filter-based delete uses the same filter arguments as `query` and `export`.
Without `--confirm`, it prints how many entries would be deleted and exits 1.
With `--confirm`, it deletes and prints `Deleted N entries` on stderr.

Calling `delete` with no ID and no filters prints an error (prevents
accidental delete-all — use `purge` for that).

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

## Info

Show store configuration, paths, and environment:

```bash
# Human-readable output
agent-store info

# JSON output for scripting
agent-store info --json | jq .version
agent-store info --json | jq .db_size_bytes
```

Fields: `store_path`, `db_path`, `db_size_bytes`, `agent_store_path_env`,
`project_root`, `version`.

## Discovery

List what labels, entity types, and attribute keys exist in the store — useful
for agents exploring a store without querying all entries:

```bash
# List all unique labels (sorted, one per line)
agent-store labels

# JSON array of labels
agent-store labels --json

# Labels with entry counts
agent-store labels --count            # alpha (3)\n beta (1)
agent-store labels --count --json     # {"alpha":3,"beta":1}

# List all unique entity types (sorted, one per line)
agent-store types

# JSON array of types
agent-store types --json

# Types with entry counts
agent-store types --count
agent-store types --count --json

# List all unique attribute keys (sorted, one per line)
agent-store attrs

# JSON array of attribute keys
agent-store attrs --json

# Attribute keys with entry counts
agent-store attrs --count
agent-store attrs --count --json
```

## Shell completions

Generate tab-completion scripts for your shell:

```bash
agent-store completions bash > ~/.bash_completion.d/agent-store
agent-store completions zsh > ~/.zfunc/_agent-store
agent-store completions fish > ~/.config/fish/completions/agent-store.fish
```
