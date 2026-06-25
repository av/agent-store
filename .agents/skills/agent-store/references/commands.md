# Command Reference

## agent-store init

Initialize a new store and set up agent tooling.

```
agent-store init
```

- Creates `.agent-store/` directory and `store.db` SQLite database
- Installs skills to `.agents/skills/agent-store*/`
- Creates Claude Code symlinks in `.claude/skills/` (if Claude is detected)
- Adds usage instructions to `AGENTS.md` or `CLAUDE.md`
- Idempotent — safe to run multiple times; skips steps already done
- Respects `AGENT_STORE_PATH` env var for custom store location

## agent-store push

Store data from stdin or a file.

```
echo "data" | agent-store push [OPTIONS]
agent-store push --file data.txt [OPTIONS]
```

Options:
- `--label <LABEL>` — Tag the entry (repeatable for multiple labels)
- `--type <TYPE>` — Set entity type classification
- `--attr <KEY=VALUE>` — Set attribute key-value pair (repeatable, AND logic on query)
- `-f`, `--file <PATH>` — Read data from a file instead of stdin
- `-q`, `--quiet` — Suppress all output (for scripting when no feedback is needed)
- `--id-only` — Output only the raw UUID (no "stored entry" prefix). Conflicts with `--quiet`
- `--timestamp <DATETIME>` — Override created_at timestamp (ISO 8601: `"2024-01-15 10:30:00"` or `"2024-01-15"`). Default: current time
- `--ttl <DURATION>` — Set a time-to-live. Duration format: `<number><unit>` where unit is `s` (seconds), `m` (minutes), `h` (hours), or `d` (days). Examples: `30m`, `24h`, `7d`, `3600s`. Stores the computed expiry as a `_expires_at` attribute. Expired entries are collected by `gc`
- `--strip` — Strip trailing whitespace (including newlines) from data before storing. Useful with `echo` which adds a trailing newline
- `--json` — Output the stored/updated entry as structured JSON to stdout. Fields: `id`, `labels`, `type`, `attributes` (only non-null fields included). Useful for scripting when you need metadata beyond just the ID
- `--update <ID>` — Update an existing entry's data in-place (by ID or unambiguous prefix). Replaces the entry's data with new stdin/file content. Preserves `created_at` and existing labels. Adds new labels via `--label` (idempotent). Upserts attributes via `--attr`. Updates entity type if `--type` is given
- `--upsert` — Atomic find-or-create. Requires at least one filter (`--label`, `--type`, or `--attr`). If 0 entries match, creates new. If 1 matches, updates in-place. If 2+ match, errors. Conflicts with `--update`. JSON output includes `"action": "created"` or `"action": "updated"`
- `--link <REL:ID>` — Create a directional link from this entry to target (repeatable). Format: `rel:id` where `rel` is the relationship type and `id` is the target entry ID (prefix matching supported). Target entry must exist. Links are created atomically with the push

Data is read from stdin until EOF (or from `--file` if provided). Empty
input is an error. When `--file` is set, it takes precedence over stdin.
File not found prints a clear error and exits 1. Labels, type, and
attribute keys cannot be empty strings.

Scripting example:
```bash
ID=$(echo "data" | agent-store push --label tag --id-only)
agent-store push --label config --file config.json
echo "data" | agent-store push --label x --strip    # stores "data", not "data\n"

# JSON output for structured metadata
echo "data" | agent-store push --label tag --type note --json
# {"id":"<uuid>","labels":["tag"],"type":"note"}

# Update an existing entry in-place
ID=$(echo "v1" | agent-store push --id-only --strip)
echo "v2" | agent-store push --update $ID                # data replaced, labels preserved
echo "v3" | agent-store push --update $ID --label extra  # adds label, updates data
```

## agent-store pull \<ID\>

Retrieve an entry by ID (or unambiguous ID prefix).

```
agent-store pull <ID> [--json] [--raw] [--with-links]
```

Prints the entry's data to stdout (raw payload, no metadata). The ID
argument supports prefix matching — pass just the first few characters
instead of the full UUID. Exit code 1 if the entry is not found or the
prefix is ambiguous.

