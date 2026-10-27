#!/usr/bin/env python3
"""Refresh the collapsed "Skills brief" table in README.md from each
SKILL.md frontmatter. Called by sync.sh save, so it never goes stale."""
import glob
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
readme = os.path.join(root, "README.md")
listing = os.path.join(root, "pi", "skills.txt")
START, END = "<!-- skills-brief:start -->", "<!-- skills-brief:end -->"
CAP = 190


def skill_md(name, pi):
    for p in (
        os.path.join(root, "library", "skills", name, "SKILL.md"),
        os.path.join(pi, "skills", name, "SKILL.md"),
    ):
        if os.path.exists(p):
            return p
    hits = sorted(glob.glob(os.path.join(root, "library", "skills", name, "*", "SKILL.md")))
    return hits[0] if hits else None


def description(path):
    if not path:
        return "—"
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    front = m.group(1) if m else ""
    m = re.search(r"^description:[ \t]*(.*(?:\n[ \t]+.*)*)", front, re.M)
    raw = m.group(1) if m else ""
    raw = re.sub(r"^[>|][-+]?[ \t]*", "", raw.strip())          # folded/literal block
    raw = re.sub(r"\s+", " ", raw).strip().strip("\"'")
    if len(raw) > CAP:
        cut = raw[:CAP]
        raw = cut[: cut.rfind(" ")] + "…" if " " in cut[CAP // 2:] else cut + "…"
    return raw.replace("|", "\\|") or "—"


def main():
    pi = os.environ.get("PI_AGENT_DIR", os.path.expanduser("~/.pi/agent"))
    with open(listing, encoding="utf-8") as f:
        names = [ln.strip() for ln in f if ln.strip()]
    rows = [f"| `{n}` | {description(skill_md(n, pi))} |" for n in names]
    block = "\n".join(
        [
            START,
            "## Skills brief",
            "",
            "<details>",
            f"<summary><b>Skills brief</b> — {len(rows)} skills, one line each</summary>",
            "",
            "| Skill | What it does |",
            "| --- | --- |",
            *rows,
            "",
            "</details>",
            END,
        ]
    )
    with open(readme, encoding="utf-8") as f:
        doc = f.read()
    if START in doc and END in doc:
        doc = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda _: block, doc, flags=re.S)
    else:
        doc = doc.rstrip("\n") + "\n\n" + block + "\n"
    with open(readme, "w", encoding="utf-8") as f:
        f.write(doc)


main()
