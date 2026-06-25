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

## ID prefix matching

All commands that accept an entry ID (pull, tag, untag, update, delete,
query --id, export --id) support prefix matching. Instead of the full UUID, pass just the
first few characters (e.g., the 7-char short ID shown in query output).

- **1 match** — resolved to the full ID automatically
- **0 matches** — `error: entry not found: <prefix>`
- **2+ matches** — `error: ambiguous ID prefix '<prefix>' matches N entries`

```bash
# Push and get the full ID
ID=$(echo "data" | agent-store push --id-only)
# e.g. 7bf8d3fb-6357-4e45-b4d7-c67f4ad23632

# Pull with a prefix instead of the full UUID
agent-store pull 7bf8d3f

# Works with tag, untag, delete too
agent-store tag 7bf8d3f reviewed
agent-store delete 7bf8d3f
```

## Commands

| Command | What it does |
|---------|-------------|
| `init` | Create `.agent-store/store.db`, install skills to `.agents/skills/`, set up project docs |
| `push` | Read stdin (or `--file`), store as entry. Flags: `--label`, `--type`, `--attr key=value`, `--timestamp`, `--ttl <duration>`, `-f`/`--file`, `-q`/`--quiet`, `--id-only`, `--strip`, `--json`, `--update <id>`, `--upsert`, `--link rel:id` (repeat, create links at push time) |
| `pull <id>` | Retrieve entry by ID, print data to stdout. Flags: `--json` (full entry as JSON object), `--raw` (omit trailing newline for binary-safe piping), `--with-links` (include `links_from`/`links_to` arrays in JSON) |
| `query` | List entries. Filter: `--label` (repeat), `--not-label` (repeat, exclude), `--type`, `--not-type` (repeat, exclude, NULL-safe), `--attr key=value` (repeat), `--not-attr key=value` (repeat, exclude), `--data <substring>`, `--search <query>` (FTS5 full-text search), `--after <datetime>`, `--before <datetime>`, `--linked-to <id>` (entries linking to this id), `--linked-from <id>` (entries this id links to), `--link-rel <rel>` (filter by relationship type), `--json`, `--count`, `--latest`, `--first`, `--last`, `--limit N`, `--offset N`, `-r`/`--reverse` |
| `schema` | Show entity types and label counts |
| `stats` | Show entry count and store size. Flags: `--json` |
| `skills` | List and read built-in usage guides |
| `export` | Export entries in multiple formats. Flags: `--format jsonl\|json\|csv` (default: jsonl). Filter: `--id`, `--label` (repeat), `--not-label` (repeat), `--type`, `--not-type` (repeat, exclude), `--attr key=value` (repeat), `--not-attr key=value` (repeat, exclude), `--data`, `--search <query>` (FTS5), `--after`, `--before` |
| `import` | Import entries from JSONL on stdin (complement of export). Generates fresh IDs, preserves timestamps. Flags: `--dry-run` |
| `delete [id]` | Delete entries by ID or by filters. Filters: `--label`, `--not-label`, `--type`, `--not-type`, `--attr`, `--not-attr`, `--data`, `--search` (FTS5), `--after`, `--before`. Single-ID delete needs no confirmation; filter-based delete requires `--confirm`. Flags: `--dry-run`, `--json` |
| `purge` | Delete ALL entries (destructive). Requires `--confirm` flag. |
| `labels` | List all unique labels in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `types` | List all unique entity types in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `attrs` | List all unique attribute keys in the store, sorted. Flags: `--json` (JSON array), `--count` (with counts) |
| `info` | Show store configuration and environment. Flags: `--json` |
| `link <from> <to> [rel]` | Create a directional typed edge between two entries. Idempotent. Flags: `--json` |
| `unlink <from> <to> [rel]` | Remove a link. If `rel` is omitted, removes ALL links from->to. Idempotent. Flags: `--json` |
| `tag <id> <label>...` | Add labels to an existing entry. Idempotent (duplicate labels are ignored). Flags: `--json` |
| `untag <id> <label>...` | Remove labels from an existing entry. Idempotent (missing labels are ignored). Flags: `--json` |
| `set-attr <id> <key> <value>` | Set or update an attribute on an existing entry. Idempotent (overwrites existing value). Flags: `--json` |
| `unset-attr <id> <key>` | Remove an attribute from an existing entry. Idempotent (missing key is a no-op). Flags: `--json` |
| `gc` | Collect expired entries (those past their TTL). Also cleans changelog entries older than 30 days (or `--ttl`). Flags: `--ttl <duration>`, `--dry-run`, `--json` |
| `log [id]` | Show audit trail of mutations (tag, untag, set-attr, unset-attr, delete, update, link, unlink). With `<id>`: changelog for that entry. Without: recent changes across all entries. Flags: `--since <ISO timestamp>`, `--limit N` (default 50), `--label` (filter by entry label), `--operation` (filter by op type, repeatable), `--full-id` (show full IDs), `--json` |
| `compact` | Optimize store by running SQLite VACUUM and PRAGMA optimize. Reports before/after sizes. Flags: `--json` |
| `history <label>` | Show chronological history of entries with a given label (oldest first). Flags: `--json`, `--limit N`, `--data <substring>` |
| `alias` | Named queries. Subcommands: `set <name> -- [query flags]` (save), `run <name> [--mode query\|export\|delete] [--confirm]` (execute), `list` (show all), `rm <name>` (delete) |
| `tally` | Count entries grouped by a dimension. `--by label\|type\|rel\|attr:<key>`. Supports all filter flags. Output: tab-separated `value\tcount` (descending by count). Flags: `--json` (array of `{value, count}`) |
| `update [id]` | Compound metadata mutations in one transaction. Mutation flags: `--tag` (add label, repeat), `--untag` (remove label, repeat), `--set key=value` (set attr, repeat), `--unset key` (remove attr, repeat). Single-ID mode: no `--confirm` needed. Bulk mode (filters): requires `--confirm`. Flags: `--dry-run`, `--json`. Supports all filter flags. |
| `tail` | Watch the store for new entries (like `tail -f`). Flags: `--interval <N>` (poll seconds, default 1), `--since <datetime>`, `--json`. Supports all filter flags: `--label`, `--not-label`, `--type`, `--not-type`, `--attr`, `--not-attr`, `--data`, `--search` |
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