Options:
- `--json` — Output the full entry as a JSON object (same format as `query --json` entries: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`)
- `--raw` — Omit trailing newline for binary-safe piping. Useful for checksums: `agent-store pull <id> --raw | sha256sum`
- `--with-links` — Include outgoing and incoming links in JSON output. Adds `links_from` (array of `{to, rel, created_at}`) and `links_to` (array of `{from, rel, created_at}`) fields. Requires `--json`

## agent-store query

List and filter entries.

```
agent-store query [OPTIONS]
```

Options:
- `--label <LABEL>` — Filter by label (can be repeated, AND logic — all must match)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated — entries with ANY specified label are excluded)
- `--type <TYPE>` — Filter by entity type (exact match)
- `--not-type <TYPE>` — Exclude entries with this entity type (can be repeated, NULL-safe — entries with no type are kept)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic — all must match)
- `--not-attr <KEY=VALUE>` — Exclude entries with this attribute key=value pair (can be repeated — entries with ANY specified pair are excluded)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--search <QUERY>` — Full-text search query (FTS5 syntax: terms, "phrases", OR, NOT, prefix*). Results ordered by relevance. Overrides default chronological sort unless `--reverse` is specified
- `--after <DATETIME>` — Only entries created after this timestamp (ISO 8601: `"2024-01-15"` or `"2024-01-15 10:30:00"`)
- `--before <DATETIME>` — Only entries created before this timestamp (ISO 8601: `"2024-01-15"` or `"2024-01-15 10:30:00"`)
- `--linked-to <ID>` — Find entries that link TO this entry (entries where to_id matches). Supports prefix matching
- `--linked-from <ID>` — Find entries that this entry links TO (entries where from_id matches). Supports prefix matching
- `--link-rel <REL>` — Filter linked results by relationship type (requires `--linked-to` or `--linked-from`)
- `--with-links` — Include `links_from` and `links_to` arrays on each entry in JSON output (requires `--json`). Same format as `pull --with-links`
- `--json` — Output as JSON array of full entry objects
- `--count` — Output only the number of matching entries (just a number, for scripting)
- `--latest` — Return only the single most recent matching entry (conflicts with `--limit`, `--first`, `--last`)
- `--first` — Return only the single oldest matching entry (sorts ASC, LIMIT 1). Conflicts with `--limit`, `--latest`, `--last`
- `--last` — Return only the single newest matching entry (sorts DESC, LIMIT 1). Conflicts with `--limit`, `--latest`, `--first`
- `--limit <N>` — Return at most N entries
- `--offset <N>` — Skip first N entries (requires `--limit`)
- `-r`, `--reverse` — Reverse sort order to oldest-first (default is newest-first)

Without any filter flags, returns all entries.

`--latest` is the most common agent pattern: "give me the latest entry with this label."
It conflicts with `--limit` (use one or the other). Combine with `--reverse` to get the
oldest single entry instead.

`--first` and `--last` are shorthand alternatives: `--first` returns the single oldest
matching entry and `--last` returns the single newest. They conflict with `--limit`,
`--latest`, and each other.

`--count` respects `--limit`/`--offset` — it counts entries within the paginated window.
When combined with `--latest`, `--count` returns 0 or 1.

`--after` and `--before` accept ISO 8601 timestamps. Use date-only (`"2024-01-15"`) or
date-time (`"2024-01-15 10:30:00"`). Combine both for a date range.

**Default output:** raw entry data (payloads only) concatenated with no
separator. Entries appear on separate lines only if their data contains
trailing newlines. Use `--json` for structured output.

**JSON output:** array of objects, each with fields: `id`, `data`,
`entity_type`, `created_at`, `labels` (array), `attributes` (object).

## agent-store schema

Show entity types and label counts.

```
agent-store schema
```

Displays two sections:
- **Entity Types** — each type with its entry count
- **Labels** — each label with its entry count

Useful for understanding the shape of the store before querying.

## agent-store stats

Show store statistics.

```
agent-store stats
agent-store stats --json
```

Options:
- `--json` — Output stats as a JSON object with fields: `entries`, `entity_types`, `labels`, `entity_type_count`, `label_count`, `entries_by_type`, `entries_by_label`

Reports (human-readable mode):
- Total entry count
- Store file size on disk
- Number of distinct entity types
- Number of distinct labels

## agent-store skills

Manage built-in usage guides for AI agents.

```
agent-store skills list                         # List available skills with descriptions
agent-store skills get <name>                   # Print a skill guide
agent-store skills get <name> --full            # Include reference appendices
agent-store skills path <name>                  # Print skill data directory path
```

Available skills:
- `agent-store` — Core reference (this document)
- `agent-store-patterns` — Workflow recipes for common agent tasks
- `agent-store-pipelines` — Shell composition and batch operations

## agent-store export

Export entries in multiple formats for backup, migration, and integration.

```
agent-store export [OPTIONS]
```

**Options:**

| Flag | Description |
|------|-------------|
| `--format <FORMAT>` | Output format: `jsonl` (default), `json`, or `csv`. See format details below. Unknown values produce an error and exit 1 |
| `--id <ID>` | Filter by entry ID (export a single entry) |
| `--label <LABEL>` | Filter by label (can be repeated, AND logic) |
| `--not-label <LABEL>` | Exclude entries with this label (can be repeated) |
| `--type <TYPE>` | Filter by entity type |
| `--not-type <TYPE>` | Exclude entries with this entity type (can be repeated, NULL-safe) |
| `--attr <KEY=VALUE>` | Filter by attribute (can be repeated, AND logic) |
| `--not-attr <KEY=VALUE>` | Exclude entries with this attribute (can be repeated) |
| `--data <SUBSTRING>` | Filter by substring match in entry data |
| `--search <QUERY>` | Full-text search query (FTS5 syntax: terms, "phrases", OR, NOT, prefix*). Results ordered by relevance. Overrides default chronological sort unless `--reverse` is specified |
| `--after <DATETIME>` | Only entries created after this timestamp (ISO 8601) |
| `--before <DATETIME>` | Only entries created before this timestamp (ISO 8601) |

All filters match `query` — see `query` docs for filter semantics.

**Output formats:**

- **`jsonl`** (default) — One JSON object per line. Each line is a self-contained
  JSON object with fields: `id`, `data`, `entity_type`, `created_at`, `labels`,
  `attributes`. Entries with outgoing links also include a `links_from` array
  of `{to, rel}` objects. Streams well, works with `jq` and `wc -l`, and is the input
  format for `import`.

- **`json`** — Proper JSON array, pretty-printed with indentation. Contains the
  same entry objects as JSONL but wrapped in `[...]` with commas between entries.
  Use when consumers expect valid JSON (APIs, config files, non-streaming tools).

- **`csv`** — CSV with headers: `id,created_at,entity_type,labels,data`. Labels
  are semicolon-separated (e.g., `urgent;review`). Data is truncated to 100
  characters. Fields containing commas, quotes, or newlines are properly escaped.
  Use for spreadsheets, quick inspection, or tools that don't handle JSON.

```bash
# Default JSONL output
agent-store export > backup.jsonl
agent-store export --label important > important.jsonl

# JSON array output
agent-store export --format json > backup.json
agent-store export --format json --label urgent > urgent.json

# CSV output
agent-store export --format csv > entries.csv
agent-store export --format csv --type task > tasks.csv

# All formats work with all filters
agent-store export --format csv --not-label archived --after "2024-06-01" > recent.csv
agent-store export --data "error" --after "2024-06-01" > recent-errors.jsonl
agent-store export | jq -r '.id'
```

## agent-store import

Import entries from JSONL on stdin. Complement of `export`.

```
agent-store import [--dry-run]
```

Options:
- `--dry-run` — Parse and validate without inserting anything. Prints
  `Dry run: N entries would be imported (M errors)` on stderr. Does not
  require an initialized store.

Reads JSONL from stdin (one JSON object per line). For each valid line,
inserts a new entry with a fresh UUID. The `created_at` field from the input
is preserved when present (for true backup/restore); when missing, the current
time is used. The `id` field is ignored to prevent conflicts.

Required fields: `data` (string).
Optional fields: `entity_type` (string), `labels` (array of strings),
`attributes` (object of string key-value pairs).

On parse errors or missing `data`, prints the error with line number to
stderr and continues processing. Empty lines are skipped.

Output: `Imported N entries (M errors)` on stderr.

```bash
# Round-trip backup/restore
agent-store export > backup.jsonl
cat backup.jsonl | agent-store import

# Validate JSONL before committing
cat data.jsonl | agent-store import --dry-run

# Import filtered entries from another store
AGENT_STORE_PATH=./other agent-store export --label shared | agent-store import
```

## agent-store delete

Delete entries by ID or by filters.

```
agent-store delete [ID] [OPTIONS]
```

Arguments:
- `[ID]` — Entry ID (or unambiguous prefix) to delete. When provided, deletes
  a single entry without requiring `--confirm`.

Options:
- `--confirm` — Required for filter-based deletes. Without it, prints how many
  entries would be deleted and exits 1.
- `--dry-run` — List entries that would be deleted without actually deleting. Prints a human-readable summary to stderr (short ID, created_at, type, labels per entry). With `--json`, outputs a JSON array of full entry objects to stdout. Conflicts with `--confirm`. Works with all filter args and single-ID mode. Read-only, always exits 0
- `--json` — Output as JSON object: `{"deleted":1,"ids":["..."]}` (confirmed) or `{"dry_run":true,"count":1}` (without `--confirm`)
- `--label <LABEL>` — Filter by label (can be repeated, AND logic)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated)
- `--type <TYPE>` — Filter by entity type
- `--not-type <TYPE>` — Exclude entries with this entity type (can be repeated, NULL-safe)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic)
- `--not-attr <KEY=VALUE>` — Exclude entries with this attribute (can be repeated)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--search <QUERY>` — Full-text search query (FTS5 syntax: terms, "phrases", OR, NOT, prefix*). Results ordered by relevance. Overrides default chronological sort unless `--reverse` is specified
- `--after <DATETIME>` — Only entries created after this timestamp (ISO 8601)
- `--before <DATETIME>` — Only entries created before this timestamp (ISO 8601)

All filter options match `query`/`export` — see those docs for semantics.

**Delete by ID:**
- Validates entry existence (exits 1 if not found)
- Removes the entry plus its labels and attributes
- No `--confirm` required
- Output: `Deleted <short-id>` on stderr

**Delete by filters:**
- Without `--confirm`: prints `Would delete N entries. Run with --confirm to proceed.` on stderr, exits 1
- With `--confirm`: deletes matching entries, prints `Deleted N entries` on stderr
- No ID and no filters: prints `error: specify an ID or at least one filter`, exits 1

Deletes in FK-safe order: attributes, labels, entries.

```bash
# Delete one entry by ID
agent-store delete $ID

