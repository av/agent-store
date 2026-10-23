# Claude Code, Codex and Cursor

agent-store is a CLI, so any agent that can run a shell command can use
it. The work is getting the agent to *think of it* without being told
each session. `agent-store init` handles that for Claude Code, Codex and
Cursor in one go. There is no per-agent mode or flag: the same files
cover all three.

For a full Claude Code walkthrough (conventions, a `SessionStart` hook,
a two-session example), see the
[Claude Code tutorial](claude-code.md).

## What `init` writes

Run it once at the project root:

```sh
$ agent-store init
Initialized .agent-store/
Installed .agents/skills/agent-store/SKILL.md
Installed .agents/skills/agent-store-patterns/SKILL.md
Installed .agents/skills/agent-store-pipelines/SKILL.md
Installed .claude/skills/agent-store/SKILL.md
Installed .claude/skills/agent-store-patterns/SKILL.md
Installed .claude/skills/agent-store-pipelines/SKILL.md
No AGENTS.md or CLAUDE.md found; create one and re-run `agent-store init` to add the instructions block
```

| Path | What it is |
| --- | --- |
| `.agent-store/` | The store. Added to `.gitignore`; the SQLite file appears on the first write. |
| `.agents/skills/<skill>/SKILL.md` | The three [skills](skills.md), for agents that read `.agents/skills/`. |
| `.claude/skills/<skill>/SKILL.md` | The same three skills, byte for byte, for agents that read `.claude/skills/`. |
| `AGENTS.md`, `CLAUDE.md` | A managed instructions block is appended, but only to files that already exist. |

`init` writes nothing agent-specific beyond that: no `.cursor/rules`, no
`.codex/` config, no agent hooks.

The block is the same in both files and sits between markers; `init`
never touches the rest of the file:

```markdown
<!-- agent-store:start -->
## agent-store
This project keeps its cross-session memory in agent-store, a queryable record store in `.agent-store/`.
- At session start, run `agent-store ctx` to see recorded decisions, tasks and notes. Run `agent-store init` only if it reports that no store was found.
- Record decisions, tasks and handoff notes in the store rather than in this file, e.g. `agent-store create decision area=<topic> choice=<what> reason=<why>` or `agent-store create task title=<what> status=pending`.
- Look things up with `agent-store find <query>` (e.g. `agent-store find kind=decision area=auth`); the installed `agent-store` skills have the full workflow.
<!-- agent-store:end -->
```

## Who reads what

Observed in real headless sessions (Claude Code, Codex CLI and
`cursor-agent`, October 2026), each one recording a decision in one
session and recalling it in the next through the store:

| Agent | Skills it reads | Instructions file it reads |
| --- | --- | --- |
| Claude Code | `.claude/skills/` | `CLAUDE.md` |
| Codex | `.agents/skills/` | `AGENTS.md` |
| Cursor (`cursor-agent`) | `.claude/skills/` | `AGENTS.md` and `CLAUDE.md` |

The two skill directories cover all three agents. Each skill's
`description` says when to use it (remembering a decision or task for
later sessions, session start, handoff), so all three agents used the
store from the skills alone, in a repo with no `AGENTS.md` or
`CLAUDE.md`. The instructions block adds the session-start step: with
it, agents run `agent-store ctx` before they start working.

## Fresh repo: create the instruction files, then re-run `init`

In a new repo there is no `AGENTS.md` or `CLAUDE.md`, so the first
`init` adds no block (that is the last line of the output above). Create
both files (empty is fine) and run `init` again:

```sh
$ touch AGENTS.md CLAUDE.md
$ agent-store init
Already initialized .agent-store/
Skills already installed in .agents/skills/ and .claude/skills/
Added instructions block to AGENTS.md
Added instructions block to CLAUDE.md
```

Creating both covers every agent above. If you only use Claude Code,
`CLAUDE.md` is the one that matters; for Codex, `AGENTS.md`. Running
`init` again after that reports the block as already present and changes
nothing.

Commit the skill directories and instruction files so every clone, and
every agent working in it, gets them. The store itself stays
gitignored.

## Per agent

**Claude Code** loads the skills from `.claude/skills/` and the block
from `CLAUDE.md`. To give every session the store summary up front, add a
`SessionStart` hook that runs `agent-store ctx`; the
[Claude Code tutorial](claude-code.md#injecting-context-at-session-start)
has the exact `.claude/settings.json`.

**Codex** reads `AGENTS.md` and opens `.agents/skills/agent-store/SKILL.md`
when the task calls for it. Make sure `AGENTS.md` exists before you run
`init` (or re-run it after creating the file).

**Cursor** (`cursor-agent`) reads the skills from `.claude/skills/` and
the block from `AGENTS.md` or `CLAUDE.md`. No Cursor rules file is
needed.

**Other agents**: anything that reads `AGENTS.md`, or that you can point
at a skill file, works the same way. Otherwise, paste the block above
into whatever instructions file your agent reads.

## Making it a habit

The block tells agents to run `ctx` at session start and to record
decisions and tasks in the store. To make that stricter, add your own
lines outside the managed block. They work in both `AGENTS.md` and
`CLAUDE.md`:

```markdown
## Project memory
- At the start of each session, run `agent-store ctx` before doing anything else.
- When you make a nontrivial technical decision, record it:
  `agent-store create decision area=<topic> choice=<what> reason=<why>`.
- Before deciding anything, check for prior art: `agent-store find kind=decision area=<topic>`.
```

Field names are free-form, so different agents (or sessions) may
describe the same decision with different fields. Naming them in a
convention like this keeps queries such as
`find kind=decision area=database` reliable.

To check what an agent recorded, run `agent-store ctx` or
`agent-store find` yourself after the session.

## After upgrading agent-store

Re-running `init` adds anything missing and never touches your records,
a skill file you edited, or the rest of `AGENTS.md` / `CLAUDE.md`. To
get the current skills or block after upgrading the binary, see
[Skills and agent integration](skills.md#updating).

See also: [Skills and agent integration](skills.md) for what each skill
covers; [Concepts](concepts.md) for records, links, queries and `ctx`.