Both `tag` and `untag` accept `--json` for structured output (e.g., `{"id":"...","labels_added":["urgent"]}`).

## Attribute mutation

Attributes can be set or removed after push using `set-attr` and `unset-attr`.
Both are idempotent — setting an existing key overwrites the value, and unsetting
a missing key is a no-op.

```bash
# Set an attribute on an existing entry
ID=$(echo "data" | agent-store push --id-only)
agent-store set-attr $ID priority high
agent-store set-attr $ID status pending

# Update an existing attribute (overwrites)
agent-store set-attr $ID status done

# Remove an attribute
agent-store unset-attr $ID priority

# Removing a non-existent attribute is a no-op (no error)
agent-store unset-attr $ID nonexistent

# Verify
agent-store pull $ID --json | jq .attributes
```

Both `set-attr` and `unset-attr` accept `--json` for structured output:
- `set-attr --json`: `{"id":"...","key":"priority","value":"high"}`
- `unset-attr --json`: `{"id":"...","key":"priority","removed":true}`

## Links

Entries can be connected with directional typed edges. Links form a graph
overlay on top of the flat entry store, enabling dependency tracking, parent-child
relationships, and other structured connections.

```bash
# Create entries and link them
PARENT=$(echo "parent task" | agent-store push --label task --id-only)
CHILD=$(echo "subtask" | agent-store push --label task --id-only)
agent-store link $PARENT $CHILD blocks

# Create links at push time (format: rel:id)
BLOCKER=$(echo "blocker" | agent-store push --link "blocks:$PARENT" --id-only)

# Query by link relationships
agent-store query --linked-from $PARENT       # entries PARENT links to
agent-store query --linked-to $CHILD          # entries linking to CHILD
agent-store query --linked-from $PARENT --link-rel blocks  # filter by rel

# Inspect links on an entry
agent-store pull $PARENT --json --with-links
# adds links_from: [{to, rel, created_at}] and links_to: [{from, rel, created_at}]

# Remove links
agent-store unlink $PARENT $CHILD blocks      # remove specific rel
agent-store unlink $PARENT $CHILD             # remove ALL rels between them

# Cascade: deleting an entry removes its link rows (not linked entries)
agent-store delete $PARENT
```

