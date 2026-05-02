# MkDocs Site Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a minimal MkDocs site that renders the repository tutorial docs and includes the 6809 `NOTES.md` appendix without duplicating the Markdown source.

**Architecture:** Use a standard `docs/` directory for MkDocs input, but populate it with generated symlinks pointing at the existing tutorial Markdown and required asset files. Keep navigation explicit in `mkdocs.yml` so the site structure is stable and reviewable.

**Tech Stack:** MkDocs 1.6.x, YAML, Python 3, filesystem symlinks

---

### Task 1: Add design-time site config skeleton

**Files:**
- Create: `mkdocs.yml`

**Step 1: Create base MkDocs config**

Add:

```yaml
site_name: acwj
docs_dir: docs
site_dir: site
theme:
  name: mkdocs
nav:
  - 首页: index.md
```

**Step 2: Extend nav with tutorial chapters**

Add explicit entries for:

- `00_Introduction/Readme.md`
- through
- `64_6809_Target/Readme.md`
- plus `64_6809_Target/docs/NOTES.md`

**Step 3: Verify YAML parses**

Run: `mkdocs build --strict`
Expected: build may still fail because `docs/` content is not created yet, but YAML-specific parse errors must be gone

### Task 2: Add docs mirror generator

**Files:**
- Create: `tools/generate_mkdocs_docs.py`

**Step 1: Implement docs directory bootstrap**

The script should:

- create `docs/` if missing
- remove stale generated links/files it owns
- create `docs/index.md` linked to `Readme.md`

**Step 2: Implement chapter link generation**

For each chapter directory containing `Readme.md`, create matching directories under `docs/` and symlink the chapter `Readme.md`.

**Step 3: Include appendix resources**

Ensure:

- `docs/64_6809_Target/docs/NOTES.md` points to the original file
- required assets under `64_6809_Target/docs/` such as images/PDFs are linked so embedded references resolve

**Step 4: Run generator**

Run: `python3 tools/generate_mkdocs_docs.py`
Expected: `docs/` tree exists with homepage, chapter links, and appendix links

### Task 3: Validate generated site structure

**Files:**
- Verify generated `docs/` tree

**Step 1: Inspect generated paths**

Run:

```bash
find docs -maxdepth 3 | sort | sed -n '1,200p'
```

Expected: homepage, chapter subdirectories, and `64_6809_Target/docs/NOTES.md`

**Step 2: Spot-check symlink targets**

Run:

```bash
find docs -type l | sort | sed -n '1,120p'
```

Expected: generated links point back to original repository Markdown/assets

### Task 4: Build and verify the MkDocs site

**Files:**
- Verify site output only

**Step 1: Build the site**

Run: `mkdocs build --strict`
Expected: exit 0

**Step 2: Spot-check important pages**

Run:

```bash
mkdocs build --strict
```

Then verify generated files exist:

```bash
find site -maxdepth 3 | sort | sed -n '1,200p'
```

Expected: homepage, chapter pages, and appendix output exist

**Step 3: Check for obvious broken internal references**

Run targeted grep over generated HTML for unresolved `Readme.md` links if needed, or inspect a few key outputs manually from:

- `site/index.html`
- `site/00_Introduction/Readme/index.html` or matching chapter output
- `site/64_6809_Target/Readme/index.html` or matching chapter output
- `site/64_6809_Target/docs/NOTES/index.html` or matching appendix output

Expected: links resolve into the built site rather than raw source paths for the common navigation flow

### Task 5: Commit the MkDocs setup

**Files:**
- Add: `mkdocs.yml`
- Add: `tools/generate_mkdocs_docs.py`
- Add: generated `docs/` entries that should live in git

**Step 1: Review git diff**

Run: `git diff -- mkdocs.yml tools/generate_mkdocs_docs.py docs`
Expected: only MkDocs setup and generated docs mirror changes

**Step 2: Commit**

```bash
git add mkdocs.yml tools/generate_mkdocs_docs.py docs
git commit -m "docs: add mkdocs tutorial site"
```

Expected: one reviewable commit containing the initial MkDocs site setup
