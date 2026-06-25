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

# Overwrite scratch data in place (no new entry, no history)
echo "$UPDATED_RESULT" | agent-store push --update "$ID"

# Clean up scratch entries when done
agent-store delete --type scratch --attr task=refactor-auth --confirm

# Or delete a single scratch entry by ID
agent-store delete "$ID"
```

**Gotcha:** Scratchpad entries accumulate. Use a task-scoped attribute
(`--attr task=<name>`) so you can query just one workflow's state, and
clean up with `delete` when done (see Data lifecycle below). For data
you expect to overwrite repeatedly (e.g., a running summary), use
`push --update` to replace in place instead of appending new entries.

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

# Quick lookups — grab the newest or oldest task
agent-store query --type task --attr status=pending --last   # newest pending task
agent-store query --type task --attr status=pending --first  # oldest pending task

# Find tasks by area
agent-store query --type task --label backend

# Update task status with set-attr (no new entry needed)
ID=$(agent-store query --type task --label backend --last --json | jq -r '.[0].id')
agent-store set-attr "$ID" status in-progress
agent-store set-attr "$ID" status done

# Mark a task done by tagging it (label-based workflow)
agent-store tag "$ID" done

# Exclude completed tasks
agent-store query --type task --not-label done
agent-store query --type task --not-attr status=done

# Re-open a task
agent-store untag "$ID" done
agent-store set-attr "$ID" status pending

# Reprioritize
agent-store set-attr "$ID" priority critical

# Remove an attribute that's no longer relevant
agent-store unset-attr "$ID" blocked-by

# View everything as JSON for structured processing
agent-store query --type task --json | jq '.[] | select(.attributes.status == "pending")'

# Search tasks by content
agent-store query --type task --search "auth middleware"
```

**Tip:** Use `set-attr` to move tasks through workflow stages when
status is an attribute (`status=pending` -> `status=done`). Use `tag`
and `untag` when status is a label (`done`, `blocked`, `in-progress`).
Both approaches avoid pushing new entries just to change status.
`--first` and `--last` are useful for quick lookups without `--json |
jq`.

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

**Tip:** For automatic tracking of metadata changes (tag/untag/set-attr/etc),
use the built-in changelog — `agent-store log` shows all mutations without
manual logging. The decision log pattern is for higher-level *why* records.

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

**Tip:** Use `--ttl` to set automatic expiry on cache entries:

```bash
# Push with TTL — entry expires after 24 hours
echo "$RESULT" | agent-store push --type cache \
  --label file-analysis --attr hash="$HASH" --ttl 24h

# Collect expired cache entries
agent-store gc

# Aggressive cleanup — delete ALL cache entries older than 1 hour
agent-store gc --ttl 1h

# Preview what gc would collect before running
agent-store gc --dry-run

# Reclaim disk space after large cleanup
agent-store compact
```

See the TTL section in `agent-store skills get agent-store` for details.

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

# Full-text search across all knowledge (FTS5, relevance-ranked)
agent-store query --type knowledge --search "JWT tokens"
agent-store query --type knowledge --search "rate limit*"

# Combine search with filters
agent-store query --type knowledge --search "deploy" --attr area=infra

# Export knowledge in different formats
agent-store export --type knowledge --format json > knowledge.json
agent-store export --type knowledge --format csv > knowledge.csv
agent-store export --type knowledge --label auth --format jsonl > auth.jsonl

# Full knowledge dump for context
agent-store query --type knowledge --json | jq -r '.[].data'
```

**Gotcha:** Knowledge entries can become stale. When you discover
something has changed, use `push --update` to correct an entry in
place, or push a new entry with the same labels for versioned history.
Use `--search` instead of `--data` when you need relevance-ranked
results or fuzzy matching (e.g., `--search "database connection"` finds
entries about DB connections even if they don't contain the exact
substring).

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

# Delete old cache entries
agent-store delete --type cache --before "2024-01-01" --confirm

# Delete scratch entries from a completed task
agent-store delete --label step1 --attr task=refactor-auth --confirm

# Delete by label — preview first, then confirm
agent-store delete --label stale
# Would delete 5 entries. Run with --confirm to proceed.
agent-store delete --label stale --confirm

# Delete a single entry by ID (no --confirm needed)
agent-store delete $ID

# For a full reset, use purge instead
agent-store purge --confirm
```

**Gotcha:** Single-ID delete needs no confirmation, but filter-based
delete always requires `--confirm`. Without it, the command prints how
many entries would be deleted and exits 1 — use this as a dry-run
preview before committing. For selective cleanup, prefer `delete` with
filters over `purge` (which removes everything).

## Upsert — atomic find-or-create

**When:** You want to ensure exactly one entry exists for a given identity
(combination of labels, type, and/or attrs), creating it if missing or
updating it if found. Ideal for singleton config, agent state, or
deduplicated records.