Key behaviors:
- Links are directional (from -> to) and typed (rel field, defaults to empty)
- `link` is idempotent (INSERT OR IGNORE on composite primary key)
- `unlink` is idempotent (no error if link doesn't exist)
- Deleting an entry removes all its link rows (both directions)
- Both `link` and `unlink` accept `--json` for structured output
- All ID arguments support prefix matching via `resolve_entry_id()`

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

## TTL and garbage collection

Set a time-to-live on entries so they expire automatically. Expired entries
are cleaned up by the `gc` command.

```bash
# Push with a TTL
echo "cache result" | agent-store push --type cache --ttl 24h
echo "temp note" | agent-store push --ttl 30m

# Preview what gc would collect
agent-store gc --dry-run

# Collect expired entries
agent-store gc

# Override: collect ALL entries older than a duration, regardless of _expires_at
agent-store gc --ttl 7d              # delete everything older than 7 days
agent-store gc --ttl 24h --dry-run   # preview what would be collected
agent-store gc --ttl 30m --json      # structured output
```

Supported duration units: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).
TTL is stored as a `_expires_at` attribute — entries without TTL never expire.

With `--ttl <duration>`, gc ignores `_expires_at` and instead collects all entries
whose `created_at` is older than the given duration. This is useful for bulk cleanup
of old entries regardless of whether they were pushed with a TTL.

Use `gc --json` for structured output: `{"collected":1,"ids":["..."]}` or `{"dry_run":true,"count":0}`.

## Compact

Optimize the store database by running SQLite VACUUM (reclaims unused space)
and PRAGMA optimize (updates query planner statistics). Reports before and
after sizes so you can see how much space was freed.

```bash
# Compact the store
agent-store compact
# 340.0 KB → 232.0 KB (freed 108.0 KB)

# JSON output for scripting
agent-store compact --json
# {"size_before":348160,"size_after":237568,"freed":110592}
```

Run compact after large deletes, purges, or gc runs to reclaim disk space.

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

# JSON output — get structured JSON instead of human-readable message
echo "data" | agent-store push --label tag --type note --json
# {"attributes":null,"id":"<uuid>","labels":["tag"],"type":"note"}

# Update an existing entry's data in-place (preserves created_at and existing labels)
ID=$(echo "v1" | agent-store push --id-only --strip)
echo "v2" | agent-store push --update $ID              # data is now "v2"
echo "v3" | agent-store push --update $ID --label new  # adds label, data is now "v3"
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

# Single-entry shortcuts (alternative to --latest/--reverse combos)
agent-store query --label config --first     # oldest matching entry
agent-store query --label config --last      # newest matching entry (same as --latest)

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

## Full-text search

Use `--search` for relevance-ranked full-text search powered by SQLite FTS5.
Unlike `--data` (substring match), `--search` tokenizes content and supports
rich query syntax. Results are ordered by relevance when `--search` is active.

```bash
# Basic term search
agent-store query --search "error"

# Phrase search (exact sequence of words)
agent-store query --search '"database connection"'

# OR — match either term
agent-store query --search "error OR warning"

# NOT — exclude entries containing a term
agent-store query --search "error NOT timeout"

# Prefix — match words starting with a prefix
agent-store query --search "config*"

# Combine with filters (AND logic with all other flags)
agent-store query --search "error" --label logs --type event
agent-store query --search "migration" --after "2024-06-01" --json

# Count search results
agent-store query --search "error" --count

# Export search results as JSONL
agent-store export --search "database"

# Delete matching entries
agent-store delete --search "deprecated" --confirm
```

`--search` is available on `query`, `export`, and `delete`. It combines with
all existing filters (`--label`, `--type`, `--attr`, `--data`, `--after`,
`--before`, and their exclusion variants). Stores created before FTS was added
are migrated automatically on first use.

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

Export entries for backup, migration, and integration. The `--format` flag
controls the output format (default: `jsonl`).

```bash
# Export all entries as JSONL (default)
agent-store export > backup.jsonl

# Export as a proper JSON array (pretty-printed)
agent-store export --format json > backup.json

# Export as CSV (headers: id,created_at,entity_type,labels,data)
agent-store export --format csv > backup.csv

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

### Output formats

| Format | Flag | Description |
|--------|------|-------------|
| JSONL | `--format jsonl` (default) | One JSON object per line. Streams well, works with `jq`, `wc -l`, and `import` |
| JSON | `--format json` | Proper JSON array, pretty-printed. Good for APIs and tools that expect valid JSON |
| CSV | `--format csv` | Headers: `id,created_at,entity_type,labels,data`. Labels are semicolon-separated. Data is truncated to 100 characters. Proper CSV escaping for fields containing commas or quotes |

Unknown format values produce an error and exit 1.

JSONL output: each line is a complete JSON object with the same fields as
`query --json`: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`.

