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
- `--quiet` — Only print the entry UUID (for scripting and piping)

Data is read from stdin until EOF. Empty stdin is an error. Labels, type,
and attribute keys cannot be empty strings.

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
- `--json` — Output as JSON array of full entry objects

Without any filter flags, returns all entries.

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
```

Reports:
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
