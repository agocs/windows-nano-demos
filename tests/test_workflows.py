"""GitHub Actions workflows must use the self-hosted runners safely and the shared build workflow (ADR 0003, 0009, 0011)."""

from __future__ import annotations

import json
import re

import pytest
from repo_conventions import (
    FORK_GUARD,
    PUBLISH_ENVIRONMENT,
    REFRESH_WORKFLOW,
    REUSABLE_WORKFLOW,
    REUSABLE_WORKFLOW_REF,
    RUNNER_LABELS,
    SMOKE_TEST,
    TRUSTED_ACTION_OWNERS,
    WINDOWS_VERSIONS,
    all_jobs,
    callers_of_reusable,
    image_dirs,
    is_reusable_call,
    jobs,
    normalize_expression,
    runs_docker,
    runs_on,
    workflow_paths,
    workflows,
)

JOBS = all_jobs()
JOB_IDS = [f"{wf}:{job_id}" for wf, job_id, _ in JOBS]
RUN_JOBS = [(wf, job_id, job) for wf, job_id, job in JOBS if not is_reusable_call(job)]
RUN_JOB_IDS = [f"{wf}:{job_id}" for wf, job_id, _ in RUN_JOBS]
SELF_HOSTED = [(wf, job_id, job) for wf, job_id, job in RUN_JOBS if "self-hosted" in runs_on(job)]
SELF_HOSTED_IDS = [f"{wf}:{job_id}" for wf, job_id, _ in SELF_HOSTED]


@pytest.fixture(scope="module")
def reusable() -> dict:
    return workflows()[REUSABLE_WORKFLOW]


@pytest.fixture(scope="module")
def reusable_job(reusable: dict) -> dict:
    (job,) = jobs(reusable).values()
    return job


def test_workflows_exist() -> None:
    assert workflow_paths(), "no workflows found under .github/workflows"


@pytest.mark.parametrize("path", workflow_paths(), ids=lambda p: p.name)
def test_workflow_has_name_triggers_and_jobs(path) -> None:
    wf = workflows()[path.name]
    assert wf.get("name"), f"{path.name} has no name"
    assert wf.get("on"), f"{path.name} has no triggers"
    assert jobs(wf), f"{path.name} has no jobs"


@pytest.mark.parametrize(("wf", "job_id", "job"), RUN_JOBS, ids=RUN_JOB_IDS)
def test_docker_jobs_use_the_self_hosted_runner(wf: str, job_id: str, job: dict) -> None:
    if runs_docker(job):
        assert runs_on(job) == RUNNER_LABELS, (
            f"{wf}:{job_id} runs docker, so it must use runs-on: {RUNNER_LABELS}, not {runs_on(job)}"
        )


@pytest.mark.parametrize(("wf", "job_id", "job"), RUN_JOBS, ids=RUN_JOB_IDS)
def test_jobs_without_docker_use_github_hosted_runners(wf: str, job_id: str, job: dict) -> None:
    if not runs_docker(job):
        assert "self-hosted" not in runs_on(job), (
            f"{wf}:{job_id} doesn't use docker, so it should run on a GitHub-hosted runner, not {runs_on(job)}"
        )


@pytest.mark.parametrize(("wf", "job_id", "job"), SELF_HOSTED, ids=SELF_HOSTED_IDS)
def test_self_hosted_jobs_use_exactly_the_runner_labels(wf: str, job_id: str, job: dict) -> None:
    assert runs_on(job) == RUNNER_LABELS, f"{wf}:{job_id} uses {runs_on(job)}; the runners are labelled {RUNNER_LABELS}"


@pytest.mark.parametrize(("wf", "job_id", "job"), SELF_HOSTED, ids=SELF_HOSTED_IDS)
def test_self_hosted_jobs_skip_fork_pull_requests(wf: str, job_id: str, job: dict) -> None:
    assert normalize_expression(str(job.get("if", ""))) == FORK_GUARD, (
        f"{wf}:{job_id} runs on the self-hosted runner without the fork guard: if: {FORK_GUARD}"
    )


@pytest.mark.parametrize(("wf", "job_id", "job"), SELF_HOSTED, ids=SELF_HOSTED_IDS)
def test_self_hosted_jobs_have_a_timeout(wf: str, job_id: str, job: dict) -> None:
    assert "timeout-minutes" in job, f"{wf}:{job_id} has no timeout-minutes, so a hung build holds a runner for 6 hours"


