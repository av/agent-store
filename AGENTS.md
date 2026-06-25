<!-- facts:start -->
## Fact-driven development

This project uses [facts](https://github.com/av/facts) for specification and documentation. All work flows through the fact sheet — it is the source of truth.

**Every change starts with a fact.** Facts are the spec — they define what "done" means. Code that isn't described by a fact is unverifiable and will be treated as incorrect. This does not mean every code path needs its own fact — one fact per user-visible behavior is the right granularity. The skill `facts skills show facts` has the full format spec and command reference.

1. `facts list` — read the current spec to orient. Fact sheets can be large — use filters to focus: `--section "cli/init"`, `--tags "draft"`, `--file api.facts`, `--manual`. Read only the section relevant to your task, not the entire sheet.
2. `facts add` — write facts describing what should be true when done. Each fact is a testable claim. You are not ready to write code until this step is complete. Before adding, search the existing sheet for existing coverage — if a fact already describes the behavior, sharpen it instead of adding a near-duplicate.
3. Implement the code to make those facts true.
4. `facts check --tags "<tag>"` or `facts get <id>` — verify your changes. Never run bare `facts check` unless asked.
5. `facts edit <id> --add-tag implemented` — mark verified facts done

Step 4 only works if step 2 happened. If you skipped step 2, go back now — you cannot verify work that has no fact.

**Manual facts (`?` in check output):** these have no command, so you verify them by reading the relevant code. For each `?` fact: read what it claims, check the code, report PASS or FAIL with a one-line reason. Reporting "N manual" without verifying each one is not acceptable.

**Lifecycle:** `@draft` → `@spec` → `@implemented`

**Domain:** the `## domain` section in `.facts` defines the project's entities and relations — read it first to learn the vocabulary.

**What makes a good fact:**
- **Black-box check** — the command tests from the outside: runs the tool, calls the API, checks output. If your command reads a source file for variable names or string literals, rewrite it to test behavior.
- **Independent value** — removing the fact would lose something. If an existing test already validates the same claim, the fact is redundant — state a different claim or skip it.
- **Behavioral label** — the label describes what a user or caller observes, not what the code looks like. Labels never contain source file names, line numbers, or branch names — those belong in tests.
- **Spec-first** — the fact was written before the code (step 2), not after. Record completion by tagging `@implemented`, not by adding new facts about work you already did.
- **Contract-level** — one fact per feature contract, not one per code path. If a section has 3+ facts about the same component, consolidate into one.
- **Actively curated** — before adding, check whether existing facts already cover the behavior. Sharpen or merge them instead of accumulating. A single file past ~80 facts needs splitting.

**Skills** (invoke via `facts skills show <name>`):
- `facts-refine` — sharpen `@draft` facts into `@spec` with the user
- `facts-discover` — scan the codebase and sync facts to reality (only when explicitly asked)
- `facts-implement` — implement `@spec` facts in code, verify, tag `@implemented`
<!-- facts:end -->

<!-- agent-store:start -->
## Agent data store

This project uses [agent-store](https://github.com/av/agent-store) for persistent data storage. Agents can push, pull, and query arbitrary data with no schema.

**Getting started:** Run `agent-store skills get agent-store --full` for the complete usage guide.

```bash
agent-store init                              # Initialize store + install skills
echo "data" | agent-store push --label tag    # Store data
agent-store query --label tag                 # Find it
agent-store pull <id>                         # Retrieve by ID
```

**Skills** (invoke via `agent-store skills get <name>`):
- `agent-store` — Core reference: data model, commands, configuration
- `agent-store-patterns` — Workflow recipes: scratchpad, task tracking, caching, knowledge base
- `agent-store-pipelines` — Shell composition: batch import/export, tool chaining, aggregation
<!-- agent-store:end -->
