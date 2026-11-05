"""Tests for scripts/coverage_gaps.py. All offline."""

from __future__ import annotations

import json
from pathlib import Path

import coverage_gaps as cg
import pytest

SOURCE = """import sys


class Thing:
    def method(self):
        a = 1
        b = 2
        return a + b


def helper():
    return 1


x = 1
"""


def coverage(missing: list[int], percent: str = "60") -> dict:
    return {
        "files": {
            "scripts/demo.py": {"missing_lines": missing, "summary": {"percent_covered_display": percent}},
            "scripts/full.py": {"missing_lines": [], "summary": {"percent_covered_display": "100"}},
        },
        "totals": {"percent_covered_display": "97"},
    }


@pytest.mark.parametrize(
    ("lines", "expected"),
    [([], []), ([4], [(4, 4)]), ([1, 2, 3, 7, 9, 10], [(1, 3), (7, 7), (9, 10)]), ([3, 1, 2], [(1, 3)])],
    ids=["empty", "one", "several", "unsorted"],
)
def test_ranges(lines: list[int], expected: list[tuple[int, int]]) -> None:
    assert cg.ranges(lines) == expected


def test_enclosing_names_are_innermost_and_qualified() -> None:
    names = cg.enclosing_names(SOURCE)
    assert names[6] == "Thing.method" and names[12] == "helper" and 15 not in names


def test_report_lists_ranges_with_their_function_and_code(tmp_path: Path) -> None:
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "demo.py").write_text(SOURCE, encoding="utf-8")
    text = cg.report(coverage([6, 7, 8, 12, 15]), root=tmp_path, code_lines=2)
    assert text.splitlines() == [
        "## scripts/demo.py 60%",
        "- 6-8 in Thing.method:",
        "            a = 1",
        "            b = 2",
        "- 12 in helper:",
        "        return 1",
        "- 15 in module level:",
        "    x = 1",
        "Total: 97%",
    ]


def test_report_says_when_everything_is_covered(tmp_path: Path) -> None:
    assert cg.report(coverage([]), root=tmp_path) == "Everything is covered. Total: 97%"


def test_main_reads_the_json(tmp_path: Path, capsys, monkeypatch) -> None:
    path = tmp_path / "coverage.json"
    path.write_text(json.dumps(coverage([])), encoding="utf-8")
    assert cg.main(["--json", str(path)]) == 0
    assert "Everything is covered" in capsys.readouterr().out


def test_main_explains_a_missing_json(tmp_path: Path, capsys) -> None:
    assert cg.main(["--json", str(tmp_path / "nope.json")]) == 2
    assert "--cov-report=json" in capsys.readouterr().err