# Dry run — see exactly what would be deleted
agent-store delete --label stale --dry-run
# Lists each matching entry: short ID, created_at, type, labels

# Dry run with JSON — full entry objects
agent-store delete --label stale --dry-run --json

# Dry run on a single entry
agent-store delete $ID --dry-run

# Preview filter-based delete
agent-store delete --label stale
# Would delete 5 entries. Run with --confirm to proceed.

# Execute filter-based delete
agent-store delete --label stale --confirm
# Deleted 5 entries

# Combined filters
agent-store delete --type log --before "2024-01-01" --confirm
agent-store delete --label todo --attr status=done --confirm
```

## agent-store purge

Delete ALL entries from the store. Destructive — requires explicit confirmation.

```
agent-store purge [--confirm]
```

Options:
- `--confirm` — Actually perform the deletion. Without this flag, prints a
  warning and exits with code 1.

Deletes from `attributes`, `labels`, and `entries` tables in FK-safe order.
Prints `Purged N entries` on success.

Useful for testing and resetting stores.

## agent-store info

Show store configuration, paths, and environment details.

```
agent-store info [--json]
```

Options:
- `--json` — Output as a JSON object

Human-readable output shows:
- Store path (`.agent-store/` directory)
- Database file path
- Database file size
- `AGENT_STORE_PATH` env var status
- Project root directory
- CLI version

JSON output fields: `store_path`, `db_path`, `db_size_bytes` (null if DB
doesn't exist), `agent_store_path_env` (null if not set), `project_root`
(null if not in a git repo), `version`.

```bash
agent-store info
agent-store info --json | jq .version
```

## agent-store labels

List all unique labels in the store, one per line, sorted alphabetically.
Useful for discovery — agents can see what labels exist without querying
all entries.

```
agent-store labels [--json] [--count]
```

Options:
- `--json` — Output as a JSON array of label strings (or JSON object of label-to-count when combined with `--count`)
- `--count` — Show entry count next to each label

```bash
# Plain list (one per line, sorted)
agent-store labels

