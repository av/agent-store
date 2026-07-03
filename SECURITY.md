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

### Hooks execute shell commands

Hooks are the one code-execution surface. A hook is a `bash -c` command
string stored in the local store; it runs automatically after matching
mutations (`create`, `set`, `unset`, `rm`, `link`, `unlink`), with the
project root as its working directory.

Consequence: anyone who can write to `.agent-store/store.sqlite` can run
arbitrary commands as you the next time a hook fires. In particular, a
cloned repository could ship a committed `.agent-store/` directory
containing malicious hooks.

Mitigations:

- `agent-store init` adds `.agent-store/` to the project's `.gitignore`, so
  stores are not committed by default. This protects repos you initialize —
  it does not protect you from a repo that deliberately commits a store.
- After cloning an untrusted repository, check whether `.agent-store/`
  exists and run `agent-store hook ls` to inspect any hooks before running
  mutation commands. Deleting the directory removes the store entirely.
- Hooks are capped at a 30-second timeout and 8192 bytes of captured
  output, but these are resource limits, not a sandbox.

Treat a `.agent-store/` directory you did not create the same way you would
treat a checked-in shell script.