All formats work with all filter flags and through `alias run --mode export`.

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

# Dry run — list what would be deleted without deleting
agent-store delete --label old-tag --dry-run
# Prints: short ID, created_at, type, labels for each matching entry

# Dry run with JSON output — full entry objects to stdout
agent-store delete --label old-tag --dry-run --json

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

Use `--dry-run` to list entries that would be deleted without actually deleting.
Without `--json`, it prints a human-readable summary to stderr (short ID, created_at,
type, labels per entry). With `--json`, it outputs a JSON array of full entry objects
to stdout. `--dry-run` conflicts with `--confirm` and does not require it. Works with
all filter args and single-ID mode. Read-only, always exits 0.

Use `--json` for structured output: `{"deleted":1,"ids":["..."]}` (confirmed) or `{"dry_run":true,"count":1}` (preview).

## Updating entries

For simple in-place replacement, use `push --update <id>`:

```bash
ID=$(echo "v1 config" | agent-store push --type config --label app --id-only)
echo "v2 config" | agent-store push --update $ID
```

This replaces the entry's data, preserves `created_at` and existing labels,
adds any new `--label` values, upserts `--attr` values, and updates `--type`
if given. Supports prefix ID matching. Use this when you don't need version
history.

For atomic find-or-create, use `push --upsert`:

```bash
echo "config data" | agent-store push --upsert --label config --attr env=prod
```

This queries for entries matching ALL provided filters (`--label`, `--type`,
`--attr`). If 0 matches: creates a new entry. If 1 match: updates that entry's
data, merges labels, and upserts attrs. If 2+ matches: errors with the match
count (exit 1). The entire operation runs in a single SQLite transaction.
Use `--json` to see `{"action": "created"}` or `{"action": "updated"}` in the
output. Cannot be combined with `--update`.

For versioned updates where you want to preserve the original, use the
supersede convention: push a new entry with `--attr supersedes=<old-id>`.
Queries return newest-first, so `--latest` always gives the current version.
After confirming the replacement, clean up with `agent-store delete <old-id>`.
See `agent-store skills get agent-store-patterns` for full examples including
version chain traversal and iterative draft workflows.

## Batch update (compound mutations)

Apply multiple metadata mutations (tag, untag, set attribute, unset attribute)
atomically in a single transaction. Use `update` when you need to change several
things at once without multiple round-trips.

```bash
# Single entry: tag + untag + set attr + unset attr in one operation
agent-store update $ID --tag done --untag pending --set status=closed --unset priority

# Single entry JSON output
agent-store update $ID --tag archived --json
# {"id":"...","tags_added":1,"tags_removed":0,"attrs_set":0,"attrs_unset":0}

# Bulk: update all entries matching filters (requires --confirm)
agent-store update --label task --attr status=stale --set status=archived --tag archived --confirm

# Preview bulk update (prints count, exits 1)
agent-store update --label task --tag archived
# Would update 5 entries. Run with --confirm to proceed.

# Dry run: list entries that would be affected
agent-store update --label task --tag archived --dry-run

# Dry run with JSON output (full entry objects to stdout)
agent-store update --label task --tag archived --dry-run --json

# Bulk JSON output (with --confirm)
agent-store update --label old --untag old --tag migrated --confirm --json
# {"updated":3,"ids":[...],"tags_added":3,"tags_removed":3,"attrs_set":0,"attrs_unset":0}
```

**Mutation flags** (all repeatable):
- `--tag <label>` — add a label (INSERT OR IGNORE, idempotent)
- `--untag <label>` — remove a label (DELETE, idempotent)
- `--set <key>=<value>` — set an attribute (INSERT OR REPLACE, overwrites)
- `--unset <key>` — remove an attribute (DELETE, idempotent)

At least one mutation flag is required (error if none provided).

**Single-ID mode** (`update <id> ...`): resolves ID via prefix matching, applies
mutations, no `--confirm` needed (explicit ID = intentional).

