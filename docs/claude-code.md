# Using agent-store with Claude Code

Claude Code forgets everything when a session ends. Decisions made, dead
ends explored, project conventions discovered — all of it is re-derived
(or worse, contradicted) next time. `agent-store` fixes this with a
store that lives inside the repo: the agent records what it learns as it
works, and every later session starts from a compact summary of that
memory instead of a blank slate.

This tutorial wires the two together end to end: setup, teaching the
agent via `CLAUDE.md`, injecting context at session start, and a worked
two-session example.

## Setup

Initialize a store at the project root:

```sh
$ agent-store init
Initialized .agent-store/
Installed .agents/skills/agent-store/SKILL.md
Installed .agents/skills/agent-store-patterns/SKILL.md
Installed .agents/skills/agent-store-pipelines/SKILL.md
Installed .claude/skills/agent-store/SKILL.md
Installed .claude/skills/agent-store-patterns/SKILL.md
Installed .claude/skills/agent-store-pipelines/SKILL.md
Added instructions block to CLAUDE.md
```

Three things happened, all Claude Code-relevant:

1. `.agent-store/` was created (and gitignored) — the SQLite database.
2. Three [skills](skills.md) were installed into `.claude/skills/`,
   where Claude Code discovers them automatically. They teach the agent
   how to create records, query, and read context — no prompting needed.
3. If a `CLAUDE.md` existed, a managed instructions block was appended
   (the last line reads `No AGENTS.md or CLAUDE.md found; ...` instead
   when neither file exists — create one and re-run `init`).

Commands find the store by walking up from the current directory, so
they work from any subdirectory of the project.

## The CLAUDE.md block

`init` manages this block between `<!-- agent-store:start/end -->`
markers (re-running `init` refreshes it without touching the rest of the
file):

```markdown
<!-- agent-store:start -->
## agent-store
- Run `agent-store init` before using the project-local store.
- Use `agent-store create <kind> key=value...` to store records and `agent-store find <query>` to retrieve them.
- Use `agent-store ctx` for a compact project summary, and read the installed `agent-store` skills for workflow guidance.
<!-- agent-store:end -->
```

That is enough for the agent to use the store when it thinks of it. To
make recording a habit rather than an option, add your own conventions
outside the managed block:

```markdown
## Project memory
- At the start of each session, run `agent-store ctx` before doing anything else.
- When you make a nontrivial technical decision, record it:
  `agent-store create decision area=<topic> choice=<what> reason=<why>`.
- Before deciding anything, check for prior art: `agent-store find kind=decision area=<topic>`.
- Track multi-session work as `task` records (`title`, `status`); set `status=done` when finished.
```

## Injecting context at session start

`agent-store ctx` prints a Quick Context summary capped at 8192 bytes —
record counts by kind, fields per kind, hooks, and the most recently
updated records — sized to be pasted into a prompt. Claude Code's
`SessionStart` hook can inject it automatically so every session opens
already knowing the project's memory. In `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "agent-store ctx 2>/dev/null || true"
          }
        ]
      }
    ]
  }
}
```

Stdout from a `SessionStart` hook is added to the agent's context. The
`|| true` guard keeps sessions starting cleanly in repos without a store
(`ctx` exits nonzero with `error: no agent-store found` there).

Note the two hook systems are different things: Claude Code hooks fire
on agent lifecycle events and are configured in `.claude/settings.json`;
[agent-store hooks](hooks.md) fire on store mutations and are managed
with `agent-store hook add/ls/rm`. They compose — for example, mirror
task changes into a log file the agent (or you) can tail:

```sh
$ agent-store hook add set kind=task -- 'echo "$AGENT_STORE_ID $AGENT_STORE_FIELD: $AGENT_STORE_OLD_VALUE -> $AGENT_STORE_NEW_VALUE" >> .agent-store/task-changes.log'
ev9c7i
```

## Worked example: memory across two sessions

**Session 1** — the agent evaluates HTTP clients, picks one, and records
the decision plus the follow-up work:

```sh
$ agent-store create decision area=http choice=reqwest reason="rustls default, no openssl build dep"
pcdk3i

$ agent-store create task title="Migrate HTTP client to reqwest" status=pending
jycx1k

$ agent-store link jycx1k implements pcdk3i
Linked jycx1k implements pcdk3i
```

The session ends. The context window is gone; the records are not.

**Session 2** — days later, with the `SessionStart` hook above, the new
session opens with this already in context:

```
Quick Context
Records: 2
Record kinds:
  decision: 1
    fields: area, choice, reason
  task: 1
    fields: status, title
    status: pending=1
Links: 1
  implements: 1
Hooks: 0
Latest activity: 2026-07-03T22:03:44.379Z
Recent records:
  jycx1k task status=pending title='Migrate HTTP client to reqwest'
  pcdk3i decision area=http choice=reqwest reason='rustls default, no openssl build dep'
```

The agent sees pending work and the reasoning behind it without being
told. When it needs detail, it queries — asked "should we use openssl?",
it can check prior art instead of re-litigating:

```sh
$ agent-store find kind=decision area=http
pcdk3i decision area=http choice=reqwest reason='rustls default, no openssl build dep'
```

It finishes the migration and closes the loop:

```sh
$ agent-store set jycx1k status=done
Updated jycx1k
```

Any unambiguous ID prefix works (`agent-store set jyc status=done`), so
recalled IDs from `ctx` output are cheap to reuse.

## Troubleshooting

- **`error: no agent-store found; run 'agent-store init' first`** — no
  `.agent-store/` in the current directory or any ancestor. Run `init`
  at the project root, or check you're inside the right project.
- **The agent isn't using the store** — confirm the managed block is in
  `CLAUDE.md` (re-run `agent-store init` if not) and the skills exist
  under `.claude/skills/`. Nudging conventions (see the CLAUDE.md
  section above) help far more than the minimal block alone.
- **`ctx` output looks truncated** — by design: it's capped at 8192
  bytes, dropping oldest records first. Use `find` with a query for
  anything the summary doesn't surface.
- **Session-start hook shows nothing** — run
  `agent-store ctx` manually in the project to check it succeeds, and
  verify the hook with `claude` → `/hooks` or by inspecting
  `.claude/settings.json`. Hook config changes apply to new sessions.
- **agent-store hooks don't fire on Windows** — hook commands run via
  `bash -c`; install Git Bash or WSL so `bash` is on `PATH`. See
  [Hooks](hooks.md).
- **Cloned an untrusted repo?** — a committed store can ship hooks,
  which are arbitrary shell commands. Inspect `agent-store hook ls` (or
  delete `.agent-store/`) before running mutation commands. See
  [SECURITY.md](../SECURITY.md).

See also: [Concepts](concepts.md) — the mental model behind records,
links, queries, and `ctx`; [Skills and agent integration](skills.md) —
what `init` installs; [Hooks](hooks.md) — store-mutation hooks in depth;
[FAQ](faq.md) — data format, concurrency, privacy, and limits.
