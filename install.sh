#!/bin/sh
# agent-store installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/av/agent-store/master/install.sh | sh
#
# Environment variables:
#   AGENT_STORE_VERSION  Tag to install (e.g. v0.1.0). Default: latest release.
#   AGENT_STORE_INSTALL_DIR  Install directory. Default: ~/.local/bin,
#                            falling back to /usr/local/bin (with sudo).
#   INSTALL_DRY_RUN=1    Print what would be downloaded/installed and exit
#                        before any network access.

set -eu

REPO="av/agent-store"
BIN="agent-store"

err() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            case "$arch" in
                x86_64 | amd64) echo "x86_64-unknown-linux-musl" ;;
                *) err "unsupported Linux architecture: $arch (prebuilt binaries: x86_64 only; use 'cargo install --git https://github.com/$REPO')" ;;
            esac
            ;;
        Darwin)
            case "$arch" in
                x86_64) echo "x86_64-apple-darwin" ;;
                arm64 | aarch64) echo "aarch64-apple-darwin" ;;
                *) err "unsupported macOS architecture: $arch" ;;
            esac
            ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            err "on Windows, download agent-store-<tag>-x86_64-pc-windows-msvc.zip from https://github.com/$REPO/releases"
            ;;
        *)
            err "unsupported OS: $os (use 'cargo install --git https://github.com/$REPO')"
            ;;
    esac
}

latest_tag() {
    # Resolve the latest release tag via the GitHub redirect (no jq needed).
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
        err "could not reach github.com to resolve the latest release"
    tag=${url##*/}
    case "$tag" in
        v*) echo "$tag" ;;
        *) err "no published release found for $REPO (got: $url)" ;;
    esac
}

verify_checksum() {
    file=$1
    sumfile=$2
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$(dirname "$file")" && sha256sum -c "$(basename "$sumfile")") >/dev/null ||
            err "sha256 checksum verification failed for $(basename "$file")"
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$(dirname "$file")" && shasum -a 256 -c "$(basename "$sumfile")") >/dev/null ||
            err "sha256 checksum verification failed for $(basename "$file")"
    else
        printf 'warning: no sha256sum/shasum found; skipping checksum verification\n' >&2
    fi
}

main() {
    command -v curl >/dev/null 2>&1 || err "curl is required"
    command -v tar >/dev/null 2>&1 || err "tar is required"

    target=$(detect_target)

    if [ "${INSTALL_DRY_RUN:-0}" = "1" ]; then
        tag="${AGENT_STORE_VERSION:-<latest>}"
        asset="$BIN-$tag-$target.tar.gz"
        printf 'dry run: target=%s\n' "$target"
        printf 'dry run: would download https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$tag" "$asset"
        printf 'dry run: would verify %s.sha256 and install to %s\n' "$asset" "${AGENT_STORE_INSTALL_DIR:-$HOME/.local/bin}"
        exit 0
    fi

    tag="${AGENT_STORE_VERSION:-$(latest_tag)}"
    asset="$BIN-$tag-$target.tar.gz"
    base="https://github.com/$REPO/releases/download/$tag"

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    printf 'Downloading %s ...\n' "$asset"
    curl -fsSL -o "$tmpdir/$asset" "$base/$asset" ||
        err "download failed: $base/$asset"
    curl -fsSL -o "$tmpdir/$asset.sha256" "$base/$asset.sha256" ||
        err "download failed: $base/$asset.sha256"
    verify_checksum "$tmpdir/$asset" "$tmpdir/$asset.sha256"

    tar -xzf "$tmpdir/$asset" -C "$tmpdir"
    [ -f "$tmpdir/$BIN" ] || err "archive did not contain the '$BIN' binary"
    chmod +x "$tmpdir/$BIN"

    if [ -n "${AGENT_STORE_INSTALL_DIR:-}" ]; then
        dir="$AGENT_STORE_INSTALL_DIR"
        mkdir -p "$dir" || err "cannot create $dir"
        mv "$tmpdir/$BIN" "$dir/$BIN" || err "cannot write to $dir"
    else
        dir="$HOME/.local/bin"
        if mkdir -p "$dir" 2>/dev/null && mv "$tmpdir/$BIN" "$dir/$BIN" 2>/dev/null; then
            :
        else
            dir="/usr/local/bin"
            printf 'Installing to %s (requires sudo)\n' "$dir"
            sudo mv "$tmpdir/$BIN" "$dir/$BIN" || err "install failed"
        fi
    fi

    printf 'Installed %s %s to %s/%s\n' "$BIN" "$tag" "$dir" "$BIN"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *)
            printf '\nNote: %s is not on your PATH. Add it, e.g.:\n' "$dir"
            # shellcheck disable=SC2016
            printf '  export PATH="%s:$PATH"\n' "$dir"
            ;;
    esac
}

main "$@"
