---
name: agent-store-patterns
description: >
  Workflow recipes for agent tasks — scratchpad, task tracking, decision log,
  caching, knowledge base, cross-agent communication, and schema design guidance.
---

# agent-store-patterns

Reusable patterns for common agent workflows built on agent-store.
Each pattern includes when to use it, a ready-to-paste example, and
gotchas. Read `agent-store skills get agent-store` first for command basics.

## Persistent scratchpad

**When:** You need to save intermediate results between steps so later
steps can pick them up — even across context compressions or session
restarts.

```bash
# Save intermediate results with step labels
echo "$ANALYSIS_RESULT" | agent-store push --type scratch --label step1 --attr task=refactor-auth
echo "$PARSED_OUTPUT"   | agent-store push --type scratch --label step2 --attr task=refactor-auth

# Retrieve a specific step
agent-store query --type scratch --label step1 --attr task=refactor-auth

# Get the latest scratchpad value for a label
agent-store query --type scratch --label step1 --attr task=refactor-auth --latest

# Retrieve all steps for a task
agent-store query --type scratch --attr task=refactor-auth

# Capture an ID for immediate round-trip
ID=$(echo "$EXPENSIVE_RESULT" | agent-store push --type scratch --id-only)
# ... do other work ...
agent-store pull "$ID"
```

**Gotcha:** Scratchpad entries accumulate. Use a task-scoped attribute
(`--attr task=<name>`) so you can query just one workflow's state, and
clean up when done (see Data lifecycle below).

## Task tracking

**When:** You want a lightweight kanban — push tasks, mark status with
attributes, query what's pending.

```bash
# Create tasks
echo "implement auth middleware" | agent-store push --type task \
  --label backend --attr status=pending --attr priority=high
echo "write API tests"          | agent-store push --type task \
  --label backend --attr status=pending --attr priority=medium
echo "update README"            | agent-store push --type task \
  --label docs    --attr status=pending --attr priority=low

# Find what needs doing
agent-store query --type task --attr status=pending
agent-store query --type task --attr status=pending --attr priority=high

# Find tasks by area
agent-store query --type task --label backend

# Mark a task done by tagging it
ID=$(agent-store query --type task --label backend --latest --json | jq -r '.[0].id')
agent-store tag "$ID" done

# Exclude completed tasks
agent-store query --type task --not-label done

# Re-open a task by removing the done label
agent-store untag "$ID" done

# View everything as JSON for structured processing
agent-store query --type task --json | jq '.[] | select(.attributes.status == "pending")'
```

**Tip:** Use `tag` and `untag` to move tasks through workflow stages.
Tag entries with `done`, `blocked`, `in-progress` etc. and use
`--not-label done` to filter them out of active queries. This avoids
needing to push new entries just to change status.

## Decision log

**When:** You want an audit trail of architectural or design choices so
future sessions (or other agents) can understand *why* things are the
way they are.

```bash
# Record a decision with context
echo "chose SQLite over Postgres: no daemon needed, single-agent writes, \
embedded in binary. Revisit if we need concurrent multi-agent writes." | \
  agent-store push --type decision --label architecture --attr area=storage

echo "using clap for CLI parsing: derives, built-in help generation, \
widespread in Rust ecosystem" | \
  agent-store push --type decision --label architecture --attr area=cli

# Record a constraint from the user
echo "user constraint: all skill names must be prefixed with 'agent-store' \
because skills install into a shared global pool" | \
  agent-store push --type decision --label constraint --attr source=user

# Query decisions by area
agent-store query --type decision --attr area=storage

# Review all decisions
agent-store query --type decision

# Review all user constraints
agent-store query --type decision --label constraint
```

**Gotcha:** Decisions are most useful when they include the *rationale*
and *alternatives considered*, not just the choice. "Chose X" is less
useful than "Chose X over Y because Z."

## Session state

**When:** You need to persist what was done and where you left off so a
future session can resume without re-discovering the project state.

```bash
# Save session summary at end of work
cat <<'EOF' | agent-store push --type session --label summary --attr session=2024-01-15
Completed:
- Implemented push command with --label and --type flags
- Added query filtering by label

In progress:
- Query filtering by attribute (half done, see src/main.rs:350)

Next:
- Finish attribute filtering
- Add --json output flag
- Write tests for query command
EOF

# Retrieve last session state at start of new session
agent-store query --type session --label summary --latest

# Save what files were modified
echo "src/main.rs src/query.rs tests/cli.rs" | \
  agent-store push --type session --label modified-files --attr session=2024-01-15
```

**Gotcha:** Keep session entries focused and short. A 2000-line dump
is harder to parse than a 20-line summary with pointers to relevant
files and line numbers.

