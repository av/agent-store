# Brand assets

## Brand

The mark is square brackets enclosing two green nodes joined by a bar: a record
(bracket syntax, how the CLI prints records) containing a *link* — the thing
that makes agent-store a store of connected records rather than a flat log.
The brackets carry the "store/record" idea; the green link carries the
"connected" idea. The wordmark's hyphen is the same accent green so the lockup
reads as one system: two words joined by a link, two records joined by a link.

Distinctiveness notes (checked against common dev-tool marks): the two-node
connector alone would read as a generic git-branch/commit glyph, and brackets
alone as a generic "code" glyph — the enclosure of one inside the other is what
makes it ownable. Do not use either half by itself.

Which variant to use:

- `logo.svg` — default lockup anywhere that honors `prefers-color-scheme` (docs, websites you control).
- `logo-light.svg` / `logo-dark.svg` — contexts with an explicit theme toggle or no media-query support (GitHub README `<picture>`, embeds).
- `logo-mark.svg` — square contexts smaller than ~200 px where the wordmark would be illegible (favicons, avatars, app icons). This is also the `mkdocs.yml` `favicon:` — modern browsers render the SVG and pick the palette from `prefers-color-scheme`, so the tab icon is correct on both light and dark tab bars.
- `logo-mark-white.svg` — only on solid brand-green or other saturated backgrounds where the gray/green mark lacks contrast.

The three SVGs are the source of truth; every raster asset is generated from them.

| Asset | What it is | Used by |
|---|---|---|
| `logo.svg` | Full lockup: bracket mark + "agent-store" wordmark. 438x90 px (viewBox `0 0 350.4 72`). Dual-theme via `prefers-color-scheme`. | Docs / general use; source of the fixed-palette variants |
| `logo-light.svg` / `logo-dark.svg` | Same lockup with the light/dark palette baked in (no media query). GitHub ignores in-SVG `prefers-color-scheme` when the site theme is set explicitly and in the mobile apps, so the README uses the GitHub-native `<picture>` pattern with these. Regenerate both whenever `logo.svg` changes. | `README.md` header (`<picture>`, `width="438"`) |
| `logo-mark.svg` | Mark only, square. 128x128 px (viewBox `0 0 64 64`). Dual-theme. | Source for `favicon.png`, `favicon.ico` |
| `logo-mark-white.svg` | All-white mark for colored backgrounds. | `mkdocs.yml` docs-site header (renders on green) |
| `favicon.png` | 128x128 raster of the mark with the theme-neutral favicon palette baked in (see below). | Fallback for contexts that need a raster favicon |
| `favicon.ico` | Multi-size 16/32/48, same theme-neutral palette. | Served at `/assets/favicon.ico` on the docs site for older browsers |
| `social-preview.svg` / `social-preview.png` | 1280x640 dark card: lockup (dark palette baked in) + tagline + feature line on `#0d1117`. The SVG is the source (tagline text as paths, no font dependency); the PNG is its raster. | GitHub Settings > General > Social preview (manual upload — not read from the repo); also used by link unfurls (Slack/Discord/X) |
| `demo.sh` / `demo.gif` | Scripted README demo recording (init/create/find/set/ctx basics). | `README.md` header |
| `demo-hooks.sh` / `demo-hooks.gif` | Scripted demo of links, hooks firing on `set`, and `ctx`. Recipe in the script header (same asciinema + agg theme as `demo.sh`). | `README.md` Hooks section |

## Design notes

- Mark: square brackets (record syntax) enclosing a green two-node link.
- Palette: GitHub light/dark — ink `#1f2328`/`#f0f6fc`, soft gray `#59636e`/`#9198a1`, accent green `#1a7f37`/`#3fb950`; dark canvas `#0d1117` (social card, demo-GIF background) and muted `#6e7681` (social-card feature line). The dark values live in a `@media (prefers-color-scheme: dark)` block inside each themed SVG; keep those classes when editing (generic SVG minifiers strip them — see below).
- Wordmark: Noto Sans Mono wght=600, converted to paths with fontTools (no font dependency). The hyphen is a separate accent-green path.

## Regeneration

```sh
# favicon.png / favicon.ico — raster fallbacks. Rasterizing logo-mark.svg
# directly would freeze the light palette (dark-green link ~2:1 against a dark
# tab bar), so bake a theme-neutral palette first: brackets #6e7681 (muted
# token; ~4.6:1 on white, ~3.3:1 on #0d1117), link/nodes #2ea043 (mid green
# between the two accent tokens; raster-favicon-only, not for other assets).
sed -e 's/#59636e/#6e7681/' -e 's/#1a7f37/#2ea043/g' -e '/@media/d' \
  assets/logo-mark.svg > /tmp/favicon-neutral.svg
magick -background none -density 384 /tmp/favicon-neutral.svg -resize 128x128 assets/favicon.png
magick -background none /tmp/favicon-neutral.svg -define icon:auto-resize=48,32,16 assets/favicon.ico
# Verify: composite the 16/32 px rasters over both #0d1117 and white and look.

# social-preview.png from its SVG source (all geometry lives in the SVG)
magick -density 96 assets/social-preview.svg assets/social-preview.png
# social-preview.svg itself is composed by hand: the logo-dark.svg content
# (classes inlined) scaled to ~770px wide, plus two tagline lines converted
# to paths from Noto Sans Mono wght=400 with fontTools (same approach as the
# wordmark). If logo-dark.svg or the README tagline changes, re-compose it.
# Verify: view full card, a 1224x640 center crop (~1.91:1 unfurl crop), and
# a 600px-wide resize for small-preview legibility.

# demo.gif / demo-hooks.gif — recipe (asciinema + agg with the custom
# GitHub-dark theme) is documented in the headers of assets/demo.sh and
# assets/demo-hooks.sh. Record with the repo's current binary on PATH
# (cargo build --release; PATH="target/release:$PATH") — a stale installed
# agent-store silently changes the output. Both scripts print their first
# command instantly (no typing lead-in) so the GIF's opening frame shows
# content; keep that when editing, since README GIFs autoplay from frame 0.
```

Note on minification: `svgo` inlines the theme classes and drops the dark-mode
media query and `role="img"`. If you run it, restore the `<style>` block with
the `.ink`/`.soft`/`.accent`/`.link` classes and the `role` attribute, then
verify by rasterizing before/after with ImageMagick and `magick compare`.