# JSON array
agent-store labels --json              # ["done","todo","urgent"]

# With counts
agent-store labels --count             # done (1)\n todo (5)\n urgent (2)
agent-store labels --count --json      # {"done":1,"todo":5,"urgent":2}
```

## agent-store types

List all unique entity types in the store, one per line, sorted alphabetically.
Same pattern as `labels` but for entity types.

```
agent-store types [--json] [--count]
```

Options:
- `--json` — Output as a JSON array of type strings (or JSON object of type-to-count when combined with `--count`)
- `--count` — Show entry count next to each type

```bash
# Plain list (one per line, sorted)
agent-store types

# JSON array
agent-store types --json               # ["config","note","task"]

# With counts
agent-store types --count              # config (1)\n note (3)\n task (2)
agent-store types --count --json       # {"config":1,"note":3,"task":2}
```

## agent-store attrs

List all unique attribute keys in the store, one per line, sorted alphabetically.
Same pattern as `labels` and `types` but for attribute keys.

```
agent-store attrs [--json] [--count]
```

Options:
- `--json` — Output as a JSON array of key strings (or JSON object of key-to-count when combined with `--count`)
- `--count` — Show entry count next to each attribute key

```bash
# Plain list (one per line, sorted)
agent-store attrs

# JSON array
agent-store attrs --json               # ["color","size","weight"]

# With counts
agent-store attrs --count              # color (3)\n size (1)\n weight (2)
agent-store attrs --count --json       # {"color":3,"size":1,"weight":2}
```

## agent-store tag

Add labels to an existing entry.

```
agent-store tag <ID> <LABEL>... [--json]
```

Arguments:
- `<ID>` — Entry ID (or unambiguous prefix) to tag.
- `<LABEL>...` — One or more labels to add. At least one required.

Options:
- `--json` — Output as JSON object: `{"id":"...","labels_added":["label1"]}`

Idempotent: adding a label that already exists on the entry is a no-op (uses
`INSERT OR IGNORE` on the `(entry_id, label)` primary key). Empty labels are
rejected with an error. Unknown entry IDs print "not found" and exit 1.

Output: `Tagged <short-id> with: <labels>` on stderr (or JSON to stdout with `--json`).

```bash
# Tag a single label
agent-store tag $ID urgent

# Tag multiple labels at once
agent-store tag $ID urgent review backend

# Safe to repeat (idempotent)
agent-store tag $ID urgent urgent    # no error, no duplicate
```

## agent-store untag

Remove labels from an existing entry.

```
agent-store untag <ID> <LABEL>... [--json]
```

Arguments:
- `<ID>` — Entry ID (or unambiguous prefix) to untag.
- `<LABEL>...` — One or more labels to remove. At least one required.

Options:
- `--json` — Output as JSON object: `{"id":"...","labels_removed":["label1"]}`

Idempotent: removing a label that doesn't exist on the entry is a no-op
(the `DELETE` simply affects zero rows). Unknown entry IDs print "not found"
and exit 1.

Output: `Untagged <short-id>: <labels>` on stderr (or JSON to stdout with `--json`).

```bash
# Remove a label
agent-store untag $ID urgent

