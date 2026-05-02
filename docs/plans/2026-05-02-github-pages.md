# GitHub Pages Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an official GitHub Pages deployment workflow for the MkDocs documentation site so the project site can be published automatically from the `master` branch after this feature branch is merged.

**Architecture:** Keep the current MkDocs source layout and local build flow intact, but add repository metadata and CI configuration around it. The workflow will install a dedicated docs dependency set, build the site into `site/`, upload the artifact, and deploy it through GitHub’s Pages Actions pipeline.

**Tech Stack:** MkDocs, Material for MkDocs, Python, GitHub Actions, GitHub Pages

---

### Task 1: Add Pages-aware MkDocs metadata

**Files:**
- Modify: `mkdocs.yml`

**Step 1: Add project site URL**

Add:

```yaml
site_url: https://shenli99.github.io/acwj-zh/
```

**Step 2: Preserve existing local build behavior**

Do not change:

- `docs_dir`
- `site_dir`
- nav structure
- theme behavior

**Step 3: Verify local build still passes**

Run: `mkdocs build --strict`
Expected: exit 0

### Task 2: Add reproducible docs dependencies

**Files:**
- Create: `requirements-docs.txt`

**Step 1: Add minimal build dependencies**

Include the packages required for CI to build the site:

- `mkdocs`
- `mkdocs-material`
- `pymdown-extensions`

**Step 2: Keep the file scoped**

Do not add unrelated runtime or development tooling.

### Task 3: Add the GitHub Pages workflow

**Files:**
- Create: `.github/workflows/pages.yml`

**Step 1: Configure triggers**

Trigger on:

- pushes to `master`
- manual `workflow_dispatch`

**Step 2: Configure permissions and concurrency**

Add the minimum required permissions and a concurrency group for Pages deployment.

**Step 3: Add build and deploy jobs**

The workflow should:

- check out the repo
- configure Pages
- set up Python
- install `requirements-docs.txt`
- run `mkdocs build --strict`
- upload `site/`
- deploy via `actions/deploy-pages`

### Task 4: Verify the Pages setup locally

**Files:**
- Verify generated output only

**Step 1: Run strict MkDocs build**

Run: `mkdocs build --strict`
Expected: exit 0

**Step 2: Run homepage regression check**

Run: `bash tools/check_homepage_links.sh`
Expected: `homepage links look good`

**Step 3: Review workflow and dependency diff**

Run:

```bash
git diff -- mkdocs.yml requirements-docs.txt .github/workflows/pages.yml
```

Expected: only Pages-related configuration changes

### Task 5: Commit the Pages setup

**Files:**
- Add: `mkdocs.yml`
- Add: `requirements-docs.txt`
- Add: `.github/workflows/pages.yml`
- Add: `docs/plans/2026-05-02-github-pages-design.md`
- Add: `docs/plans/2026-05-02-github-pages.md`

**Step 1: Stage only Pages-related files**

```bash
git add mkdocs.yml requirements-docs.txt .github/workflows/pages.yml docs/plans/2026-05-02-github-pages-design.md docs/plans/2026-05-02-github-pages.md
```

**Step 2: Commit**

```bash
git commit -m "docs: add github pages deployment"
```

Expected: one reviewable commit containing the Pages deployment setup