```bash
# First call creates the entry
echo "initial config" | agent-store push --upsert --label config --attr env=prod

# Second call with same filters updates the existing entry's data
echo "updated config" | agent-store push --upsert --label config --attr env=prod

# Check: only one entry exists
agent-store query --label config --attr env=prod --count  # => 1
```

The filters (`--label`, `--type`, `--attr`) define the entry's identity.
All provided filters must match for an existing entry to be found:

- **0 matches** - creates a new entry with the given data, labels, type, and attrs
- **1 match** - updates that entry's data, merges labels (INSERT OR IGNORE),
  upserts attrs (INSERT OR REPLACE)
- **2+ matches** - errors with "upsert matched N entries, narrow your filters"

Use `--json` to see the action taken:

```bash
echo "data" | agent-store push --upsert --label singleton --json
# => {"action":"created","id":"...","labels":["singleton"]}

echo "new data" | agent-store push --upsert --label singleton --json
# => {"action":"updated","id":"...","labels":["singleton"]}
```

**Gotcha:** All labels and attrs are used as match filters AND applied to the
entry. If you need to add new labels/attrs during an update, use `tag`,
`set-attr`, or `push --update <id>` after the upsert.

## Supersede / versioning

**When:** You need to "update" an entry and want to preserve the original
for version history. If you just need a simple in-place replacement without
history, use `push --update <id>` instead (see `agent-store skills get
agent-store` for details).

For versioned updates, agent-store's convention is to push a new entry and
link it to the one it replaces with `--attr supersedes=<old-id>`.

```bash
# Push the original entry
ID=$(echo "v1 config" | agent-store push --type config --label app-config --id-only)

# Later, push a replacement that links back to the original
echo "v2 config" | agent-store push --type config --label app-config \
  --attr supersedes=$ID

# The latest version is always the most recent entry with that label
agent-store query --type config --label app-config --latest
```

### Query pattern — get the current version

Queries return newest-first by default. Use `--latest` (or `head -1`
on raw output) to get the current version:

```bash
# Single latest entry
agent-store query --type config --label app-config --latest

# Or with head for raw output
agent-store query --type config --label app-config | head -1
```

### Chain pattern — trace version history

Follow the `supersedes` attribute to walk the full revision chain:

```bash
# Get the latest entry as JSON
LATEST=$(agent-store query --type config --label app-config --latest --json)
echo "$LATEST" | jq -r '.[0].data'

# Walk the chain backwards
PREV_ID=$(echo "$LATEST" | jq -r '.[0].attributes.supersedes // empty')
while [ -n "$PREV_ID" ]; do
  ENTRY=$(agent-store pull "$PREV_ID" --json)
  echo "Previous version: $(echo "$ENTRY" | jq -r .data)"
  PREV_ID=$(echo "$ENTRY" | jq -r '.attributes.supersedes // empty')
done
```

### Cleanup pattern — remove old versions

After confirming the new version works, delete the old one:

```bash
# Get the ID of the latest entry
LATEST_ID=$(agent-store query --type config --label app-config --latest --json | jq -r '.[0].id')

# Get the ID it superseded
OLD_ID=$(agent-store query --type config --label app-config --latest --json | jq -r '.[0].attributes.supersedes // empty')

# Delete the old version
if [ -n "$OLD_ID" ]; then
  agent-store delete "$OLD_ID"
fi
```

### Example: iterative draft

The supersede pattern works well for iterative content like drafts,
where each revision replaces the last:

```bash
# First draft
DRAFT_ID=$(echo "Initial proposal text" | agent-store push \
  --type draft --label proposal --attr version=1 --id-only)

# Second draft supersedes the first
DRAFT_ID=$(echo "Revised proposal with feedback" | agent-store push \
  --type draft --label proposal --attr version=2 \
  --attr supersedes=$DRAFT_ID --id-only)

# Current draft is always the latest
agent-store query --type draft --label proposal --latest

# Full history via the history command
agent-store history proposal
```

**Gotcha:** The supersede attribute is a convention, not enforced by the
store. It relies on agents consistently setting `--attr supersedes=<id>`
when pushing replacements. If you skip the attribute, the entries are
still queryable by recency — you just lose the explicit link between
versions.

## Multi-agent coordination

**When:** Multiple agents share a store and need to watch each other's
output in real time — one agent produces work, another reacts to it.

```bash
# Shared store setup
export AGENT_STORE_PATH=/path/to/shared/store

# Agent A: push findings as it works
echo "SQL injection in users.rs:42" | agent-store push --type finding \
  --label security --attr severity=critical --attr from=agent-a

# Agent B: watch for new findings in real time
agent-store tail --type finding --label security --json

# Agent B: watch only critical findings
agent-store tail --type finding --attr severity=critical --json --interval 2

# Agent B: pipe live findings to a processing script
agent-store tail --type finding --json | jq -r '.data' | while read -r finding; do
  echo "New finding: $finding"
done

# Coordination: one agent signals readiness, another waits for it
# Agent A (producer):
echo "ready" | agent-store push --type signal --label phase-1-done

# Agent B (consumer) — tail exits on first match via head
agent-store tail --type signal --label phase-1-done | head -1
echo "Phase 1 complete, starting phase 2"

# Watch entries from a specific point in time
agent-store tail --since "2024-06-01 09:00:00" --type event --json
```