# Remove multiple labels at once
agent-store untag $ID urgent review

# Safe to repeat (idempotent)
agent-store untag $ID nonexistent    # no error
```

## agent-store link

Create a directional typed edge between two entries.

```
agent-store link <FROM> <TO> [REL] [--json]
```

Arguments:
- `<FROM>` — Source entry ID or prefix
- `<TO>` — Target entry ID or prefix
- `[REL]` — Relationship type (optional, defaults to empty string)

Idempotent — creating the same link twice is a no-op (INSERT OR IGNORE on the composite primary key `from_id, to_id, rel`). Both entry IDs must exist. Supports prefix matching.

```bash
# Create a typed link
agent-store link $PARENT $CHILD blocks

# Create a link with no explicit type
agent-store link $A $B

# JSON output
agent-store link $A $B depends --json
# {"from":"<uuid>","to":"<uuid>","rel":"depends"}
```

## agent-store unlink

Remove a link between two entries.

```
agent-store unlink <FROM> <TO> [REL] [--json]
```

Arguments:
- `<FROM>` — Source entry ID or prefix
- `<TO>` — Target entry ID or prefix
- `[REL]` — If provided, removes only this specific relationship. If omitted, removes ALL links from FROM to TO regardless of rel

Idempotent — removing a non-existent link is a no-op (no error).

```bash
# Remove a specific relationship
agent-store unlink $A $B blocks

# Remove ALL links from A to B
agent-store unlink $A $B

# JSON output
agent-store unlink $A $B --json
# {"from":"<uuid>","to":"<uuid>","removed":2}
```

## agent-store links

List all links in the store, optionally filtered by relationship type or entry.

```
agent-store links [--json] [--rel <REL>] [--entry <ID>]
```

Flags:
- `--json` — Output as JSON array of `{from, to, rel, created_at}` objects
- `--rel <REL>` — Filter by relationship type
- `--entry <ID>` — Filter to links involving this entry (as source or target). Supports prefix matching

Plain text output: tab-separated `from_short\tto_short\trel` (8-char ID prefixes). Sorted by created_at descending (newest first).

```bash
# List all links
agent-store links

# Filter by relationship type
agent-store links --rel depends-on

# Links involving a specific entry
agent-store links --entry abc123

# JSON output
agent-store links --json
# [{"from":"<uuid>","to":"<uuid>","rel":"depends-on","created_at":"..."},...]

# Combine filters
agent-store links --rel blocks --entry abc123 --json
```

## agent-store set-attr

Set or update an attribute on an existing entry.

```
agent-store set-attr <ID> <KEY> <VALUE> [--json]
```

Arguments:
- `<ID>` — Entry ID (or unambiguous prefix) to modify.
- `<KEY>` — Attribute key. Cannot be empty.
- `<VALUE>` — Attribute value to set.

Options:
- `--json` — Output as JSON object: `{"id":"...","key":"...","value":"..."}`

Idempotent: setting an attribute that already exists overwrites the value (uses
`INSERT OR REPLACE` on the `(entry_id, key)` primary key). Empty keys are
rejected with an error. Unknown entry IDs print "not found" and exit 1.

Output: `Set <key>=<value> on <short-id>` on stderr (or JSON to stdout with `--json`).

```bash
# Set an attribute
agent-store set-attr $ID priority high

# Update an existing attribute (overwrites)
agent-store set-attr $ID priority low

# JSON output
agent-store set-attr $ID status done --json
# {"id":"<uuid>","key":"status","value":"done"}
```

## agent-store unset-attr

Remove an attribute from an existing entry.

```
agent-store unset-attr <ID> <KEY> [--json]
```

Arguments:
- `<ID>` — Entry ID (or unambiguous prefix) to modify.
- `<KEY>` — Attribute key to remove. Cannot be empty.

Options:
- `--json` — Output as JSON object: `{"id":"...","key":"...","removed":true|false}`

Idempotent: removing an attribute that doesn't exist on the entry is a no-op
(the `DELETE` simply affects zero rows, and `removed` is `false` in JSON output).
Unknown entry IDs print "not found" and exit 1.

Output: `Removed <key> from <short-id>` on stderr when removed, or
`No attribute <key> on <short-id> (no-op)` when the attribute didn't exist
(or JSON to stdout with `--json`).

```bash
# Remove an attribute
agent-store unset-attr $ID priority

# Safe to repeat (idempotent)
agent-store unset-attr $ID nonexistent    # no error, prints no-op message

