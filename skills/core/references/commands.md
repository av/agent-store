# Command Reference

## agent-store init

Initialize a new store.

```
agent-store init
```

Creates `.agent-store/` directory and `store.db` SQLite database. Idempotent — safe to run multiple times. Respects `AGENT_STORE_PATH` env var.

## agent-store push

Store data from stdin.

```
echo "data" | agent-store push [OPTIONS]
```

Options:
- `--label <LABEL>` — Tag the entry (repeatable)
- `--type <TYPE>` — Set entity type
- `--attr <KEY=VALUE>` — Set attribute (repeatable)
- `--quiet` — Only print the entry ID

## agent-store pull <ID>

Retrieve an entry by ID.

```
agent-store pull <ID>
```

Prints the entry's data to stdout. Exit code 1 if not found.

## agent-store query

List and filter entries.

```
agent-store query [OPTIONS]
```

Options:
- `--label <LABEL>` — Filter by label
- `--type <TYPE>` — Filter by entity type
- `--attr <KEY=VALUE>` — Filter by attribute (repeatable, AND logic)
- `--json` — Output as JSON array

Without filters, lists all entries.

## agent-store schema

Show entity types and label counts.

```
agent-store schema
```

## agent-store stats

Show store statistics.

```
agent-store stats
```

Shows entry count, store file size, entity type count, label count.

## agent-store skills

Manage built-in usage guides.

```
agent-store skills list              # List available skills
agent-store skills get <name>        # Print skill guide
agent-store skills get <name> --full # Include references
agent-store skills path <name>       # Print skill data path
```
