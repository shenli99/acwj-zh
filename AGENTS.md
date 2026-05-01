# AGENTS.md

## Purpose

This repository is primarily a chapter-by-chapter compiler tutorial. Most user-facing prose lives in Markdown documents, while the code examples are embedded in those documents or stored in the per-chapter source trees.

## Working Rules

- Prefer changing documentation before touching source code unless the user explicitly asks for code changes.
- Preserve the repository's chapter structure and relative links.
- Do not translate code, commands, file paths, variable names, function names, or other identifiers unless the user explicitly requests it.
- When translating prose, favor accurate Chinese wording with stable technical terminology.
- On first occurrence of a well-known compiler term, prefer `中文（English）` if the English name materially helps recognition.
- Keep image paths, fenced code blocks, and Markdown link targets unchanged.

## Repository Shape

- Top-level overview: `Readme.md`
- Chapter documents: `00_Introduction/Readme.md` through `64_6809_Target/Readme.md`
- Extra notes: `64_6809_Target/docs/NOTES.md`
- Planning docs: `docs/plans/`

## Verification

- Use `rg --files -g 'Readme.md' -g 'NOTES.md'` to enumerate the documentation corpus.
- Use `git diff --stat` and `git status --short --branch` before claiming completion.
- When checking translation residue, scan for obvious English-only prose but allow code snippets and canonical terms to remain in English.

## Worktree Note

- The preferred local worktree directory for this repository is `.worktrees/`.
- Keep worktree-related ignore rules in version control on the feature branch that owns the worktree setup.
