# Install details

The primary path is agent-first: a single non-interactive block —
`curl | sh` installer (checksum-verified, no sudo), then
`agent-store --version` and `agent-store init` — that you can hand to a
coding agent or run yourself. That block, plus the secondary methods
(Homebrew, Nix, cargo, prebuilt binaries), lives in the
[README](../README.md#install). This page covers verification, shell
completions, the man page, and upgrade/uninstall.

## Verifying release downloads

Each release asset has a matching `.sha256` file. Download both into the
same directory and check:

```sh
tag=v0.1.2
asset=agent-store-$tag-x86_64-unknown-linux-gnu.tar.gz
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/$asset"
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/$asset.sha256"
sha256sum -c "$asset.sha256"   # macOS: shasum -a 256 -c "$asset.sha256"
```

Releases after v0.1.0 also carry signed [build provenance attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations)
proving each archive was built by this repository's release workflow.
Verify with the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify "$asset" --repo av/agent-store
```

The `curl | sh` installer performs the checksum verification
automatically.

## Shell completions and man page

Completion scripts for bash, zsh, and fish live in
[`completions/`](https://github.com/av/agent-store/tree/master/completions):

```sh
# bash
mkdir -p ~/.local/share/bash-completion/completions
cp completions/agent-store.bash ~/.local/share/bash-completion/completions/agent-store
# zsh (any directory on your $fpath works; this one usually needs sudo)
sudo cp completions/_agent-store /usr/share/zsh/site-functions/
# fish
mkdir -p ~/.config/fish/completions
cp completions/agent-store.fish ~/.config/fish/completions/
```

A man page ships in
[`man/agent-store.1`](https://github.com/av/agent-store/blob/master/man/agent-store.1):

```sh
mkdir -p ~/.local/share/man/man1 && cp man/agent-store.1 ~/.local/share/man/man1/
man agent-store
```

Homebrew and Nix installs include the man page and completions
automatically.

## Upgrading and uninstalling

Upgrade with whatever installed it:

```sh
curl -fsSL https://raw.githubusercontent.com/av/agent-store/master/install.sh | sh   # installer: re-run, replaces the binary
brew upgrade av/tap/agent-store                                                      # Homebrew
nix profile upgrade agent-store                                                      # Nix
cargo install --force --git https://github.com/av/agent-store                        # cargo (source or binstall)
```

`agent-store --version` tells you what you're on. On Windows, replace
`agent-store.exe` with the new release zip's copy.

What lives where, for a clean uninstall:

- **Binary** — the installer puts it at `~/.local/bin/agent-store` (or
  `$AGENT_STORE_INSTALL_DIR`); `rm` it. Otherwise
  `brew uninstall av/tap/agent-store`, `nix profile remove agent-store`,
  or `cargo uninstall agent-store`.
- **Man page and completions** — only present if you copied them per the
  section above (or via Homebrew/Nix, which remove them with the
  package). Delete the copied files from `~/.local/share/man/man1/` and
  your completion directories.
- **Your data** — stores are per-project in each project's
  `.agent-store/` directory (gitignored by `init`); there is no global
  state, config, or cache. Removing the binary loses no data, and
  deleting a project's `.agent-store/` deletes that project's records —
  export first with `agent-store find --json | jq -c '.records[]'` if
  you want a backup (see [JSON output and import](json.md)).
- **`init` artifacts** — in projects where you ran `init`: skill files
  under `.agents/skills/` and `.claude/skills/`, and a managed block in
  `AGENTS.md`/`CLAUDE.md` between `<!-- agent-store:start -->` and
  `<!-- agent-store:end -->` markers. Delete the skill directories and
  the marked block to fully remove them.
