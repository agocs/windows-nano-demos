"""Tests for scripts/ci_speed.py, offline: the GitHub API and git are faked."""

from __future__ import annotations

from datetime import UTC, datetime

import ci_speed as cs

MILESTONE = cs.Milestone("layer-cache", "c" * 40, datetime(2026, 11, 5, 12, 0, tzinfo=UTC), "test change")


def run(run_id: int, sha: str, created: str, name: str = "PHP container") -> dict:
    return {"id": run_id, "name": name, "head_sha": sha, "created_at": created}


def job(name: str, started: str, completed: str, conclusion: str = "success") -> dict:
    return {"name": name, "started_at": started, "completed_at": completed, "conclusion": conclusion}


def test_leg_names() -> None:
    assert cs.leg_name("build / build-and-test (2025)") == "2025"
    assert cs.leg_name("build (1.26.10) / build-and-test (2022)") == "go1.26.10 2022"
    assert cs.leg_name("build-and-test (vim, 2019)") == "2019"
    assert cs.leg_name("pytest") is None


def test_only_successful_build_jobs_are_sampled() -> None:
    jobs = {
        1: [
            job("build / build-and-test (2022)", "2026-11-04T10:00:00Z", "2026-11-04T10:30:00Z"),
            job("build / build-and-test (2019)", "2026-11-04T10:00:00Z", "2026-11-04T10:05:00Z", "failure"),
            job("lint", "2026-11-04T10:00:00Z", "2026-11-04T10:01:00Z"),
        ]
    }
    samples = cs.samples_from_runs([run(1, "a" * 40, "2026-11-04T10:00:00Z")], jobs.__getitem__)
    assert [(s.leg, s.minutes) for s in samples] == [("2022", 30.0)]


def _samples(before_min: list[float], after_min: list[float]) -> list[cs.JobSample]:
    samples = [
        cs.JobSample("PHP container", "2022", "a" * 40, datetime(2026, 11, 4, h, tzinfo=UTC), m)
        for h, m in enumerate(before_min)
    ]
    samples += [
        cs.JobSample("PHP container", "2022", "c" * 40, datetime(2026, 11, 5, 13 + h, tzinfo=UTC), m)
        for h, m in enumerate(after_min)
    ]
    return samples


def test_first_run_after_is_reported_separately_from_later_runs() -> None:
    (report,) = cs.compare(_samples([30, 20, 25], [28, 5, 3]), MILESTONE, lambda ancestor, sha: True)
    assert report.first_after == 28
    assert report.later == [5, 3]
    assert report.speedup == 25 / 4


def test_runs_without_the_milestone_commit_are_ignored() -> None:
    (report,) = cs.compare(_samples([30], [5, 4]), MILESTONE, lambda ancestor, sha: False)
    assert report.first_after is None and report.later == []
    assert report.speedup is None


def test_markdown_names_the_point_of_improvement_and_the_verdict() -> None:
    reports = cs.compare(_samples([30, 20, 25], [28, 5, 3]), MILESTONE, lambda ancestor, sha: True)
    text = cs.markdown(MILESTONE, reports, datetime(2026, 11, 6, tzinfo=UTC))
    assert "Point of improvement: `ccccccc`" in text
    assert "| PHP container | 2022 | 25.0 min (n=3) | 28.0 min | 4.0 min (n=2) | 6.2x |" in text
    assert "faster" in text and "6.2x" in text


def test_markdown_says_when_there_is_nothing_to_compare_yet() -> None:
    reports = cs.compare(_samples([30], [28]), MILESTONE, lambda ancestor, sha: True)
    assert "No leg has a later run yet" in cs.markdown(MILESTONE, reports, datetime(2026, 11, 6, tzinfo=UTC))


def test_milestones_file_loads() -> None:
    (milestone,) = cs.load_milestones(cs.DEFAULT_MILESTONES)
    assert milestone.id == "layer-cache" and len(milestone.sha) == 40
