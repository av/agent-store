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
target=x86_64-unknown-linux-gnu
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/agent-store-$tag-$target.tar.gz"
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/agent-store-$tag-$target.sha256"
sha256sum -c "agent-store-$tag-$target.sha256"   # macOS: shasum -a 256 -c ...
```

The `.sha256` asset is named after the target, not the archive — there
is no `.tar.gz.sha256`/`.zip.sha256`. Its content is
`<hash>  <archive-name>` for the unix archives and `<hash> *<archive-name>`
for the Windows zip; `sha256sum -c` reads both directly.

Releases after v0.1.0 also carry signed [build provenance attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations)
proving each archive was built by this repository's release workflow.
Verify with the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify "$asset" --repo av/agent-store
```

The `curl | sh` installer performs the checksum verification
automatically.

## Windows

The simplest Windows installs are `cargo binstall` (prebuilt) or
`cargo install` from the README's install section — both work natively.
To install from the release zip instead, this PowerShell block
downloads, verifies the SHA-256 checksum, and extracts (the zip has
`agent-store.exe` at its root, plus `LICENSE`, `THIRD-PARTY-LICENSES.md`,
`README.md`, and unix-only `completions/` and `man/`):

```powershell
$tag = "v0.1.2"; $base = "agent-store-$tag-x86_64-pc-windows-msvc"
$url = "https://github.com/av/agent-store/releases/download/$tag"
Invoke-WebRequest "$url/$base.zip" -OutFile "$base.zip"
Invoke-WebRequest "$url/$base.sha256" -OutFile "$base.sha256"
# .sha256 content is "<hash> *<zip-name>"; PowerShell -ne is case-insensitive
$expected = ((Get-Content "$base.sha256") -split '\s+')[0]
if ((Get-FileHash "$base.zip" -Algorithm SHA256).Hash -ne $expected) { throw "checksum mismatch" }
Expand-Archive "$base.zip" -DestinationPath "$env:LOCALAPPDATA\Programs\agent-store" -Force
```

Re-running the block with a newer `$tag` upgrades in place (`-Force`
overwrites the existing `agent-store.exe`).

Then add that directory to your user `PATH` (new terminals pick it up; run
this once, not on every upgrade):

```powershell
[Environment]::SetEnvironmentVariable("Path", "$env:LOCALAPPDATA\Programs\agent-store;" + [Environment]::GetEnvironmentVariable("Path", "User"), "User")
```

The core CLI works natively; [hooks](hooks.md) run their commands via
`bash -c`, so hooks need a `bash` on `PATH` (Git Bash or WSL) —
everything else works without one.

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

`agent-store --version` tells you what you're on. On Windows, re-run the
PowerShell block above with the new tag.

What lives where, for a clean uninstall. Do the first item before you
remove the binary:

- **Scheduled jobs** — if you ran `agent-store schedule enable` in a
  project, it installed a crontab entry for that project (a
  `# agent-store:tick:<project-root>` comment plus the line after it).
  Run `agent-store schedule disable` in each such project first. If the
  binary is already gone, delete those two lines with `crontab -e`.
- **Binary** — the installer puts it at `~/.local/bin/agent-store` (or
  `$AGENT_STORE_INSTALL_DIR`); `rm` it. Otherwise
  `brew uninstall av/tap/agent-store`, `nix profile remove agent-store`,
  or `cargo uninstall agent-store-cli` (the crate is `agent-store-cli`;
  the binary is `agent-store`). On Windows, delete the install directory
  and drop it from your user `PATH`:

  ```powershell
  $dir = "$env:LOCALAPPDATA\Programs\agent-store"
  Remove-Item -Recurse -Force $dir
  $path = ([Environment]::GetEnvironmentVariable("Path", "User") -split ';' | Where-Object { $_ -and $_ -ne $dir }) -join ';'
  [Environment]::SetEnvironmentVariable("Path", $path, "User")
  ```
- **Man page and completions** — only present if you copied them per the
  section above (or via Homebrew/Nix, which remove them with the
  package). Delete the copied files from `~/.local/share/man/man1/` and
  your completion directories.
- **Your data** — stores are per-project in each project's
  `.agent-store/` directory (`init` adds an `.agent-store/` line to the
  project's `.gitignore`, which you can delete). Apart from the crontab
  entries above, there is no global state, config, or cache. Removing the
  binary loses no data, and
  deleting a project's `.agent-store/` deletes that project's records —
  export first with `agent-store find --json | jq -c '.records[]'` if
  you want a backup (see [JSON output and import](json.md)).
- **`init` artifacts** — in projects where you ran `init`: skill files
  under `.agents/skills/` and `.claude/skills/` (the three
  `agent-store*` directories in each), and a managed block in
  `AGENTS.md`/`CLAUDE.md` between `<!-- agent-store:start -->` and
  `<!-- agent-store:end -->` markers. Delete those skill directories and
  the marked block to fully remove them; this leaves empty
  `.agents/skills/` and `.claude/skills/` directories (and possibly
  `.agents/` and `.claude/`), which you can remove too.

Installed? Next: [Using agent-store with Claude Code](claude-code.md) —
the end-to-end workflow the install exists for.
