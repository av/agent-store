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
"""

import re

_RAW_PREFIX = "https://raw.githubusercontent.com/av/agent-store/master/assets/"
# Whole double-quoted src/srcset attribute (not data-src etc.); the full
# value is rewritten so multi-URL srcsets get every candidate replaced.
_ATTR_RE = re.compile(r'(?<![\w-])(src|srcset)="([^"]*)"')
# Code regions to leave untouched. Non-greedy to the matching close tag;
# Material's <pre><code> nesting is covered because the outer <pre> match
# swallows the inner <code>.
_CODE_RE = re.compile(r"<(pre|code)\b.*?</\1>", re.S | re.I)


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
    return "".join(out)