# JSON output
agent-store unset-attr $ID priority --json
# {"id":"<uuid>","key":"priority","removed":true}
```

## agent-store update

Apply compound metadata mutations (tag/untag/set/unset/link/unlink) atomically
in a single transaction. Supports single-ID mode and bulk mode with query filters.

```
agent-store update [ID] [OPTIONS]
```

Arguments:
- `[ID]` — Entry ID (or unambiguous prefix). When provided, applies mutations
  to a single entry without requiring `--confirm`.

**Mutation flags** (at least one required):
- `--tag <LABEL>` — Add a label (repeatable, INSERT OR IGNORE, idempotent)
- `--untag <LABEL>` — Remove a label (repeatable, DELETE, idempotent)
- `--set <KEY=VALUE>` — Set an attribute (repeatable, INSERT OR REPLACE, overwrites)
- `--unset <KEY>` — Remove an attribute by key (repeatable, DELETE, idempotent)
- `--link <REL>:<ID>` — Create a directional link to target entry (repeatable, INSERT OR IGNORE, idempotent). Same `rel:id` format as `push --link`
- `--unlink <REL>:<ID>` — Remove a link to target entry (repeatable, DELETE, idempotent). Same `rel:id` format as `--link`

**Control flags:**
- `--confirm` — Required for bulk (filter-based) updates. Without it, prints count and exits 1. Conflicts with `--dry-run`
- `--dry-run` — List matching entries without applying mutations. Human-readable to stderr; with `--json`, full entry objects to stdout. Conflicts with `--confirm`
- `--json` — Output as JSON

**Filter flags** (same as query/export/delete):
- `--label <LABEL>` — Filter by label (can be repeated, AND logic)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated)
- `--type <TYPE>` — Filter by entity type
- `--not-type <TYPE>` — Exclude entries with this entity type (can be repeated, NULL-safe)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic)
- `--not-attr <KEY=VALUE>` — Exclude entries with this attribute (can be repeated)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--search <QUERY>` — Full-text search query (FTS5 syntax)
- `--after <DATETIME>` — Only entries created after this timestamp (ISO 8601)
- `--before <DATETIME>` — Only entries created before this timestamp (ISO 8601)

**Single-ID mode:**
- Resolves ID via prefix matching
- No `--confirm` required (explicit ID = intentional)
- Output: `Updated <short-id>` on stderr
- JSON: `{"id":"...","tags_added":N,"tags_removed":N,"attrs_set":N,"attrs_unset":N,"links_added":N,"links_removed":N}`

**Bulk mode (no ID, uses filters):**
- Without `--confirm`: `Would update N entries. Run with --confirm to proceed.` on stderr, exits 1
- With `--confirm`: applies mutations, `Updated N entries` on stderr
- JSON (confirmed): `{"updated":N,"ids":[...],"tags_added":N,"tags_removed":N,"attrs_set":N,"attrs_unset":N,"links_added":N,"links_removed":N}`
- JSON (no confirm): `{"dry_run":true,"count":N}`
- `--dry-run`: lists affected entries without modifying; with `--json`, outputs entry objects
- No ID and no filters: `error: specify an ID or at least one filter`, exits 1

```bash
# Single entry: compound mutation
agent-store update $ID --tag done --untag pending --set status=closed --unset priority

# Single entry with JSON
agent-store update $ID --tag archived --json

# Create links via update
agent-store update $ID --link "depends:$OTHER_ID" --link "blocks:$THIRD_ID"

# Remove links via update
agent-store update $ID --unlink "depends:$OTHER_ID"

# Combine link mutations with metadata mutations
agent-store update $ID --tag linked --link "ref:$TARGET" --json

# Bulk: preview (no --confirm)
agent-store update --label task --tag archived
# Would update 5 entries. Run with --confirm to proceed.

# Bulk: link all matching entries to a target
agent-store update --label task --link "parent:$PROJECT_ID" --confirm

# Bulk: dry run (see affected entries)
agent-store update --label task --tag archived --dry-run

# Bulk: execute
agent-store update --label task --set status=archived --tag archived --confirm

# Bulk: JSON output
agent-store update --label old --untag old --tag migrated --confirm --json
```

## agent-store history

Show chronological history of entries with a given label. Since agent-store is append-only, pushing multiple entries with the same label tracks changes over time. The `history` subcommand makes this explicit with human-readable output.

```
agent-store history <LABEL> [--json] [--limit N] [--data <SUBSTRING>]
```

Arguments:
- `<LABEL>` — Required. The label to show history for.

Options:
- `--json` — Output as JSON array (same format as `query --json`)
- `--limit <N>` — Show only the last N entries (most recent N, still displayed oldest first)
- `--data <SUBSTRING>` — Filter to entries whose data contains the substring

Default sort is oldest first (ASC), opposite of `query` default.

```bash
# Show full history of "config" label
agent-store history config

# Output:
# [2024-01-15 10:30:00] abc1234
#   First value
#
# [2024-01-15 11:00:00] def4567
#   Updated value

# JSON output for programmatic use
agent-store history config --json

# Last 3 entries only
agent-store history config --limit 3

# Search within history
agent-store history config --data "database"
```

## agent-store gc

Collect expired entries — those whose `_expires_at` attribute is in the past.
With `--ttl`, collect all entries older than a given duration instead.

