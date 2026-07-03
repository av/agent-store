# Release notes template

Maintainer template for the notes attached to each GitHub release. The release
itself (with binaries and `.sha256` files) is created automatically by
[`release.yml`](workflows/release.yml) when a `v*` tag is pushed; edit the
release afterwards and paste in the filled-out template below.

Process:

1. Update `CHANGELOG.md` (move Unreleased items under the new version) and bump
   the version in `Cargo.toml`; commit, tag `vX.Y.Z`, and push the tag.
2. Wait for the Release workflow to finish (binaries, checksums, provenance
   attestations, crates.io publish and Homebrew tap bump if their secrets are
   configured).
3. Edit the release on GitHub, fill in the template, and use the
   **Generate release notes** button (or `gh release edit vX.Y.Z --notes-file ...`
   after `gh api ... --method POST /repos/av/agent-store/releases/generate-notes`)
   for the "What's Changed" section — categories come from
   [`.github/release.yml`](release.yml).

Replace every `X.Y.Z` / `A.B.C` (previous version) below.

---

## Highlights

<!-- 2-4 bullets: the changes a user actually cares about, in plain language.
     Pull from CHANGELOG.md; link docs/ pages where relevant. -->

- ...

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/av/agent-store/master/install.sh | sh
```

Also available via `brew install av/tap/agent-store`, `nix run github:av/agent-store`,
`cargo binstall --git https://github.com/av/agent-store agent-store`, or the
prebuilt archives below — see the [install matrix](https://github.com/av/agent-store#install).

## Verifying downloads

Each asset has a matching `.sha256` file and a signed [build provenance
attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations):

```sh
tag=vX.Y.Z
asset=agent-store-$tag-x86_64-unknown-linux-gnu.tar.gz
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/$asset"
curl -fsSLO "https://github.com/av/agent-store/releases/download/$tag/$asset.sha256"
sha256sum -c "$asset.sha256"   # macOS: shasum -a 256 -c "$asset.sha256"
gh attestation verify "$asset" --repo av/agent-store
```

## What's Changed

<!-- Auto-generated: "Generate release notes" button or
     `gh release create/edit --generate-notes`. Categories are configured in
     .github/release.yml. Trim noise; keep first-time contributor credits. -->

**Full Changelog**: https://github.com/av/agent-store/compare/vA.B.C...vX.Y.Z
(and the curated [CHANGELOG.md](https://github.com/av/agent-store/blob/master/CHANGELOG.md))
