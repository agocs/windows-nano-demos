"""The repo's conventions as data, plus helpers to load workflows and find images (ADR 0011).

When a convention changes, change its ADR and the constants here in the same pull request.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

# ADR 0003: the self-hosted nanoserver runners that talk to the host docker daemon
RUNNER_LABELS = ["self-hosted", "windows", "docker"]
# ADR 0003: self-hosted jobs never run for pull requests from forks
FORK_GUARD = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
# ADR 0008
WINDOWS_VERSIONS = ["2019", "2022", "2025"]
DEFAULT_WINDOWS_VERSION = "2025"
# ADR 0008 exceptions: images whose workflow overrides the shared matrix with `windows-versions`, and exactly the
# versions they build. Every entry needs a reason in the image README.
# None today: MySQL builds ltsc2019 again since its smoke test waits for the server properly (issue #44).
WINDOWS_VERSION_EXCEPTIONS: dict[str, list[str]] = {}
BASE_IMAGE_ARG = re.compile(
    r"^ARG BASE_IMAGE=mcr\.microsoft\.com/windows/(nanoserver|servercore):ltsc\$\{WINDOWS_VERSION\}-amd64$"
)
# ADR 0009
REUSABLE_WORKFLOW = "build-windows-image.yml"
REUSABLE_WORKFLOW_REF = f"./.github/workflows/{REUSABLE_WORKFLOW}"
# plans/patch-tuesday-image-refresh.md: the only workflow that publishes, and the only caller that builds a subset of versions
REFRESH_WORKFLOW = "image-refresh.yml"
# The GitHub environment that holds DOCKERHUB_USERNAME and DOCKERHUB_TOKEN
PUBLISH_ENVIRONMENT = "Docker Hub zippy1981"
SMOKE_TEST = "smoke-test.ps1"
# ADR 0012: each image lives in the directory for the base of its final stage, as <dir>/<dir>-<name>, and is
# published as the matching Docker Hub name, windows-<prefix>-<name>
IMAGE_PARENTS = {"nano-server": "nanoserver", "server-core": "servercore"}
HUB_PREFIXES = {"nano-server": "windows-nano-", "server-core": "windows-servercore-"}
# ADR 0011: actions owned by these accounts may use version tags; everything else is pinned to a commit
TRUSTED_ACTION_OWNERS = {"actions"}

_DOCKER_COMMAND = re.compile(r"(?m)^\s*(?:\$\w+\s*=\s*)?docker(?:\.exe)?\s")


def workflow_paths() -> list[Path]:
    return sorted([*WORKFLOWS_DIR.glob("*.yml"), *WORKFLOWS_DIR.glob("*.yaml")])


def load_workflow(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError(f"{path.name} is not a YAML mapping")
    # PyYAML follows YAML 1.1, which reads the bare key `on` as the boolean True
    if True in data:
        data["on"] = data.pop(True)
    return data


def workflows() -> dict[str, dict[str, Any]]:
    return {path.name: load_workflow(path) for path in workflow_paths()}


def jobs(workflow: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return workflow.get("jobs") or {}


def all_jobs() -> list[tuple[str, str, dict[str, Any]]]:
    """Every job in every workflow, as (workflow file, job id, job)."""
    return [(name, job_id, job) for name, wf in workflows().items() for job_id, job in jobs(wf).items()]


def runs_on(job: dict[str, Any]) -> list[str]:
    value = job.get("runs-on", [])
    return [value] if isinstance(value, str) else list(value)


def is_reusable_call(job: dict[str, Any]) -> bool:
    return "uses" in job


def runs_docker(job: dict[str, Any]) -> bool:
    """True if any step runs the docker CLI, directly or through an image's smoke-test.ps1."""
    for step in job.get("steps", []):
        script = step.get("run", "")
        if _DOCKER_COMMAND.search(script) or SMOKE_TEST in script:
            return True
    return False


def normalize_expression(text: str) -> str:
    text = text.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return " ".join(text.split())


def image_dirs() -> list[Path]:
    """Folders with a Dockerfile under the base-image directories (ADR 0012). Each one is an image."""
    return sorted(
        p
        for parent in IMAGE_PARENTS
        if (REPO_ROOT / parent).is_dir()
        for p in (REPO_ROOT / parent).iterdir()
        if p.is_dir() and (p / "Dockerfile").is_file()
    )


def image_context(image_dir: Path) -> str:
    """The image's docker build context as the workflows name it, for example nano-server/nano-server-php."""
    return image_dir.relative_to(REPO_ROOT).as_posix()


def top_level_image_dirs() -> list[Path]:
    """Folders with a Dockerfile directly in the repo root. ADR 0012 says there are none."""
    return sorted(p for p in REPO_ROOT.iterdir() if p.is_dir() and (p / "Dockerfile").is_file())


def callers_of_reusable() -> list[tuple[str, str, dict[str, Any]]]:
    return [(wf, job_id, job) for wf, job_id, job in all_jobs() if job.get("uses") == REUSABLE_WORKFLOW_REF]


def dockerfile_lines(image_dir: Path) -> list[str]:
    """Dockerfile instructions with comments and blank lines removed and continuations joined."""
    lines: list[str] = []
    pending = ""
    for raw in (image_dir / "Dockerfile").read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not pending and (not line or line.startswith("#")):
            continue
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        lines.append((pending + line).strip())
        pending = ""
    if pending:
        lines.append(pending.strip())
    return lines
