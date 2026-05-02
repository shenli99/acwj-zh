# Navigation Short Titles Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace numeric tutorial nav labels with short topic titles so the docs sidebar is informative on desktop and mobile.

**Architecture:** Keep MkDocs navigation static and explicit. Update the tutorial entries in `mkdocs.yml` to use curated short labels, then verify the built site no longer renders the old `第 xx 部分` labels in the sidebar.

**Tech Stack:** MkDocs, Material for MkDocs, YAML, shell regression checks

---

### Task 1: Add a failing nav label regression check

**Files:**
- Create: `tools/check_nav_short_titles.sh`

**Step 1: Write the failing test**

Create a shell check that inspects `site/index.html` and verifies:
- tutorial labels like `第 01 部分`, `第 35 部分`, `第 64 部分` are absent
- replacement labels like `词法扫描`, `预处理器`, `8 位自编译` are present

**Step 2: Run test to verify it fails**

Run: `mkdocs build --strict && bash tools/check_nav_short_titles.sh`
Expected: FAIL because the current site still uses numeric nav labels.

**Step 3: Write minimal implementation**

No implementation in this task.

**Step 4: Run test to verify it still fails for the right reason**

Run: `bash tools/check_nav_short_titles.sh`
Expected: FAIL with a message about the old nav labels still being present.

**Step 5: Commit**

```bash
git add tools/check_nav_short_titles.sh
git commit -m "test: cover docs nav short titles"
```

### Task 2: Replace tutorial labels in `mkdocs.yml`

**Files:**
- Modify: `mkdocs.yml`
- Test: `tools/check_nav_short_titles.sh`

**Step 1: Write the failing test**

Use the existing red check from Task 1.

**Step 2: Run test to verify it fails**

Run: `bash tools/check_nav_short_titles.sh`
Expected: FAIL before changing the nav labels.

**Step 3: Write minimal implementation**

Replace `第 00 部分` through `第 64 部分` with curated short titles derived from each document's current chapter heading.

**Step 4: Run test to verify it passes**

Run: `mkdocs build --strict && bash tools/check_nav_short_titles.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add mkdocs.yml tools/check_nav_short_titles.sh
git commit -m "feat: shorten docs navigation titles"
```

### Task 3: Run full verification

**Files:**
- Test: `tools/check_nav_short_titles.sh`
- Test: `tools/check_mobile_nav.sh`
- Test: `tools/check_homepage_links.sh`
- Test: `tools/check_browser_compat_notice.sh`

**Step 1: Write the failing test**

No additional test file is needed.

**Step 2: Run test to verify final behavior**

Run: `mkdocs build --strict`
Expected: PASS

Run: `bash tools/check_nav_short_titles.sh`
Expected: PASS

Run: `bash tools/check_mobile_nav.sh`
Expected: PASS

Run: `bash tools/check_homepage_links.sh`
Expected: PASS

Run: `bash tools/check_browser_compat_notice.sh`
Expected: PASS

**Step 3: Write minimal implementation**

None.

**Step 4: Run test to verify it passes**

Same commands as above.

**Step 5: Commit**

```bash
git add mkdocs.yml tools/check_nav_short_titles.sh
git commit -m "chore: verify docs nav short titles"
```