@pytest.mark.parametrize(("wf", "job_id", "job"), JOBS, ids=JOB_IDS)
def test_third_party_actions_are_pinned_to_a_commit(wf: str, job_id: str, job: dict) -> None:
    for step in job.get("steps", []):
        uses = step.get("uses")
        if not uses or uses.startswith("./"):
            continue
        owner = uses.split("/", 1)[0]
        if owner not in TRUSTED_ACTION_OWNERS:
            assert re.search(r"@[0-9a-f]{40}$", uses), (
                f"{wf}:{job_id} uses {uses}; pin third-party actions to a commit SHA"
            )


def test_image_builds_only_run_through_the_reusable_workflow() -> None:
    direct = [f"{wf}:{job_id}" for wf, job_id, job in RUN_JOBS if wf != REUSABLE_WORKFLOW and runs_docker(job)]
    assert not direct, f"these jobs run docker directly instead of calling {REUSABLE_WORKFLOW_REF}: {direct}"


class TestReusableWorkflow:
    def test_is_callable(self, reusable: dict) -> None:
        assert "workflow_call" in reusable["on"]

    def test_requires_context_and_image_inputs(self, reusable: dict) -> None:
        inputs = reusable["on"]["workflow_call"]["inputs"]
        for name in ("context", "image"):
            assert inputs[name]["required"] is True

    def test_has_a_single_job(self, reusable: dict) -> None:
        assert len(jobs(reusable)) == 1

    def test_runs_on_the_self_hosted_runner(self, reusable_job: dict) -> None:
        assert runs_on(reusable_job) == RUNNER_LABELS

    def test_builds_every_windows_version_without_fail_fast(self, reusable: dict, reusable_job: dict) -> None:
        strategy = reusable_job["strategy"]
        assert strategy["fail-fast"] is False
        # The matrix comes from the windows-versions input, so image-refresh.yml can build a subset.
        # Image workflows don't pass it, so the default must be every version (ADR 0008).
        assert normalize_expression(strategy["matrix"]["windows-version"]) == "fromJSON(inputs.windows-versions)"
        default = reusable["on"]["workflow_call"]["inputs"]["windows-versions"]["default"]
        assert json.loads(default) == WINDOWS_VERSIONS

    def test_image_workflows_build_every_version(self) -> None:
        for wf, job_id, job in callers_of_reusable():
            if wf != REFRESH_WORKFLOW:
                assert "windows-versions" not in job.get("with", {}), f"{wf}:{job_id} must build every Windows version"

    def test_publishes_only_from_main_through_the_publish_environment(self, reusable_job: dict) -> None:
        pushes = [s for s in reusable_job["steps"] if "docker push" in s.get("run", "")]
        assert pushes, "no publish step"
        for step in pushes:
            condition = str(step.get("if", ""))
            assert "inputs.publish" in condition and "github.ref == 'refs/heads/main'" in condition, (
                f"publish step {step.get('name')!r} must require inputs.publish and main (ADR 0006)"
            )
        environment = normalize_expression(str(reusable_job.get("environment", "")))
        assert f"'{PUBLISH_ENVIRONMENT}'" in environment and "github.ref == 'refs/heads/main'" in environment

    def test_labels_every_build_for_refresh_detection(self, reusable_job: dict) -> None:
        build = next(s["run"] for s in reusable_job["steps"] if "docker build" in s.get("run", ""))
        for label in ("org.opencontainers.image.revision", "org.opencontainers.image.base.digest"):
            assert label in build, f"the build step must set the {label} label that image-refresh.yml reads"

    def test_builds_with_more_memory_and_the_version_argument(self, reusable_job: dict) -> None:
        builds = [s["run"] for s in reusable_job["steps"] if "docker build" in s.get("run", "")]
        assert builds, "no docker build step"
        assert all("--memory" in b for b in builds), "docker build needs --memory; Hyper-V's 1 GB default hangs builds"
        assert all("WINDOWS_VERSION=${{ matrix.windows-version }}" in b for b in builds)

    def test_runs_the_image_smoke_test(self, reusable_job: dict) -> None:
        assert any(SMOKE_TEST in s.get("run", "") for s in reusable_job["steps"])

    def test_always_cleans_up(self, reusable_job: dict) -> None:
        cleanup = [
            s
            for s in reusable_job["steps"]
            if "docker rmi" in s.get("run", "") and "docker push" not in s.get("run", "")
        ]
        assert cleanup and all("always()" in str(s.get("if", "")) for s in cleanup)