## Caching expensive results

**When:** A computation is slow (API call, large file analysis, test
run) and you want to avoid repeating it if the input hasn't changed.

```bash
# Store a cache entry with a key that identifies the input
HASH=$(sha256sum large-file.json | cut -d' ' -f1)
echo "$ANALYSIS_RESULT" | agent-store push --type cache \
  --label file-analysis --attr hash="$HASH" --attr file=large-file.json

# Check cache before recomputing
CACHED=$(agent-store query --type cache --label file-analysis --attr hash="$HASH" --latest 2>/dev/null)
if [ -n "$CACHED" ]; then
  echo "Cache hit"
  echo "$CACHED"
else
  echo "Cache miss — recomputing"
  RESULT=$(expensive_analysis large-file.json)
  echo "$RESULT" | agent-store push --type cache \
    --label file-analysis --attr hash="$HASH" --attr file=large-file.json
  echo "$RESULT"
fi

# Cache API responses
ENDPOINT="/api/v1/users"
RESPONSE=$(curl -s "https://api.example.com$ENDPOINT")
echo "$RESPONSE" | agent-store push --type cache \
  --label api-response --attr endpoint="$ENDPOINT"
```

**Gotcha:** There's no TTL or automatic eviction. Cache entries live
forever. If your input changes frequently, query for stale entries
periodically and note them for cleanup (see Data lifecycle).

## Knowledge base

**When:** You're building up domain knowledge over time — things
learned about the codebase, API behaviors, debugging findings — and
want to query it later by topic.

```bash
# Store knowledge entries by topic
echo "The auth middleware checks JWT tokens in the Authorization header. \
Tokens expire after 1 hour. Refresh tokens are stored in HttpOnly cookies." | \
  agent-store push --type knowledge --label auth --attr area=backend

echo "Rate limiting is 100 req/min per IP for unauthenticated, \
1000 req/min per user for authenticated. Returns 429 with Retry-After header." | \
  agent-store push --type knowledge --label api --attr area=backend

echo "The CI pipeline runs: lint → typecheck → test → build → deploy. \
Deploy only on main branch. Test timeout is 10 minutes." | \
  agent-store push --type knowledge --label ci --attr area=infra

# Query by topic
agent-store query --type knowledge --label auth
agent-store query --type knowledge --attr area=backend

# Full knowledge dump for context
agent-store query --type knowledge --json | jq -r '.[].data'
```

**Gotcha:** Knowledge entries can become stale. When you discover
something has changed, push a corrected entry with the same labels.
Periodically review with `agent-store query --type knowledge --json`
to spot outdated information.

## Project artifact catalog

**When:** You want a quick-lookup index of project structure — files,
APIs, endpoints, config locations — without re-scanning every time.

```bash
# Index API endpoints
echo "GET /api/v1/users — list users, supports ?page=N&limit=N" | \
  agent-store push --type endpoint --label api --attr method=GET --attr path=/api/v1/users
echo "POST /api/v1/users — create user, body: {name, email}" | \
  agent-store push --type endpoint --label api --attr method=POST --attr path=/api/v1/users

# Index key files
echo "src/main.rs — CLI entry point, command routing" | \
  agent-store push --type file-index --attr path=src/main.rs --attr role=entrypoint
echo "src/auth.rs — JWT validation, token refresh" | \
  agent-store push --type file-index --attr path=src/auth.rs --attr role=auth

# Index environment variables
echo "DATABASE_URL — Postgres connection string, required" | \
  agent-store push --type env-var --attr name=DATABASE_URL --attr required=true
echo "LOG_LEVEL — debug|info|warn|error, default: info" | \
  agent-store push --type env-var --attr name=LOG_LEVEL --attr required=false

# Quick lookups
agent-store query --type endpoint --attr method=GET
agent-store query --type file-index --attr role=auth
agent-store query --type env-var --attr required=true
```

**Gotcha:** Keep catalog entries to one line or a short block per item.
The value is fast lookup, not deep documentation. Point to the source
file for details.

## Cross-agent communication

**When:** Multiple agents share a store (via `AGENT_STORE_PATH`) and
need to leave messages, handoffs, or findings for each other.

```bash
# Shared store setup — both agents use the same path
export AGENT_STORE_PATH=/path/to/shared/store
agent-store init

# Agent A: leave a finding for Agent B
echo "Found SQL injection in src/api/users.rs:42 — \
user input passed directly to query string" | \
  agent-store push --type finding --label security \
  --attr severity=critical --attr from=agent-a --attr status=new

# Agent B: pick up new findings
agent-store query --type finding --attr status=new

# Agent B: acknowledge after handling
echo "Fixed SQL injection: parameterized query in commit abc1234" | \
  agent-store push --type finding --label security \
  --attr severity=critical --attr from=agent-b --attr status=resolved \
  --attr related-commit=abc1234

# Handoff pattern — one agent leaves work for the next
echo "Auth middleware implemented and tested. \
Next agent: add rate limiting on top (see src/middleware.rs)" | \
  agent-store push --type handoff --attr from=agent-a --attr to=agent-b

# Check for handoffs addressed to you
agent-store query --type handoff --attr to=agent-b
```

