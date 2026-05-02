# Via Compatibility Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add conservative CSS fallbacks and a compatibility notice so older mobile browsers can still use the docs navigation or see a clear warning.

**Architecture:** Keep Material's navigation structure unchanged. Add fallback-first CSS in the custom stylesheet, then layer modern visual effects behind `@supports`. Add a small runtime feature check in the theme override to show a dismissible warning only when key CSS features are unsupported.

**Tech Stack:** MkDocs, Material for MkDocs, Jinja theme override, CSS, vanilla JavaScript, shell regression checks

---

### Task 1: Add a failing compatibility regression check

**Files:**
- Create: `tools/check_browser_compat_notice.sh`

**Step 1: Write the failing test**

Create a shell check that inspects:
- `site/index.html` for a compatibility notice container and feature-detection script marker
- `site/stylesheets/extra.css` for a fallback marker or `@supports` block

**Step 2: Run test to verify it fails**

Run: `mkdocs build --strict && bash tools/check_browser_compat_notice.sh`
Expected: FAIL because the current site has no compatibility notice or fallback markers yet.

**Step 3: Write minimal implementation**

No implementation in this task.

**Step 4: Run test to verify it still fails for the right reason**

Run: `bash tools/check_browser_compat_notice.sh`
Expected: FAIL with a missing compatibility marker message.

**Step 5: Commit**

```bash
git add tools/check_browser_compat_notice.sh
git commit -m "test: cover browser compatibility notice"
```

### Task 2: Add fallback-first CSS

**Files:**
- Modify: `docs/stylesheets/extra.css`
- Test: `tools/check_browser_compat_notice.sh`

**Step 1: Write the failing test**

The compatibility check from Task 1 is already red.

**Step 2: Run test to verify it fails**

Run: `bash tools/check_browser_compat_notice.sh`
Expected: FAIL before CSS fallback markers are added.

**Step 3: Write minimal implementation**

Add plain-color fallback values for custom backgrounds and header styling, then re-enable `color-mix()` and `backdrop-filter` only inside `@supports` blocks.

**Step 4: Run test to verify partial progress**

Run: `mkdocs build --strict && bash tools/check_browser_compat_notice.sh`
Expected: Still FAIL until the runtime notice exists, or PASS the CSS portion if the script checks separately.

**Step 5: Commit**

```bash
git add docs/stylesheets/extra.css
git commit -m "style: add browser-compatible docs fallbacks"
```

### Task 3: Add runtime compatibility notice

**Files:**
- Modify: `overrides/main.html`
- Modify: `docs/stylesheets/extra.css`
- Test: `tools/check_browser_compat_notice.sh`

**Step 1: Write the failing test**

The compatibility check is still red because `site/index.html` lacks the notice markup or feature-detection marker.

**Step 2: Run test to verify it fails**

Run: `bash tools/check_browser_compat_notice.sh`
Expected: FAIL with a message about the missing notice marker.

**Step 3: Write minimal implementation**

Inject a hidden, dismissible notice container plus a small script that:
- checks support for `color-mix()` and `backdrop-filter`
- shows the notice only when either feature is unsupported
- lets the user dismiss the notice for the session

**Step 4: Run test to verify it passes**

Run: `mkdocs build --strict && bash tools/check_browser_compat_notice.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add overrides/main.html docs/stylesheets/extra.css tools/check_browser_compat_notice.sh
git commit -m "fix: add browser compatibility notice"
```

### Task 4: Run full verification

**Files:**
- Test: `tools/check_mobile_nav.sh`
- Test: `tools/check_homepage_links.sh`
- Test: `tools/check_browser_compat_notice.sh`

**Step 1: Write the failing test**

No new test file needed; use the existing verification commands.

**Step 2: Run test to verify final behavior**

Run: `mkdocs build --strict`
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
git add docs/stylesheets/extra.css overrides/main.html tools/check_browser_compat_notice.sh
git commit -m "chore: verify browser compatibility fallback"
```
