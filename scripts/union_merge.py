"""Resolve merge conflicts in list-like files by keeping both sides.

For files where both branches only add lines, such as the root README's image table or a list of ADRs, the right
resolution is "keep ours, then theirs, without duplicates". Refuses files that have no conflict markers and leaves
anything else alone.

    uv run python scripts/union_merge.py README.md docs/adr/README.md && git add README.md docs/adr/README.md
"""

from __future__ import annotations

import sys
from pathlib import Path

START, MIDDLE, END = "<<<<<<< ", "=======", ">>>>>>> "


def union(text: str) -> tuple[str, int]:
    """The text with every conflict replaced by ours followed by the new lines of theirs, and the conflict count."""
    out: list[str] = []
    ours: list[str] = []
    theirs: list[str] = []
    state = "outside"
    conflicts = 0
    for line in text.splitlines(keepends=True):
        bare = line.rstrip("\r\n")
        if state == "outside" and bare.startswith(START):
            state, ours, theirs = "ours", [], []
        elif state == "ours" and bare.startswith("||||||| "):
            state = "base"
        elif state in {"ours", "base"} and bare == MIDDLE:
            state = "theirs"
        elif state == "theirs" and bare.startswith(END):
            seen = {o.rstrip("\r\n") for o in ours}
            out += ours + [t for t in theirs if t.rstrip("\r\n") not in seen]
            state = "outside"
            conflicts += 1
        elif state == "ours":
            ours.append(line)
        elif state == "theirs":
            theirs.append(line)
        elif state == "outside":
            out.append(line)
    if state != "outside":
        raise ValueError("unterminated conflict marker")
    return "".join(out), conflicts


def main(argv: list[str] | None = None) -> int:
    paths = argv if argv is not None else sys.argv[1:]
    if not paths:
        print("usage: union_merge.py FILE...", file=sys.stderr)
        return 2
    status = 0
    for name in paths:
        path = Path(name)
        text, count = union(path.read_text(encoding="utf-8"))
        if not count:
            print(f"{name}: no conflicts, left unchanged", file=sys.stderr)
            status = 1
            continue
        path.write_text(text, encoding="utf-8")
        print(f"{name}: resolved {count} conflict(s) by keeping both sides")
    return status


if __name__ == "__main__":
    sys.exit(main())