@pytest.mark.parametrize("image_dir", image_dirs(), ids=lambda p: p.name)
class TestEveryImageHasACallerWorkflow:
    def _callers(self, image_dir) -> list[tuple[str, str, dict]]:
        return [c for c in callers_of_reusable() if c[2].get("with", {}).get("context") == image_dir.name]

    def test_exactly_one_caller(self, image_dir) -> None:
        callers = self._callers(image_dir)
        assert len(callers) == 1, (
            f"{image_dir.name} needs exactly one workflow job with uses: {REUSABLE_WORKFLOW_REF} "
            f"and context: {image_dir.name}, found {len(callers)}"
        )

    def test_caller_passes_the_image_name(self, image_dir) -> None:
        for wf, job_id, job in self._callers(image_dir):
            assert job["with"].get("image"), f"{wf}:{job_id} doesn't pass image"

    def test_caller_paths_include_the_image_and_the_reusable_workflow(self, image_dir) -> None:
        for wf, _, _ in self._callers(image_dir):
            triggers = workflows()[wf]["on"]
            for event in ("push", "pull_request"):
                paths = (triggers.get(event) or {}).get("paths", [])
                for wanted in (
                    f"{image_dir.name}/**",
                    f".github/workflows/{REUSABLE_WORKFLOW}",
                    f".github/workflows/{wf}",
                ):
                    assert wanted in paths, f"{wf} {event} paths are missing {wanted}"

    def test_has_a_smoke_test(self, image_dir) -> None:
        assert (image_dir / SMOKE_TEST).is_file(), f"{image_dir.name}/{SMOKE_TEST} is missing"


@pytest.mark.parametrize(("wf", "job_id", "job"), callers_of_reusable(), ids=lambda c: str(c))
def test_callers_point_at_an_image_folder(wf: str, job_id: str, job: dict) -> None:
    context = job.get("with", {}).get("context", "")
<<<<<<< HEAD
    assert context in {p.name for p in image_dirs()}, f"{wf}:{job_id} context {context!r} isn't a folder with a Dockerfile"


@pytest.mark.parametrize(("wf", "job_id", "job"), callers_of_reusable(), ids=lambda c: str(c))
def test_callers_dont_set_the_windows_version_or_base_through_build_args(wf: str, job_id: str, job: dict) -> None:
    extra = str(job.get("with", {}).get("build-args", ""))
    for name in ("WINDOWS_VERSION", "BASE_IMAGE"):
        assert name not in extra, f"{wf}:{job_id} sets {name} in build-args; the shared matrix and base-image-overrides own it"


def test_reusable_workflow_rejects_version_and_base_in_build_args() -> None:
    (job,) = jobs(workflows()[REUSABLE_WORKFLOW]).values()
    build = next(s["run"] for s in job["steps"] if "docker build" in s.get("run", ""))
    assert "'WINDOWS_VERSION', 'BASE_IMAGE'" in build and "throw" in build
=======
    if wf == REFRESH_WORKFLOW:
        assert normalize_expression(context) == "matrix.context", (
            f"{wf}:{job_id} must take context from the detect matrix"
        )
        return
    assert context in {p.name for p in image_dirs()}, (
        f"{wf}:{job_id} context {context!r} isn't a folder with a Dockerfile"
    )


def test_docker_hub_secrets_are_only_used_by_the_publishing_workflows() -> None:
    allowed = {REUSABLE_WORKFLOW, REFRESH_WORKFLOW}
    for path in workflow_paths():
        if path.name not in allowed:
            assert "DOCKERHUB_" not in path.read_text(encoding="utf-8"), (
                f"{path.name} must not touch the Docker Hub secrets"
            )


class TestRefreshWorkflow:
    def test_exists_with_a_schedule_and_manual_dispatch(self) -> None:
        triggers = workflows()[REFRESH_WORKFLOW]["on"]
        assert triggers.get("schedule") and "workflow_dispatch" in triggers

    def test_never_runs_for_pull_requests(self) -> None:
        triggers = workflows()[REFRESH_WORKFLOW]["on"]
        assert not {"pull_request", "pull_request_target", "workflow_run"} & set(triggers)

    def test_publishes_only_from_main(self) -> None:
        refresh = jobs(workflows()[REFRESH_WORKFLOW])["refresh"]
        assert normalize_expression(str(refresh["with"]["publish"])) == "github.ref == 'refs/heads/main'"
>>>>>>> 4469824 (Implement the Patch Tuesday image refresh (phases 0-4))