```
agent-store gc [--ttl <DURATION>] [--dry-run] [--json]
```

Options:
- `--ttl <DURATION>` — Override: collect ALL entries whose `created_at` is older than the given duration, regardless of `_expires_at`. Duration format: `<number><unit>` where unit is `s` (seconds), `m` (minutes), `h` (hours), or `d` (days). Examples: `30m`, `24h`, `7d`
- `--dry-run` — Show how many entries would be collected without deleting them
- `--json` — Output as JSON object: `{"collected":1,"ids":["..."]}` or `{"dry_run":true,"count":0}` (with `--dry-run`)

**Default mode (no `--ttl`):**
Entries get an `_expires_at` attribute when pushed with `--ttl`. The `gc`
command scans for entries where `_expires_at` is earlier than the current
time and deletes them (along with their labels and attributes).
Entries without `_expires_at` are never collected — they live forever.

**Override mode (`--ttl <duration>`):**
Ignores `_expires_at` entirely. Instead, collects all entries whose
`created_at` timestamp is older than the specified duration from now.
This is useful for bulk cleanup of old entries regardless of whether
they were pushed with a TTL. Works with `--dry-run` and `--json`.

```bash
# Collect all expired entries (default mode)
agent-store gc
# Collected 3 entries

# Preview without deleting
agent-store gc --dry-run
# 3 expired entries would be collected

# Override: collect everything older than 7 days
agent-store gc --ttl 7d

# Preview age-based collection
agent-store gc --ttl 24h --dry-run

# JSON output with TTL override
agent-store gc --ttl 30m --json
```

## agent-store log

Show the audit trail of mutations (tag, untag, set-attr, unset-attr, delete, update).

```
agent-store log [ID] [--since <TIMESTAMP>] [--limit N] [--label <LABEL>...] [--operation <OP>...] [--json]
```

Options:
- `ID` — Show changelog for a specific entry (supports prefix matching). If omitted, shows recent changes across all entries
- `--since <TIMESTAMP>` — Include only changelog entries after this timestamp (ISO 8601 format)
- `--limit N` — Maximum number of changelog entries to show (default: 50)
- `--label <LABEL>` — Filter to entries that have this label (repeatable, AND logic)
- `--operation <OP>` — Filter by operation type (repeatable, OR logic). Valid operations: `tag`, `untag`, `set-attr`, `unset-attr`, `delete`, `update`
- `--json` — Output as JSON array

```bash
# Show recent changelog across all entries
agent-store log

# Show changelog for a specific entry
agent-store log abc1234

# Show only tag and untag operations
agent-store log --operation tag --operation untag

# Show set-attr operations for entries labeled "config"
agent-store log --operation set-attr --label config

# JSON output with operation filter
agent-store log --operation delete --json

# Combine time and operation filters
agent-store log --since "2024-06-01" --operation tag --limit 20
```

Plain text output format: `[timestamp] operation short_id key change`

Changelog entries are automatically cleaned up during `gc` (default: entries older than 30 days).

## agent-store compact

Optimize the store by running SQLite VACUUM and PRAGMA optimize.

```
agent-store compact [--json]
```

Options:
- `--json` — Output as a JSON object with fields: `size_before`, `size_after`, `freed` (all in bytes)

VACUUM reclaims unused space left behind by deleted entries, and PRAGMA
optimize updates SQLite's query planner statistics. Reports before and
after database sizes in human-readable format.

```bash
# Compact the store
agent-store compact
# 340.0 KB → 232.0 KB (freed 108.0 KB)

# JSON output for scripting
agent-store compact --json
# {"size_before":348160,"size_after":237568,"freed":110592}
```

Run after large deletes, purges, or gc runs to reclaim disk space.

## agent-store alias set

Save a query as a named alias.

```
agent-store alias set <NAME> -- [QUERY FLAGS...]
```

Arguments:
- `<NAME>` — Alias name. Must be unique; if an alias with this name exists, it is overwritten (INSERT OR REPLACE).
- `[QUERY FLAGS...]` — The query flags to save. These are the same flags accepted by `query` (e.g., `--label`, `--type`, `--attr`, `--data`, `--search`, etc.). The `--` separator before the flags is required.

Output: `Alias '<name>' saved` on stderr.

```bash
agent-store alias set urgent-tasks -- --label urgent --type task
agent-store alias set recent-errors -- --label logs --data error --after "2024-01-01"
```

## agent-store alias run

Execute a saved alias (runs the stored query flags).

```
agent-store alias run <NAME> [--mode query|export|delete] [--confirm]
```

Arguments:
- `<NAME>` — Name of an existing alias. Exits 1 if not found.

Options:
- `--mode <MODE>` — Execution mode. Default: `query`.
  - `query` — Run the stored flags as a `query` command (default behavior)
  - `export` — Run the stored flags as an `export` command (JSONL output)
  - `delete` — Run the stored flags as a `delete` command
- `--confirm` — Required when using `--mode delete` to actually execute the deletion. Without it, prints how many entries would be deleted and exits 1.