**Gotcha:** There's no locking or ordering guarantees. If two agents
push simultaneously, both entries are stored but query order isn't
guaranteed. Use attributes (`--attr from=`, `--attr status=`) to
disambiguate.

## Schema design guide

**When:** You're deciding how to organize data in agent-store and want
to pick the right metadata for efficient querying.

### Labels vs types vs attributes

| Mechanism | Best for | Queryable | Example |
|-----------|----------|-----------|---------|
| `--type` | The *kind* of thing (noun) | `--type task` | task, decision, knowledge, cache |
| `--label` | Categorical tags (adjective) | `--label urgent` | urgent, backend, reviewed, stale |
| `--attr` | Structured key-value pairs | `--attr status=pending` | status=pending, priority=high, hash=abc123 |

### Rules of thumb

1. **One type per entry.** Types are mutually exclusive categories.
   Use type for the primary classification: `task`, `decision`, `cache`,
   `knowledge`, `session`, `finding`.

2. **Labels for cross-cutting concerns.** An entry can have multiple
   labels. Use them for tags that span types: `urgent`, `backend`,
   `api`, `reviewed`.

3. **Attributes for filterable fields.** Use attributes when you need
   to filter by specific values: `status=pending`, `priority=high`,
   `assignee=agent-a`. Attributes support AND queries with multiple
   `--attr` flags.

4. **Data field for the payload.** The stdin data is the actual
   content. Keep metadata in labels/types/attributes, keep content in
   data.

### Anti-patterns

- **Encoding metadata in the data blob.** If you'll need to filter by
  it, it should be a label, type, or attribute — not buried in JSON.
- **Using attributes for tags.** If a value is just present/absent
  (not key=value), use a label: `--label reviewed` not
  `--attr reviewed=true`.
- **One entry per line of output.** Store logical units, not raw lines.
  One entry per task/finding/decision, not one per line of stdout.

## Data lifecycle

**When:** The store has accumulated entries over time and you need to
manage its size or clean up obsolete data.

```bash
# Check store size
agent-store stats

# Review what's in the store
agent-store schema

# Find entries by type to assess what can be cleaned
agent-store query --type scratch --json | jq 'length'
agent-store query --type cache   --json | jq 'length'

# Export before cleanup (backup)
agent-store query --type scratch --json > /tmp/scratch-backup.json

# Identify stale cache entries (manual review via JSON)
agent-store query --type cache --json | \
  jq '.[] | {id, created: .created_at, labels, attrs: .attributes}'

# There is no delete command — agent-store is append-only by design.
# For cleanup, re-initialize:
#   1. Export what you want to keep
#   2. Remove the store directory
#   3. Re-init and re-import

# Export keepers (JSONL format preserves all metadata including timestamps)
agent-store export --type decision > /tmp/decisions.jsonl
agent-store export --type knowledge > /tmp/knowledge.jsonl

# Nuke and rebuild
rm -rf .agent-store
agent-store init

# Re-import (preserves timestamps, labels, attributes — only IDs change)
cat /tmp/decisions.jsonl /tmp/knowledge.jsonl | agent-store import
```

**Gotcha:** The re-init approach loses entry IDs (timestamps are preserved by import). If
other entries reference IDs (e.g., "see entry abc123"), those references
break. For stores where referential integrity matters, prefer growing
the store and using labels/attributes to mark entries as superseded
rather than deleting:

```bash
# Mark an entry as superseded instead of deleting
# Push a new version and tag it
echo "updated auth docs — tokens now expire in 2 hours" | \
  agent-store push --type knowledge --label auth --label current
# The old entry still exists but won't match --label current
```

## Putting it together

A typical agent workflow combines several patterns:

```bash
# Start of session: check for prior state
agent-store query --type session --label summary
agent-store query --type handoff --attr to=me

# During work: persist findings and decisions
echo "$FINDING" | agent-store push --type finding --label security --attr severity=high
echo "$DECISION" | agent-store push --type decision --label architecture

# Cache expensive work
echo "$TEST_RESULTS" | agent-store push --type cache --label test-run --attr commit="$GIT_SHA"

# End of session: save state
echo "$SESSION_SUMMARY" | agent-store push --type session --label summary
```