**Bulk mode** (`update --label ... --tag ...`): uses the same filter flags as
`query`/`export`/`delete`. Without `--confirm`, prints count and exits 1. With
`--dry-run`, lists affected entries without modifying them. With `--confirm`,
applies mutations to all matching entries atomically.

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

## Named queries (aliases)

Save frequently used query flag combinations as named aliases and replay
them without remembering the full flag set. Aliases are stored in the
SQLite database alongside entries.

```bash
# Save a query as an alias
agent-store alias set urgent-tasks -- --label urgent --type task --attr status=pending

# Run the saved query (equivalent to: agent-store query --label urgent --type task --attr status=pending)
agent-store alias run urgent-tasks

# Run as export (JSONL output instead of query format)
agent-store alias run urgent-tasks --mode export

# Run as delete (preview — prints count, exits 1)
agent-store alias run urgent-tasks --mode delete

# Run as delete (execute — requires --confirm)
agent-store alias run urgent-tasks --mode delete --confirm

# List all saved aliases (name\targs per line)
agent-store alias list

# Overwrite an existing alias (upsert — INSERT OR REPLACE)
agent-store alias set urgent-tasks -- --label urgent --type task

# Remove an alias (exits 1 if not found)
agent-store alias rm urgent-tasks
```

Aliases store the raw query flags as a JSON array. The `--` separator
before the flags is required by the CLI parser.

`alias run` supports `--mode` to change the execution mode:
- `--mode query` (default) — run as a `query` command
- `--mode export` — run as an `export` command (JSONL output)
- `--mode delete` — run as a `delete` command (requires `--confirm` to execute)

## Tally (aggregation)

Count entries grouped by a metadata dimension. Useful for dashboards, status
summaries, and understanding what's in the store without reading every entry.

```bash
# Count entries per label (descending by count, tab-separated)
agent-store tally --by label
# todo	5
# done	3
# blocked	1

# Count entries per entity type
agent-store tally --by type
# note	10
# task	7
# (none)	2

# Count entries per attribute value
agent-store tally --by attr:status
# open	4
# done	3

# JSON output: array of {value, count} objects
agent-store tally --by label --json
# [{"value":"todo","count":5},{"value":"done","count":3}]

# Combine with filters (same flags as query)
agent-store tally --by type --label urgent        # only urgent entries
agent-store tally --by label --after "2024-06-01" # recent entries only
agent-store tally --by attr:priority --type task   # task priorities
```

**Dimensions:**
- `--by label` — groups by label. Entries with multiple labels are counted once per label.
- `--by type` — groups by entity type. Entries with no type appear as `(none)`.
- `--by attr:<key>` — groups by the value of attribute `<key>`. Entries without that attribute are excluded.

Output is tab-separated (`value\tcount`) for stable agent parsing. Use `--json`
for structured output. Results are sorted descending by count, then alphabetically
by value for ties. All filter flags (`--label`, `--not-label`, `--type`, `--not-type`,
`--attr`, `--not-attr`, `--data`, `--search`, `--after`, `--before`) are supported.

## Tail (live watch)

Watch the store for new entries in real time, like `tail -f`. Polls at a
configurable interval and prints each new entry as it arrives. Supports all
filter flags so you can watch a specific slice of the store.

```bash
# Watch all new entries (Ctrl+C to stop)
agent-store tail

# Watch only entries with a specific label
agent-store tail --label deploy

# JSON output (one JSON object per line, same format as query --json entries)
agent-store tail --json

# Custom poll interval (seconds, default: 1)
agent-store tail --interval 5

# Start from a past timestamp (shows pre-existing entries after that time first)
agent-store tail --since "2024-06-01 09:00:00"

# Combine filters
agent-store tail --label error --type event --json --interval 2

# Pipe to jq for live structured processing
agent-store tail --json | jq '.data'
```

Default output is raw entry data (one entry per poll cycle). Use `--json`
for structured output with id, data, entity_type, created_at, labels, and
attributes. Clean exit via Ctrl+C (SIGINT) or broken pipe from downstream.

## Shell completions

Generate tab-completion scripts for your shell:

```bash
agent-store completions bash > ~/.bash_completion.d/agent-store
agent-store completions zsh > ~/.zfunc/_agent-store
agent-store completions fish > ~/.config/fish/completions/agent-store.fish
```