Runs the specified command with the stored flags. Output matches whatever
the stored flags and mode produce.

```bash
agent-store alias run urgent-tasks
agent-store alias run urgent-tasks --mode export
agent-store alias run urgent-tasks --mode delete
agent-store alias run urgent-tasks --mode delete --confirm
```

## agent-store alias list

List all saved aliases.

```
agent-store alias list
```

Output: one alias per line, tab-separated: `<name>\t<args>`.
If no aliases exist, output is empty.

```bash
agent-store alias list
# urgent-tasks	--label urgent --type task
# recent-errors	--label logs --data error --after 2024-01-01
```

## agent-store alias rm

Remove a saved alias.

```
agent-store alias rm <NAME>
```

Arguments:
- `<NAME>` — Name of the alias to remove. Exits 1 with an error if the alias does not exist.

Output: `Alias '<name>' removed` on stderr.

```bash
agent-store alias rm urgent-tasks
```

## agent-store tally

Count entries grouped by a metadata dimension.

```
agent-store tally --by <DIMENSION> [OPTIONS]
```

Arguments:
- `--by <DIMENSION>` — Required. The dimension to group by:
  - `label` — Group by label. Entries with multiple labels are counted once per label.
  - `type` — Group by entity type. Entries with no type appear as `(none)`.
  - `attr:<KEY>` — Group by the value of attribute `<KEY>`. Entries without that attribute are excluded.

Options:
- `--json` — Output as JSON array of `{"value": "...", "count": N}` objects
- `--label <LABEL>` — Filter by label (can be repeated, AND logic)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated)
- `--type <TYPE>` — Filter by entity type
- `--not-type <TYPE>` — Exclude entries with this entity type (can be repeated, NULL-safe)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic)
- `--not-attr <KEY=VALUE>` — Exclude entries with this attribute (can be repeated)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--search <QUERY>` — Full-text search query (FTS5 syntax)
- `--after <DATETIME>` — Only entries created after this timestamp (ISO 8601)
- `--before <DATETIME>` — Only entries created before this timestamp (ISO 8601)

**Default output:** tab-separated `value\tcount` pairs, sorted descending by count
(then alphabetically by value for ties). One pair per line, stable for agent parsing.

**JSON output:** array of objects, each with `value` (string) and `count` (number).

```bash
# Count entries per label
agent-store tally --by label
# todo	5
# done	3

# Count entries per entity type
agent-store tally --by type
# note	10
# (none)	2

# Count entries per attribute value
agent-store tally --by attr:status
# open	4
# done	3

# JSON output
agent-store tally --by label --json
# [{"value":"todo","count":5},{"value":"done","count":3}]

# Combine with filters
agent-store tally --by type --label urgent
agent-store tally --by attr:priority --type task --after "2024-06-01"
```

## agent-store tail

Watch the store for new entries in real time (like `tail -f`).

```
agent-store tail [OPTIONS]
```

Options:
- `--interval <N>` — Poll frequency in seconds (default: 1)
- `--since <DATETIME>` — Start from entries created after this timestamp (ISO 8601: `"2024-01-15"` or `"2024-01-15 10:30:00"`). Without this flag, only entries created after tail starts are shown
- `--json` — Output each entry as a JSON object (one per line, same fields as `query --json` entries: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`)
- `--label <LABEL>` — Filter by label (can be repeated, AND logic)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated)
- `--type <TYPE>` — Filter by entity type
- `--not-type <TYPE>` — Exclude entries with this entity type (can be repeated, NULL-safe)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic)
- `--not-attr <KEY=VALUE>` — Exclude entries with this attribute (can be repeated)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--search <QUERY>` — Full-text search query (FTS5 syntax)

Polls the store every `--interval` seconds. On each poll, fetches entries
with `created_at` after the last-seen timestamp, prints them (raw data or
JSON), and advances the cursor. Pre-existing entries are skipped unless
`--since` is provided.

Exits cleanly on Ctrl+C (SIGINT), SIGTERM, or broken pipe (e.g., when piped
to `head`).

```bash
# Watch all new entries
agent-store tail

# Watch with a label filter and JSON output
agent-store tail --label deploy --json

# Slower polling (every 5 seconds)
agent-store tail --interval 5

# Start from a past time (catches up on missed entries first)
agent-store tail --since "2024-06-01 09:00:00"

# Combine with other filters
agent-store tail --type event --attr severity=high --json

# Pipe to jq for live structured output
agent-store tail --json | jq '.data'
```

## agent-store completions

Generate shell completion scripts.

```
agent-store completions <SHELL>
```

Supported shells: `bash`, `zsh`, `fish`, `elvish`, `powershell`

Writes the completion script to stdout. Redirect to the appropriate file
for your shell:

```bash
agent-store completions bash > ~/.bash_completion.d/agent-store
agent-store completions zsh > ~/.zfunc/_agent-store
agent-store completions fish > ~/.config/fish/completions/agent-store.fish
```
