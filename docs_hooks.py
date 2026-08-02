"""mkdocs build hook (wired via mkdocs.yml `hooks:`).

The README pins its images (logo <picture> srcsets, demo GIFs) to
raw.githubusercontent.com/…/master/ URLs so they render on crates.io.
On the docs site those are an external dependency and can serve stale
content between a push and the raw-CDN cache refresh — while docs.yml
already stages assets/ into the site itself. Rewrite img src/srcset
attributes to the local copies at build time. Only src=/srcset=
attributes are touched, so the install.sh curl commands in code blocks
keep their raw URLs. README.md itself stays unchanged for GitHub and
crates.io.
"""

import re

_RAW_PREFIX = "https://raw.githubusercontent.com/av/agent-store/master/assets/"
_ATTR_RE = re.compile(r'\b(src|srcset)="' + re.escape(_RAW_PREFIX))


def on_page_content(html, page, config, files):
    # Depth-aware relative prefix (README renders at the site root, so this
    # is just "assets/" there, but stays correct for any nested page).
    depth = page.url.count("/")
    local = "../" * depth + "assets/"
    return _ATTR_RE.sub(lambda m: f'{m.group(1)}="{local}', html)
