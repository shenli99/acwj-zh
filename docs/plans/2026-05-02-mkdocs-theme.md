# MkDocs Theme Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the tutorial site to a more polished Material-based theme with usable dark mode and better mobile reading ergonomics while keeping the current documentation structure intact.

**Architecture:** Reuse the existing generated `docs/` mirror and explicit navigation, but swap the site theme from default MkDocs to Material. Add a single custom stylesheet for typography, spacing, dark palette tuning, and small-screen behavior instead of introducing template or JavaScript customization.

**Tech Stack:** MkDocs 1.6.x, mkdocs-material, YAML, CSS

---

### Task 1: Switch the site theme to Material

**Files:**
- Modify: `mkdocs.yml`

**Step 1: Replace the base theme**

Update `mkdocs.yml` to use:

```yaml
theme:
  name: material
```

**Step 2: Configure tutorial-friendly features**

Enable the smallest useful set of Material features for this site, such as:

- navigation highlighting
- table of contents following
- top navigation usability
- code copy button
- back-to-top behavior

**Step 3: Add light and dark palettes**

Configure a default light palette and a dark palette toggle with readable contrast.

**Step 4: Run a build check**

Run: `mkdocs build --strict`
Expected: configuration loads and build succeeds or fails only on stylesheet references not yet added

### Task 2: Add the custom stylesheet

**Files:**
- Create: `docs/stylesheets/extra.css`
- Modify: `mkdocs.yml`

**Step 1: Register the stylesheet**

Add:

```yaml
extra_css:
  - stylesheets/extra.css
```

**Step 2: Implement typography and layout tuning**

Add styles for:

- narrower prose width
- more comfortable body line-height
- stronger heading rhythm
- cleaner list and blockquote spacing

**Step 3: Implement dark-mode tuning**

Adjust custom properties and key surfaces so dark mode has clearer text and code block contrast.

**Step 4: Implement mobile-specific rules**

Add breakpoints for:

- page padding
- heading size reduction
- code block overflow
- table overflow

### Task 3: Validate the refreshed site

**Files:**
- Verify site output only

**Step 1: Build the site**

Run: `mkdocs build --strict`
Expected: exit 0

**Step 2: Spot-check generated output**

Confirm the build still includes:

- homepage
- tutorial chapters
- appendix `NOTES.md`

**Step 3: Check that theme assets are wired**

Inspect `site/` output enough to confirm Material assets and custom stylesheet are present.

### Task 4: Commit the theme refresh

**Files:**
- Add: `mkdocs.yml`
- Add: `docs/stylesheets/extra.css`
- Add: `docs/plans/2026-05-02-mkdocs-theme-design.md`
- Add: `docs/plans/2026-05-02-mkdocs-theme.md`

**Step 1: Review the diff**

Run: `git diff -- mkdocs.yml docs/stylesheets/extra.css docs/plans/2026-05-02-mkdocs-theme-design.md docs/plans/2026-05-02-mkdocs-theme.md`
Expected: only theme refresh config, stylesheet, and plan/design docs are included

**Step 2: Commit**

```bash
git add mkdocs.yml docs/stylesheets/extra.css docs/plans/2026-05-02-mkdocs-theme-design.md docs/plans/2026-05-02-mkdocs-theme.md
git commit -m "docs: refresh mkdocs theme"
```

Expected: one reviewable commit containing the theme refresh
