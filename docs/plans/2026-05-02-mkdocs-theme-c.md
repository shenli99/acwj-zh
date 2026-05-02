# MkDocs Theme C Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the tutorial site from the A-theme baseline to a more intentional C-theme version with official automatic color-scheme detection, syntax-highlighted code blocks, and a stronger tutorial landing experience.

**Architecture:** Keep the current `docs/` symlink mirror and explicit MkDocs navigation, but extend Material for MkDocs with official palette and markdown extension settings plus a shallow `overrides/` template layer. Use a single stylesheet to coordinate homepage hero modules, chapter cards, navigation polish, and mobile behavior.

**Tech Stack:** MkDocs 1.6.x, Material for MkDocs, Python Markdown extensions, YAML, Jinja templates, CSS

---

### Task 1: Enable official automatic theme selection and code highlighting

**Files:**
- Modify: `mkdocs.yml`

**Step 1: Update palette to support system preference**

Replace the current two-palette toggle with the official three-entry `media` form:

- `(prefers-color-scheme)`
- `(prefers-color-scheme: light)`
- `(prefers-color-scheme: dark)`

**Step 2: Add syntax-highlighting markdown extensions**

Enable:

```yaml
markdown_extensions:
  - pymdownx.highlight:
      anchor_linenums: true
      line_spans: __span
      pygments_lang_class: true
  - pymdownx.inlinehilite
  - pymdownx.snippets
  - pymdownx.superfences
```

**Step 3: Run a strict build**

Run: `mkdocs build --strict`
Expected: build succeeds with the updated configuration

### Task 2: Add shallow template overrides for the homepage

**Files:**
- Modify: `mkdocs.yml`
- Create: `overrides/main.html`

**Step 1: Register the custom template directory**

Add:

```yaml
theme:
  custom_dir: overrides
```

**Step 2: Extend the Material page template**

Create a small override that:

- extends the upstream page template
- detects the homepage
- injects a hero/introduction area before the normal page content
- renders grouped chapter quick-links and an appendix shortcut

**Step 3: Keep documentation content intact**

Ensure the original `Readme.md` content still renders underneath the new homepage modules.

### Task 3: Upgrade the visual system for C

**Files:**
- Modify: `docs/stylesheets/extra.css`

**Step 1: Add homepage-specific styles**

Style:

- hero block
- chapter card grid
- appendix entry
- responsive stacked layout for small screens

**Step 2: Tune code-block styling**

Adjust spacing and surfaces so highlighted code feels integrated in both light and dark modes.

**Step 3: Refine navigation treatment**

Improve nav affordances, section rhythm, and small-screen spacing without fighting Material defaults.

### Task 4: Verify the new tutorial entry experience

**Files:**
- Verify generated `site/` output only

**Step 1: Run strict build**

Run: `mkdocs build --strict`
Expected: exit 0

**Step 2: Inspect generated homepage output**

Confirm:

- hero block exists
- grouped chapter links exist
- appendix shortcut exists

**Step 3: Inspect generated code-block output**

Confirm rendered HTML includes syntax-highlighting classes or spans consistent with `pymdownx.highlight`.

**Step 4: Inspect theme palette output**

Confirm generated HTML contains palette entries for automatic mode and system-based light/dark variants.

### Task 5: Commit the C refresh

**Files:**
- Add: `mkdocs.yml`
- Add: `docs/stylesheets/extra.css`
- Add: `overrides/main.html`
- Add: `docs/plans/2026-05-02-mkdocs-theme-c-design.md`
- Add: `docs/plans/2026-05-02-mkdocs-theme-c.md`

**Step 1: Review the diff**

Run:

```bash
git diff -- mkdocs.yml docs/stylesheets/extra.css overrides/main.html docs/plans/2026-05-02-mkdocs-theme-c-design.md docs/plans/2026-05-02-mkdocs-theme-c.md
```

Expected: only theme C configuration, template, stylesheet, and plan/design docs are included

**Step 2: Commit**

```bash
git add mkdocs.yml docs/stylesheets/extra.css overrides/main.html docs/plans/2026-05-02-mkdocs-theme-c-design.md docs/plans/2026-05-02-mkdocs-theme-c.md
git commit -m "docs: refresh mkdocs theme c"
```

Expected: one reviewable commit containing the C-theme refresh