**Tip:** `tail` is ideal for live coordination. For polling-based
workflows where you check periodically rather than streaming, use
`query --last` to grab the newest entry in a loop. For one-shot
handoffs, the cross-agent communication pattern (above) is simpler.

## Audit trail

**When:** You want to annotate entries after the fact — add metadata
to record what happened to an entry without modifying its original
data.

```bash
# Push an entry
ID=$(echo "deploy v2.3.1 to production" | agent-store push \
  --type event --label deploy --id-only)

# Later: annotate with audit metadata
agent-store set-attr "$ID" reviewed-by agent-b
agent-store set-attr "$ID" reviewed-at "2024-06-15 14:30:00"
agent-store set-attr "$ID" outcome success

# Tag with audit labels
agent-store tag "$ID" reviewed
agent-store tag "$ID" approved

# Query for unreviewed entries
agent-store query --type event --not-label reviewed

# Query for entries with a specific outcome
agent-store query --type event --attr outcome=success

# Annotate a finding with resolution details
FINDING_ID=$(agent-store query --type finding --label security --last --json | jq -r '.[0].id')
agent-store set-attr "$FINDING_ID" resolution "patched in commit abc1234"
agent-store set-attr "$FINDING_ID" resolved-by agent-c
agent-store tag "$FINDING_ID" resolved

# Remove a mistaken annotation
agent-store unset-attr "$FINDING_ID" resolution
agent-store untag "$FINDING_ID" resolved
```

**Tip:** The audit trail pattern separates the original data (immutable)
from annotations added later (mutable via `set-attr` and `tag`). This
gives you the benefits of append-only data (nothing lost) with the
flexibility to track status changes and review outcomes after the fact.

## Links — relationship modeling

**When:** Entries have structural relationships — task dependencies,
parent-child hierarchies, or associative references — and you need to
traverse or query those relationships.

### Task dependencies

```bash
# Create tasks
DESIGN=$(echo "design auth flow" | agent-store push --type task --label backend --id-only)
IMPL=$(echo "implement auth" | agent-store push --type task --label backend --id-only)
TEST=$(echo "test auth" | agent-store push --type task --label backend --id-only)

# Link: IMPL depends-on DESIGN, TEST depends-on IMPL
agent-store link "$IMPL" "$DESIGN" depends-on
agent-store link "$TEST" "$IMPL" depends-on

# Find what a task depends on
agent-store query --linked-from "$TEST" --link-rel depends-on

# Find what depends on a task (reverse — who is blocked by this?)
agent-store query --linked-to "$DESIGN" --link-rel depends-on
```

### Parent-child hierarchy

```bash
# Create an epic and its child tasks
EPIC=$(echo "user authentication" | agent-store push --type epic --label auth --id-only)

# Push children with links in one command
echo "login page" | agent-store push --type task --link "child-of:$EPIC" --label auth
echo "logout flow" | agent-store push --type task --link "child-of:$EPIC" --label auth
echo "password reset" | agent-store push --type task --link "child-of:$EPIC" --label auth

# List all children of the epic
agent-store query --linked-to "$EPIC" --link-rel child-of

# Count children
agent-store query --linked-to "$EPIC" --link-rel child-of --count
```

### Associative references — linking findings to sources

```bash
# A finding references the file it was found in
FILE_ID=$(echo "src/auth.rs" | agent-store push --type file-index --id-only)
echo "SQL injection at line 42" | agent-store push --type finding \
  --label security --link "found-in:$FILE_ID" --attr severity=critical

# Later: find all findings for a file
agent-store query --linked-to "$FILE_ID" --link-rel found-in

# Find what a finding references
agent-store query --linked-from "$FINDING_ID" --link-rel found-in
```

### Inspecting links

```bash
# See all links on an entry (both directions)
agent-store pull "$ID" --json --with-links

# The output includes:
#   links_from: [{to, rel, created_at}]  — edges going out
#   links_to:   [{from, rel, created_at}] — edges coming in
```

**Gotcha:** Links are directional. `link A B rel` means A->B. Use
`--linked-from A` to find entries A points to, `--linked-to B` to find
entries pointing at B. Deleting an entry removes its link rows in both
directions but does not cascade-delete linked entries.

**Tip:** For version chains, consider whether links or the `supersedes`
attribute pattern (see Supersede / versioning above) fits better. Links
are better when relationships are many-to-many or have named types;
`supersedes` is simpler for linear version history.

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
