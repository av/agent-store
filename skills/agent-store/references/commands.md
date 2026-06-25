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

Store data from stdin.

```
echo "data" | agent-store push [OPTIONS]
```

Options:
- `--label <LABEL>` — Tag the entry (repeatable for multiple labels)
- `--type <TYPE>` — Set entity type classification
- `--attr <KEY=VALUE>` — Set attribute key-value pair (repeatable, AND logic on query)
- `-q`, `--quiet` — Suppress all output (for scripting when no feedback is needed)
- `--id-only` — Output only the raw UUID (no "stored entry" prefix). Conflicts with `--quiet`

Data is read from stdin until EOF. Empty stdin is an error. Labels, type,
and attribute keys cannot be empty strings.

Scripting example:
```bash
ID=$(echo "data" | agent-store push --label tag --id-only)
```

## agent-store pull \<ID\>

Retrieve an entry by ID.

```
agent-store pull <ID>
```

Prints the entry's data to stdout (raw payload, no metadata). Exit code 1
if the entry is not found.

## agent-store query

List and filter entries.

```
agent-store query [OPTIONS]
```

Options:
- `--label <LABEL>` — Filter by label (can be repeated, AND logic — all must match)
- `--type <TYPE>` — Filter by entity type (exact match)
- `--attr <KEY=VALUE>` — Filter by attribute (can be repeated, AND logic — all must match)
- `--data <SUBSTRING>` — Filter by substring match in entry data
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

`--count` ignores `--limit`/`--offset` and always reports the total matching count.
When combined with `--latest`, `--count` returns 0 or 1.

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
- `--json` — Output stats as a JSON object with fields: `entries`, `entity_types`, `labels`, `entity_type_count`, `label_count`

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
| `--label <LABEL>` | Filter by label (can be repeated, AND logic) |
| `--type <TYPE>` | Filter by entity type |
| `--attr <KEY=VALUE>` | Filter by attribute (can be repeated, AND logic) |

Output goes to stdout. Each line is a self-contained JSON object with
fields: `id`, `data`, `entity_type`, `created_at`, `labels`, `attributes`.

```bash
agent-store export > backup.jsonl
agent-store export --label important > important.jsonl
agent-store export | jq -r '.id'
```

## agent-store import

Import entries from JSONL on stdin. Complement of `export`.

```
agent-store import
```

Reads JSONL from stdin (one JSON object per line). For each valid line,
inserts a new entry with a fresh UUID and timestamp. The `id` and
`created_at` fields from the input are ignored to prevent ID conflicts.

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
