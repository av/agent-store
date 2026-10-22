# Skills and agent integration

`agent-store init` does more than create the database. In one step it:

1. Creates `.agent-store/` (and gitignores it).
2. Installs three skill docs into `.agents/skills/` and `.claude/skills/`.
3. Appends a managed agent-store instructions block to `AGENTS.md` and
   `CLAUDE.md` when those files already exist.

The output enumerates each step: every installed or refreshed skill path,
every skill file kept because you edited it, the instructions block status
per file (added, already present, refreshed, or kept because you edited
it), and — when neither `AGENTS.md` nor `CLAUDE.md` exists — a hint to
create one and re-run `agent-store init` (which then adds the block).
`--json` reports the same summary as `skills_installed`,
`skills_refreshed`, `skills_modified`, and `instructions` arrays.

The result: coding agents working in the project discover the store on
their own — no per-session prompting.

## The bundled skills

| Skill | Covers |
| --- | --- |
| `agent-store` | Core guide: init, creating records, the query language, `ctx`, hooks |
| `agent-store-patterns` | Workflow recipes: scratchpad, task tracker, decision log, handoff memory |
| `agent-store-pipelines` | Shell composition: JSONL import/export, `jq` filtering, batch creation |

Each is a single `SKILL.md` with YAML frontmatter (`name`, `description`),
the format Claude Code and other skill-aware harnesses load automatically.
The tracked sources live in this repo under
[`.agents/skills/`](https://github.com/av/agent-store/tree/master/.agents/skills).

## Conventions the skills teach agents

- **Core loop**: `init` once, then `create` / `find` / `get` / `set` / `ctx`.
- **Small, queryable records** over long append-only logs: a record is a
  `kind` plus `key=value` fields, e.g.
  `create task title="Fix parser" status=pending`.
- **Start sessions with `ctx`**: it prints a compact project summary capped
  at 8192 bytes — record counts by kind, fields per kind, hooks, and the 10
  most recently updated records (truncated, dropped oldest-first to fit).
- **No manual date fields**: listings default to creation order, and
  `created_at` / `updated_at` are queryable and sortable built-ins.
- **Short IDs**: mutation commands print short IDs; any unambiguous prefix
  works in `get`, `set`, `unset`, `rm`, `link`, and friends.

## Suggested kinds

The skills use these by convention (kinds are free-form — anything goes):

- `task` — `title`, `status`, `priority`; query open work with
  `find 'kind=task and status!=done'`
- `decision` — `area`, `choice`, `reason`; a durable decision log
- `note` / `scratch` — free-form working memory within a task
- `log` — captured command output, e.g.
  `create log command=test output="$(cargo test 2>&1)"`

## Updating

After upgrading the binary, re-run `agent-store init` to bring the skills
up to date. A skill file that is still exactly what an earlier release
installed is replaced with the current version (`Refreshed <path>`), and an
unedited instructions block is updated in place. Your records and the rest
of `AGENTS.md` / `CLAUDE.md` are never touched.

A skill file or block you edited is kept as is and reported
(`Kept <path>: modified locally; ...`). To replace it with the current
version, delete it and re-run `init`:

```bash
rm .agents/skills/agent-store/SKILL.md .claude/skills/agent-store/SKILL.md
agent-store init
```

See also: [Claude Code tutorial](claude-code.md) — a full
walkthrough of what these skills enable; [FAQ](faq.md) — data format,
concurrency, privacy, and limits.
