# Brand assets

The three SVGs are the source of truth; every raster asset is generated from them.

| Asset | What it is | Used by |
|---|---|---|
| `logo.svg` | Full lockup: bracket mark + "agent-store" wordmark. 438x90 px (viewBox `0 0 350.4 72`). Dual-theme via `prefers-color-scheme`. | Docs / general use; source of the fixed-palette variants |
| `logo-light.svg` / `logo-dark.svg` | Same lockup with the light/dark palette baked in (no media query). GitHub ignores in-SVG `prefers-color-scheme` when the site theme is set explicitly and in the mobile apps, so the README uses the GitHub-native `<picture>` pattern with these. Regenerate both whenever `logo.svg` changes. | `README.md` header (`<picture>`, `width="438"`) |
| `logo-mark.svg` | Mark only, square. 128x128 px (viewBox `0 0 64 64`). Dual-theme. | Source for `favicon.png`, `favicon.ico` |
| `logo-mark-white.svg` | All-white mark for colored backgrounds. | `mkdocs.yml` docs-site header (renders on green) |
| `favicon.png` | 128x128 raster of `logo-mark.svg`. | `mkdocs.yml` `favicon:` |
| `favicon.ico` | Multi-size 16/32/48 for older browsers. | Served at `/assets/favicon.ico` on the docs site |
| `social-preview.svg` / `social-preview.png` | 1280x640 dark card: lockup (dark palette baked in) + tagline + feature line on `#0d1117`. The SVG is the source (tagline text as paths, no font dependency); the PNG is its raster. | GitHub Settings > General > Social preview (manual upload — not read from the repo); also used by link unfurls (Slack/Discord/X) |
| `demo.sh` / `demo.gif` | Scripted README demo recording (init/create/find/set/ctx basics). | `README.md` header |
| `demo-hooks.sh` / `demo-hooks.gif` | Scripted demo of links, hooks firing on `set`, and `ctx`. Recipe in the script header (same asciinema + agg theme as `demo.sh`). | `README.md` Hooks section |

## Design notes

- Mark: square brackets (record syntax) enclosing a green two-node link.
- Palette: GitHub light/dark — ink `#1f2328`/`#f0f6fc`, soft gray `#59636e`/`#9198a1`, accent green `#1a7f37`/`#3fb950`. The dark values live in a `@media (prefers-color-scheme: dark)` block inside each themed SVG; keep those classes when editing (generic SVG minifiers strip them — see below).
- Wordmark: Noto Sans Mono wght=600, converted to paths with fontTools (no font dependency). The hyphen is a separate accent-green path.

## Regeneration

```sh
# favicon.png / favicon.ico from the mark
magick -background none -density 384 assets/logo-mark.svg -resize 128x128 assets/favicon.png
magick -background none assets/logo-mark.svg -define icon:auto-resize=48,32,16 assets/favicon.ico

# social-preview.png from its SVG source (all geometry lives in the SVG)
magick -density 96 assets/social-preview.svg assets/social-preview.png
# social-preview.svg itself is composed by hand: the logo-dark.svg content
# (classes inlined) scaled to ~770px wide, plus two tagline lines converted
# to paths from Noto Sans Mono wght=400 with fontTools (same approach as the
# wordmark). If logo-dark.svg or the README tagline changes, re-compose it.
# Verify: view full card, a 1224x640 center crop (~1.91:1 unfurl crop), and
# a 600px-wide resize for small-preview legibility.

# demo.gif — recipe (asciinema + agg with the custom GitHub-dark theme)
# is documented in the header of assets/demo.sh
```

Note on minification: `svgo` inlines the theme classes and drops the dark-mode
media query and `role="img"`. If you run it, restore the `<style>` block with
the `.ink`/`.soft`/`.accent`/`.link` classes and the `role` attribute, then
verify by rasterizing before/after with ImageMagick and `magick compare`.
