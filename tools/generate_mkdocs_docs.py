#!/usr/bin/env python3

from __future__ import annotations

import re
import shutil
from os.path import relpath
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
PLANS = DOCS / "plans"

CHAPTER_RE = re.compile(r"^\d\d_")
LINK_RE = re.compile(r'!?\[[^\]]*\]\(([^)]+)\)')


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def safe_remove(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        shutil.rmtree(path)


def rel_symlink(src: Path, dest: Path) -> None:
    ensure_parent(dest)
    safe_remove(dest)
    dest.symlink_to(relpath(src, start=dest.parent))


def iter_markdown_links(md_text: str) -> list[str]:
    links: list[str] = []
    for match in LINK_RE.finditer(md_text):
        raw = match.group(1).strip()
        if not raw:
            continue
        target = raw.split()[0]
        target = target.split("#", 1)[0]
        if not target:
            continue
        if re.match(r"^(?:https?|ftp|mailto):", target):
            continue
        links.append(target)
    return links


def link_markdown_and_assets(src_md: Path, dest_md: Path) -> None:
    rel_symlink(src_md, dest_md)

    try:
        text = src_md.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = src_md.read_text()

    for target in iter_markdown_links(text):
        src_target = (src_md.parent / target).resolve()
        if not src_target.exists():
            continue
        dest_target = (dest_md.parent / target).resolve()
        if src_target.is_dir():
            continue
        if dest_target.exists() or dest_target.is_symlink():
            continue
        rel_symlink(src_target, dest_target)


def main() -> None:
    DOCS.mkdir(exist_ok=True)
    PLANS.mkdir(exist_ok=True)

    for child in ROOT.iterdir():
        if child.name in {"docs", "site", "tools", ".git"}:
            continue
        if CHAPTER_RE.match(child.name) and child.is_dir():
            safe_remove(DOCS / child.name)

    safe_remove(DOCS / "index.md")

    link_markdown_and_assets(ROOT / "Readme.md", DOCS / "index.md")

    chapter_dirs = sorted(
        path for path in ROOT.iterdir() if path.is_dir() and CHAPTER_RE.match(path.name)
    )

    for chapter in chapter_dirs:
        src_md = chapter / "Readme.md"
        if src_md.exists():
            link_markdown_and_assets(src_md, DOCS / chapter.name / "Readme.md")

    notes = ROOT / "64_6809_Target" / "docs" / "NOTES.md"
    if notes.exists():
        link_markdown_and_assets(notes, DOCS / "64_6809_Target" / "docs" / "NOTES.md")


if __name__ == "__main__":
    main()
