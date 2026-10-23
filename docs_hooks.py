"""mkdocs build hook (wired via mkdocs.yml `hooks:`).

The README pins its images (logo <picture> srcsets, demo GIFs) to
raw.githubusercontent.com/…/master/ URLs so they render on crates.io.
On the docs site those are an external dependency and can serve stale
content between a push and the raw-CDN cache refresh — while docs.yml
already stages assets/ into the site itself. Rewrite img src/srcset
attributes to the local copies at build time. <pre>/<code> regions are
skipped entirely (Python-Markdown does not escape quotes there, so a
literal `src="…"` in a code sample must stay untouched), which also
keeps the install.sh curl commands intact. README.md itself stays
unchanged for GitHub and crates.io.

Transcript blocks (lines starting with "$ ") get a data-copy attribute
holding only their commands, which Material's copy button copies instead
of the block text, so a pasted transcript runs without prompts or output.

Relative links to shell scripts (examples/*.sh) point at the GitHub file
view instead: the site serves .sh files as downloads.
"""

from html import escape, unescape
import posixpath
import re

_RAW_PREFIX = "https://raw.githubusercontent.com/av/agent-store/master/assets/"
# Whole double-quoted src/srcset attribute (not data-src etc.); the full
# value is rewritten so multi-URL srcsets get every candidate replaced.
_ATTR_RE = re.compile(r'(?<![\w-])(src|srcset)="([^"]*)"')
# Code regions to leave untouched. Non-greedy to the matching close tag;
# Material's <pre><code> nesting is covered because the outer <pre> match
# swallows the inner <code>.
_CODE_RE = re.compile(r"<(pre|code)\b.*?</\1>", re.S | re.I)
_PRE_RE = re.compile(r"<pre>(.*?)</pre>", re.S)
_SH_HREF_RE = re.compile(r'href="(?![a-z]+:|/|#)([^"#?]+\.sh)"')
_BLOB = "https://github.com/av/agent-store/blob/master/"
_TAG_RE = re.compile(r"<[^>]+>")


def _transcript_commands(pre_inner):
    """Commands of a "$ " transcript (with "\\" continuations), or None."""
    lines = unescape(_TAG_RE.sub("", pre_inner)).split("\n")
    if not any(line.startswith("$ ") for line in lines):
        return None
    commands = []
    continued = False
    for line in lines:
        if continued:
            commands.append(line)
        elif line.startswith("$ "):
            commands.append(line[2:])
        else:
            continue
        continued = line.endswith("\\")
    return "\n".join(commands)


def _add_copy_text(html_text):
    def add(m):
        commands = _transcript_commands(m.group(1))
        if commands is None:
            return m.group(0)
        return f'<pre data-copy="{escape(commands)}">{m.group(1)}</pre>'

    return _PRE_RE.sub(add, html_text)


def _link_scripts_to_github(html_text, page_url):
    # Static files keep their repo path in the site, so the link target's
    # site path is its repo path.
    page_dir = page_url
    if page_url and not page_url.endswith("/"):
        page_dir = posixpath.dirname(page_url) + "/"

    def link(m):
        path = posixpath.normpath(posixpath.join(page_dir, m.group(1)))
        return f'href="{_BLOB}{path}"'

    return _SH_HREF_RE.sub(link, html_text)


def on_page_content(html, page, config, files):
    # Depth-aware relative prefix (README renders at the site root, so this
    # is just "assets/" there, but stays correct for any nested page).
    depth = page.url.count("/")
    local = "../" * depth + "assets/"

    def rewrite_attrs(chunk):
        return _ATTR_RE.sub(
            lambda m: f'{m.group(1)}="{m.group(2).replace(_RAW_PREFIX, local)}"',
            chunk,
        )

    out = []
    last = 0
    for m in _CODE_RE.finditer(html):
        out.append(rewrite_attrs(html[last : m.start()]))
        out.append(m.group(0))
        last = m.end()
    out.append(rewrite_attrs(html[last:]))
    return _link_scripts_to_github(_add_copy_text("".join(out)), page.url)
