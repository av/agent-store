# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 0.1.x   | Yes       |

## Reporting a vulnerability

Report privately via [GitHub security advisories](https://github.com/av/agent-store/security/advisories/new)
(preferred), or email av@av.codes. Please do not open a public issue for
security reports.

Expect an acknowledgement within a few days and a fix or mitigation plan
within two weeks for confirmed issues. Fixes ship as a patch release with a
note in the changelog.

## Security model

agent-store makes no network connections. All data lives in
`.agent-store/store.sqlite` in your project.

### Hooks and schedules execute shell commands

The store holds two kinds of shell command, and they are its only
code-execution surface:

- **Hooks**: a `bash -c` command that runs automatically after matching
  mutations (`create`, `set`, `unset`, `rm`, `link`, `unlink`).
- **Schedules**: a `bash -c` command that runs when `agent-store schedule
  tick` finds it due. `agent-store schedule enable` installs a crontab
  entry that runs `tick` for the project every minute, so once it is
  enabled, due schedules run with nobody typing a command, until
  `schedule disable` removes the entry.

Both run as you, with the project root as their working directory.

Consequence: anyone who can write to `.agent-store/store.sqlite` can run
arbitrary commands as you the next time a hook fires or a schedule is
ticked. In particular, a cloned repository could ship a committed
`.agent-store/` directory containing malicious hooks or schedules.

Coding agents make this easier to trigger: the installed skills tell
agents to create and update records as they work, so an agent in a
cloned repository fires any hooks in a committed store without looking
at them first. agent-store has no trust prompt or allowlist for stored
commands.

Mitigations:

- `agent-store init` adds `.agent-store/` to the project's `.gitignore`, so
  stores are not committed by default. This protects repos you initialize —
  it does not protect you from a repo that deliberately commits a store.
- Before you, or an agent, work in a repository you did not create, check
  whether it ships a store (`git ls-files .agent-store`) and inspect it with
  `agent-store hook ls` and `agent-store schedule ls`. Deleting the
  directory removes the store entirely.
- `crontab -l` lists every `# agent-store:tick:<project-root>` entry that
  `schedule enable` installed; `agent-store schedule disable` in that
  project removes its entry.
- Hook and schedule commands are capped at a 30-second timeout and 8192
  bytes of captured output, but these are resource limits, not a sandbox.

Treat a `.agent-store/` directory you did not create the same way you would
treat a checked-in shell script.
