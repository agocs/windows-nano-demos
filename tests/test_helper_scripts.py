"""Tests for the token-saving helper scripts: ci_triage, repo_status and union_merge. All offline."""

from __future__ import annotations

import json

import ci_triage
import pytest
import repo_status
import union_merge


class TestCiTriage:
    def test_failed_jobs_name_their_failing_step(self) -> None:
        jobs = [
            {"id": 1, "name": "ok", "conclusion": "success", "steps": []},
            {
                "id": 2,
                "name": "build (2019)",
                "conclusion": "failure",
                "steps": [{"name": "Build", "conclusion": "success"}, {"name": "Smoke test", "conclusion": "failure"}],
            },
        ]
        assert ci_triage.failed_jobs(jobs) == [
            {"id": 2, "name": "build (2019)", "conclusion": "failure", "step": "Smoke test"}
        ]

    def test_error_lines_keep_errors_and_the_tail_and_drop_noise(self) -> None:
        raw = [
            "build\tStep\t2026-11-05T12:00:00.0000000Z ##[group]Run thing",
            "build\tStep\t2026-11-05T12:00:01.0000000Z downloading 100%",
            "build\tStep\t2026-11-05T12:00:02.0000000Z error obtaining VCS status: exit status 128",
            "build\tStep\t2026-11-05T12:00:03.0000000Z ##[warning]Node.js 20 is deprecated",
            "build\tStep\t2026-11-05T12:00:04.0000000Z ##[error]Process completed with exit code 1.",
        ]
        log = "\n".join(raw)
        lines = ci_triage.error_lines(log, tail=1)
        assert lines == ["error obtaining VCS status: exit status 128", "##[error]Process completed with exit code 1."]

    def test_pr_mode_finds_the_failed_runs(self) -> None:
        checks = [
            {"state": "FAILURE", "link": "https://github.com/o/r/actions/runs/42/job/1"},
            {"state": "SUCCESS", "link": "https://github.com/o/r/actions/runs/43/job/2"},
            {"state": "FAILURE", "link": "https://github.com/o/r/actions/runs/42/job/3"},
        ]
        assert ci_triage.runs_for_pr(7, lambda args: json.dumps(checks)) == [42]


class TestRepoStatus:
    def test_check_summary(self) -> None:
        rollup = [{"conclusion": "SUCCESS"}, {"conclusion": "FAILURE"}, {"status": "IN_PROGRESS"}, {"state": "PENDING"}]
        assert repo_status.summarize_checks(rollup) == "1 fail, 1 pass, 2 pending"
        assert repo_status.summarize_checks([]) == "no checks"

    def test_worktree_parsing(self) -> None:
        porcelain = "worktree /a\nHEAD 1\nbranch refs/heads/main\n\nworktree /b\nHEAD 2\ndetached\nlocked\n"
        trees = repo_status.parse_worktrees(porcelain)
        assert trees[0]["branch"] == "refs/heads/main"
        assert trees[1]["detached"] == "yes" and trees[1]["locked"] == "yes"

    def test_a_failing_section_does_not_stop_the_others(self, capsys: pytest.CaptureFixture[str]) -> None:
        def fake(args: list[str]) -> str:
            if args[:2] == ["gh", "pr"]:
                return json.dumps([])
            if args[:2] == ["git", "worktree"]:
                return "worktree /a\nbranch refs/heads/main\n"
            if args[:2] == ["git", "-C"]:
                return ""
            raise json.JSONDecodeError("no runners", "", 0)

        assert repo_status.main([], run_cmd=fake) == 0
        out = capsys.readouterr().out
        assert "## Open pull requests" in out and "unavailable" in out and "/a [main] clean" in out


class TestUnionMerge:
    def test_keeps_both_sides_without_duplicates(self) -> None:
        text = "a\n<<<<<<< HEAD\nours\nshared\n=======\nshared\ntheirs\n>>>>>>> branch\nz\n"
        assert union_merge.union(text) == ("a\nours\nshared\ntheirs\nz\n", 1)

    def test_handles_diff3_base_sections(self) -> None:
        text = "<<<<<<< HEAD\nours\n||||||| base\nold\n=======\ntheirs\n>>>>>>> b\n"
        assert union_merge.union(text) == ("ours\ntheirs\n", 1)

    def test_rejects_an_unterminated_conflict(self) -> None:
        with pytest.raises(ValueError):
            union_merge.union("<<<<<<< HEAD\nours\n")

    def test_files_without_conflicts_are_left_alone(self, tmp_path) -> None:
        path = tmp_path / "README.md"
        path.write_text("clean\n", encoding="utf-8")
        assert union_merge.main([str(path)]) == 1
        assert path.read_text(encoding="utf-8") == "clean\n"


def test_ci_triage_strips_prefixes_with_spaces_and_checkout_cleanup() -> None:
    raw = [
        "detect\tUNKNOWN STEP\t2026-11-05T16:43:48.5921593Z refresh_matrix: GET .../manifests/2019 returned 401",
        "detect\tUNKNOWN STEP\t2026-11-05T16:43:48.6077022Z ##[error]Process completed with exit code 1.",
        "detect\tUNKNOWN STEP\t2026-11-05T16:43:48.7657357Z includeif.gitdir:/github/workspace/.git/worktrees/*.path",
        "detect\tUNKNOWN STEP\t2026-11-05T16:43:48.8126273Z Removing credentials config '/tmp/git-credentials-1.config'",
    ]
    log = "\n".join(raw)
    assert ci_triage.error_lines(log, tail=2) == [
        "refresh_matrix: GET .../manifests/2019 returned 401",
        "##[error]Process completed with exit code 1.",
    ]


def test_ci_triage_strips_colour_codes_and_passing_pytest_lines() -> None:
    raw = [
        "pytest\tTest\t2026-11-06T10:00:00.0000000Z tests/test_a.py::test_ok PASSED [ 50%]",
        "pytest\tTest\t2026-11-06T10:00:01.0000000Z ....F..                                [ 70%]",
        "pytest\tTest\t2026-11-06T10:00:02.0000000Z \x1b[31;1mFAILED tests/test_a.py::test_bad\x1b[0m - assert 1 == 2",
        "pytest\tTest\t2026-11-06T10:00:03.0000000Z FAIL Required test coverage of 95% not reached. Total coverage: 90.00%",
    ]
    assert ci_triage.error_lines("\n".join(raw), tail=1) == [
        "FAILED tests/test_a.py::test_bad - assert 1 == 2",
        "FAIL Required test coverage of 95% not reached. Total coverage: 90.00%",
    ]
