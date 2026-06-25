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
- `--strip` — Strip trailing whitespace (including newlines) from data before storing. Useful with `echo` which adds a trailing newline

Data is read from stdin until EOF (or from `--file` if provided). Empty
input is an error. When `--file` is set, it takes precedence over stdin.
File not found prints a clear error and exits 1. Labels, type, and
attribute keys cannot be empty strings.

Scripting example:
```bash
ID=$(echo "data" | agent-store push --label tag --id-only)
agent-store push --label config --file config.json
echo "data" | agent-store push --label x --strip    # stores "data", not "data\n"
```

## agent-store pull \<ID\>

Retrieve an entry by ID.

```
agent-store pull <ID> [--json] [--raw]
```

Prints the entry's data to stdout (raw payload, no metadata). Exit code 1
if the entry is not found.

Options:
- `--json` — Output the full entry as a JSON object (same format as `query --json` entries: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`)
- `--raw` — Omit trailing newline for binary-safe piping. Useful for checksums: `agent-store pull <id> --raw | sha256sum`

## agent-store query

List and filter entries.

```
agent-store query [OPTIONS]
```

Options:
- `--label <LABEL>` — Filter by label (can be repeated, AND logic — all must match)
- `--not-label <LABEL>` — Exclude entries with this label (can be repeated — entries with ANY specified label are excluded)
- `--type <TYPE>` — Filter by entity type (exact match)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic — all must match)
- `--data <SUBSTRING>` — Filter by substring match in entry data
- `--after <DATETIME>` — Only entries created after this timestamp (ISO 8601: `"2024-01-15"` or `"2024-01-15 10:30:00"`)
- `--before <DATETIME>` — Only entries created before this timestamp (ISO 8601: `"2024-01-15"` or `"2024-01-15 10:30:00"`)
- `--json` — Output as JSON array of full entry objects
- `--count` — Output only the number of matching entries (just a number, for scripting)
- `--latest` — Return only the single most recent matching entry (conflicts with `--limit`)
- `--limit <N>` — Return at most N entries
- `--offset <N>` — Skip first N entries (requires `--limit`)
- `-r`, `--reverse` — Reverse sort order to oldest-first (default is newest-first)

Without any filter flags, returns all entries.

`--latest` is the most common agent pattern: "give me the latest entry with this label."
It conflicts with `--limit` (use one or the other). Combine with `--reverse` to get the
oldest single entry instead.

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

Export entries as JSONL (one JSON object per line) for backup and migration.

```
agent-store export [OPTIONS]
```

**Options:**

| Flag | Description |
|------|-------------|
| `--id <ID>` | Filter by entry ID (export a single entry) |
| `--label <LABEL>` | Filter by label (can be repeated, AND logic) |
| `--not-label <LABEL>` | Exclude entries with this label (can be repeated) |
| `--type <TYPE>` | Filter by entity type |
| `--attr <KEY=VALUE>` | Filter by attribute (can be repeated, AND logic) |
| `--data <SUBSTRING>` | Filter by substring match in entry data |
| `--after <DATETIME>` | Only entries created after this timestamp (ISO 8601) |
| `--before <DATETIME>` | Only entries created before this timestamp (ISO 8601) |

All filters match `query` — see `query` docs for filter semantics.

Output goes to stdout. Each line is a self-contained JSON object with
fields: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`.

```bash
agent-store export > backup.jsonl
agent-store export --label important > important.jsonl
agent-store export --not-label archived > active.jsonl
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
