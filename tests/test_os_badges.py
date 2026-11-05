"""Tests for scripts/os_badges.py and the OS badges workflow. All offline."""

from __future__ import annotations

import json
from pathlib import Path

import os_badges
import pytest
import yaml
from repo_conventions import WINDOWS_VERSION_EXCEPTIONS, WINDOWS_VERSIONS, WORKFLOWS_DIR

REPO_ROOT = Path(__file__).resolve().parent.parent


def leg(name: str, conclusion: str | None) -> dict:
    return {"name": name, "conclusion": conclusion}


def test_a_version_fails_if_any_of_its_legs_fail() -> None:
    jobs = [
        leg("build (1.27.3) / build-and-test (2019)", "success"),
        leg("build (1.26.10) / build-and-test (2019)", "failure"),
        leg("build (1.27.3) / build-and-test (2022)", "success"),
        leg("detect", "success"),
    ]
    assert os_badges.version_status(jobs) == {"2019": "failing", "2022": "passing"}


def test_unfinished_and_cancelled_versions_have_no_status() -> None:
    jobs = [leg("build / build-and-test (2019)", "cancelled"), leg("build / build-and-test (2022)", None)]
    assert os_badges.version_status(jobs) == {}


def test_a_cancelled_version_takes_its_status_from_an_older_run_and_scanning_stops_early() -> None:
    newest = [leg("build / build-and-test (2019)", "cancelled"), leg("build / build-and-test (2025)", "success")]
    older = [leg("build / build-and-test (2019)", "failure"), leg("build / build-and-test (2025)", "failure")]

    def runs():
        yield newest
        yield older
        raise AssertionError("read past the run that completed every version")

    assert os_badges.latest_status(runs()) == {"2019": "failing", "2025": "passing"}


def test_badge_is_a_shields_endpoint() -> None:
    assert os_badges.badge("2019", "failing") == {
        "schemaVersion": 1,
        "label": "ltsc2019",
        "message": "failing",
        "color": "red",
    }


def test_main_writes_one_file_per_built_version_and_skips_pull_request_runs(tmp_path: Path) -> None:
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "x-container.yml").write_text(
        "name: X container\njobs:\n  build:\n    uses: ./.github/workflows/build-windows-image.yml\n", encoding="utf-8"
    )
    (workflows / "markdown-lint.yml").write_text("name: Lint\njobs:\n  lint:\n    runs-on: x\n", encoding="utf-8")
    runs = {
        1: [leg("build / build-and-test (2022)", "success")],
        2: [leg("build / build-and-test (2022)", "failure")],
    }

    def fake(args: list[str]) -> str:
        if args[:2] == ["run", "list"]:
            return json.dumps([{"databaseId": 2, "event": "pull_request"}, {"databaseId": 1, "event": "push"}])
        return json.dumps({"jobs": runs[int(args[2])]})

    out = tmp_path / "out"
    assert os_badges.main(["--out", str(out)], run_gh=fake, workflows_dir=workflows) == 0
    assert [p.name for p in out.iterdir()] == ["x-container-2022.json"]
    assert json.loads((out / "x-container-2022.json").read_text(encoding="utf-8"))["message"] == "passing"


def test_badges_workflow_triggers_on_every_image_workflow() -> None:
    workflow = yaml.safe_load((WORKFLOWS_DIR / "os-badges.yml").read_text(encoding="utf-8"))
    # PyYAML reads the `on` key as True
    triggers = workflow[True]
    assert sorted(triggers["workflow_run"]["workflows"]) == sorted(os_badges.image_workflows().values())
    assert triggers["workflow_run"]["branches"] == ["main"]


def built_versions(workflow: str) -> list[str]:
    """The Windows versions an image workflow builds: every version unless it is an ADR 0008 exception."""
    caller = yaml.safe_load((WORKFLOWS_DIR / workflow).read_text(encoding="utf-8"))
    contexts = [job.get("with", {}).get("context") for job in caller["jobs"].values()]
    return next((WINDOWS_VERSION_EXCEPTIONS[c] for c in contexts if c in WINDOWS_VERSION_EXCEPTIONS), WINDOWS_VERSIONS)


BADGES = [(Path(wf).stem, version) for wf in os_badges.image_workflows() for version in built_versions(wf)]


@pytest.mark.parametrize(("stem", "version"), BADGES, ids=[f"{s}-{v}" for s, v in BADGES])
def test_readme_shows_a_build_badge_for_every_built_version(stem: str, version: str) -> None:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    assert f"badges%2F{stem}-{version}.json" in readme, f"README has no ltsc{version} build badge for {stem}"
