"""Print only what the tests don't cover: for each script below 100%, the uncovered line ranges with the function they
are in and the first lines of code. Writing the missing tests then needs this, not the whole file.

    uv run pytest -q --cov --cov-report=json   # writes coverage.json
    uv run python scripts/coverage_gaps.py [--json coverage.json] [--lines 3]
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def ranges(lines: list[int]) -> list[tuple[int, int]]:
    """[1, 2, 3, 7, 9, 10] -> [(1, 3), (7, 7), (9, 10)]"""
    out: list[tuple[int, int]] = []
    for line in sorted(lines):
        if out and line == out[-1][1] + 1:
            out[-1] = (out[-1][0], line)
        else:
            out.append((line, line))
    return out


def enclosing_names(source: str) -> dict[int, str]:
    """Line number -> the innermost function or class (Class.method) that contains it."""
    names: dict[int, str] = {}

    def visit(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef):
                name = f"{prefix}{child.name}"
                for line in range(child.lineno, (child.end_lineno or child.lineno) + 1):
                    names[line] = name
                visit(child, f"{name}.")
            else:
                visit(child, prefix)

    visit(ast.parse(source), "")
    return names


def report(coverage: dict, root: Path = REPO_ROOT, code_lines: int = 3) -> str:
    out = []
    for name, data in sorted(coverage["files"].items()):
        missing = data.get("missing_lines") or []
        if not missing:
            continue
        path = root / name
        source = path.read_text(encoding="utf-8")
        text, names = source.splitlines(), enclosing_names(source)
        out.append(f"## {Path(name).as_posix()} {data['summary']['percent_covered_display']}%")
        for start, end in ranges(missing):
            where = names.get(start, "module level")
            span = f"{start}" if start == end else f"{start}-{end}"
            out.append(f"- {span} in {where}:")
            out += [f"    {text[i - 1].rstrip()}" for i in range(start, min(end, start + code_lines - 1) + 1)]
    totals = coverage["totals"]["percent_covered_display"]
    return "\n".join(out + [f"Total: {totals}%"]) if out else f"Everything is covered. Total: {totals}%"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", type=Path, default=REPO_ROOT / "coverage.json")
    parser.add_argument("--lines", type=int, default=3, help="lines of code to show per uncovered range")
    args = parser.parse_args(argv)
    if not args.json.is_file():
        print(f"{args.json} not found: run `uv run pytest -q --cov --cov-report=json` first", file=sys.stderr)
        return 2
    print(report(json.loads(args.json.read_text(encoding="utf-8")), code_lines=args.lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
