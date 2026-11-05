"""Tests for the scripts' I/O edges and main() functions: gh, git, HTTP and files are faked, so these run offline."""

from __future__ import annotations

import io
import json
import subprocess
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from typing import Self

import ci_speed as cs
import ci_triage
import os_badges
import pytest
import refresh_matrix as rm
import repo_status
import union_merge

MCR = "mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64"
SPEC = rm.ImageSpec(
    context="nano-server/nano-server-php",
    image="windows-nano-php",
    workflow="php-container.yml",
    bases={"2022": MCR},
)


def completed(stdout: str = "", returncode: int = 0) -> SimpleNamespace:
    return SimpleNamespace(stdout=stdout, returncode=returncode)


class FakeResponse(io.BytesIO):
    def __init__(self, body: bytes, status: int = 200, headers: dict[str, str] | None = None) -> None:
        super().__init__(body)
        self.status = status
        self.headers = headers or {}

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


# --- the thin subprocess wrappers ---


@pytest.mark.parametrize(
    ("module", "args", "command"),
    [
        (ci_triage, ["run", "list"], ["gh", "run", "list"]),
        (os_badges, ["run", "list"], ["gh", "run", "list"]),
        (repo_status, ["git", "status"], ["git", "status"]),
    ],
    ids=["ci_triage.gh", "os_badges.gh", "repo_status.run"],
)
def test_subprocess_wrappers_return_stdout(monkeypatch, module, args, command) -> None:
    seen = []
    monkeypatch.setattr(subprocess, "run", lambda cmd, **kw: seen.append(cmd) or completed("out"))
    runner = getattr(module, "gh", None) or module.run
    assert runner(args) == "out"
    assert seen == [command]


# --- ci_speed ---


class TestCiSpeedIo:
    def test_leg_name_needs_a_windows_version(self) -> None:
        assert cs.leg_name("build / build-and-test (nano)") is None

    @pytest.mark.parametrize("variable", ["GH_TOKEN", "GITHUB_TOKEN"])
    def test_token_comes_from_the_environment(self, monkeypatch, variable: str) -> None:
        monkeypatch.delenv("GH_TOKEN", raising=False)
        monkeypatch.delenv("GITHUB_TOKEN", raising=False)
        monkeypatch.setenv(variable, "t0k")
        assert cs.github_token() == "t0k"

    def test_token_falls_back_to_gh(self, monkeypatch) -> None:
        monkeypatch.delenv("GH_TOKEN", raising=False)
        monkeypatch.delenv("GITHUB_TOKEN", raising=False)
        monkeypatch.setattr(subprocess, "run", lambda cmd, **kw: completed("from-gh\n"))
        assert cs.github_token() == "from-gh"

    def test_github_get_sends_the_token_and_parses_json(self, monkeypatch) -> None:
        seen = {}

        def urlopen(request, timeout):
            seen["auth"] = request.get_header("Authorization")
            seen["url"] = request.full_url
            return FakeResponse(b'{"ok": true}')

        monkeypatch.setattr(cs.urllib.request, "urlopen", urlopen)
        assert cs.github_get("repos/o/r", "t") == {"ok": True}
        assert seen == {"auth": "Bearer t", "url": "https://api.github.com/repos/o/r"}

    def test_repository_comes_from_the_environment(self, monkeypatch) -> None:
        monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
        assert cs.repository() == "o/r"

    @pytest.mark.parametrize(
        "url", ["https://github.com/o/r.git\n", "git@github.com:o/r.git\n", "https://github.com/o/r"]
    )
    def test_repository_falls_back_to_the_origin_remote(self, monkeypatch, url: str) -> None:
        monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)
        monkeypatch.setattr(subprocess, "run", lambda cmd, **kw: completed(url))
        assert cs.repository() == "o/r"

    @pytest.mark.parametrize(("returncode", "expected"), [(0, True), (1, False)])
    def test_git_contains(self, monkeypatch, returncode: int, expected: bool) -> None:
        monkeypatch.setattr(subprocess, "run", lambda cmd, **kw: completed(returncode=returncode))
        assert cs.git_contains("a", "b") is expected

    def test_main_reads_image_workflows_and_writes_the_report(self, monkeypatch, tmp_path: Path, capsys) -> None:
        milestones = tmp_path / "m.json"
        milestones.write_text(
            json.dumps([{"id": "x", "sha": "b" * 40, "since": "2026-11-05T00:00:00Z", "description": "d"}]),
            encoding="utf-8",
        )

        def get(path: str, token: str) -> dict:
            if path.endswith("workflows?per_page=100"):
                return {
                    "workflows": [
                        {"id": 1, "path": ".github/workflows/php-container.yml"},
                        {"id": 2, "path": ".github/workflows/markdown-lint.yml"},
                    ]
                }
            if "/workflows/1/runs" in path:
                return {
                    "workflow_runs": [
                        {"id": 10, "name": "PHP container", "head_sha": "a" * 40, "created_at": "2026-11-04T00:00:00Z"},
                        {"id": 11, "name": "PHP container", "head_sha": "c" * 40, "created_at": "2026-11-06T00:00:00Z"},
                    ]
                }
            assert "/workflows/2/" not in path, "read runs of a workflow that isn't an image workflow"
            minutes = {"10": "10", "11": "02"}[path.split("/runs/")[1].split("/")[0]]
            return {
                "jobs": [
                    {
                        "name": "build / build-and-test (2022)",
                        "conclusion": "success",
                        "started_at": "2026-11-04T00:00:00Z",
                        "completed_at": f"2026-11-04T00:{minutes}:00Z",
                    }
                ]
            }

        monkeypatch.setattr(cs, "github_token", lambda: "t")
        monkeypatch.setattr(cs, "repository", lambda: "o/r")
        monkeypatch.setattr(cs, "github_get", get)
        monkeypatch.setattr(cs, "git_contains", lambda ancestor, sha: sha == "c" * 40)
        output = tmp_path / "report.md"
        assert cs.main(["--milestones", str(milestones), "--output", str(output)]) == 0
        assert "| PHP container | 2022 |" in output.read_text(encoding="utf-8")
        assert "## CI speed: x" in capsys.readouterr().out


# --- ci_triage ---


RUN = {"name": "Go container", "headBranch": "main", "headSha": "abcdef0123", "conclusion": "failure", "url": "u"}


class TestCiTriageMain:
    def _gh(self, jobs: list[dict], log: str | Exception = "E  boom\n", runs: str = "[]"):
        def fake(args: list[str]) -> str:
            if args[:2] == ["run", "view"] and "--json" in args:
                return json.dumps(dict(RUN, jobs=jobs))
            if args[:2] == ["run", "view"]:
                if isinstance(log, Exception):
                    raise log
                return log
            return runs

        return fake

    def test_report_lists_failed_jobs_with_their_errors(self) -> None:
        jobs = [{"databaseId": 7, "name": "build (2019)", "conclusion": "failure", "steps": []}]
        text = ci_triage.report(1, self._gh(jobs))
        assert "### build (2019): failure at step '(no failed step)'" in text and "E  boom" in text

    def test_report_survives_a_missing_log(self) -> None:
        jobs = [{"id": 7, "name": "b", "conclusion": "timed_out", "steps": []}]
        failure = subprocess.CalledProcessError(1, "gh")
        assert "(no log available yet)" in ci_triage.report(1, self._gh(jobs, log=failure))

    def test_report_says_when_nothing_failed(self) -> None:
        assert "No failed jobs." in ci_triage.report(1, self._gh([]))

    def test_main_with_a_run_exits_1(self, capsys) -> None:
        assert ci_triage.main(["--run", "5"], run_gh=self._gh([])) == 1
        assert "## Go container" in capsys.readouterr().out

    def test_main_with_a_green_pr_exits_0(self, capsys) -> None:
        assert ci_triage.main(["--pr", "3"], run_gh=self._gh([], runs="[]")) == 0
        assert "No failed runs." in capsys.readouterr().out

    def test_main_with_a_branch_uses_its_latest_failed_run(self) -> None:
        assert ci_triage.main(["--branch", "main"], run_gh=self._gh([], runs='[{"databaseId": 9}]')) == 1


# --- os_badges ---


def test_os_badges_runs_jobs_reads_runs_lazily_and_skips_pull_requests() -> None:
    calls = []

    def fake(args: list[str]) -> str:
        calls.append(args[:2])
        if args[:2] == ["run", "list"]:
            return json.dumps([{"databaseId": 1, "event": "pull_request"}, {"databaseId": 2, "event": "push"}])
        return json.dumps({"jobs": [{"name": "x (2022)", "conclusion": "success"}]})

    assert list(os_badges.runs_jobs("x.yml", fake)) == [[{"name": "x (2022)", "conclusion": "success"}]]
    assert calls == [["run", "list"], ["run", "view"]]


# --- refresh_matrix ---


class TestRefreshMatrixIo:
    @pytest.mark.parametrize(
        ("status", "body", "expected"),
        [
            (404, b"", True),
            (500, b"", False),
            (401, b"not json", False),
            (401, b'{"errors": [{"code": "UNAUTHORIZED"}]}', True),
        ],
        ids=["404", "500", "401-not-json", "401-never-pushed"],
    )
    def test_hub_not_published(self, status: int, body: bytes, expected: bool) -> None:
        assert rm.hub_not_published(status, body) is expected

    def test_http_fetch_returns_status_headers_and_body(self, monkeypatch) -> None:
        monkeypatch.setattr(
            rm.urllib.request,
            "urlopen",
            lambda request, timeout: FakeResponse(b"{}", 200, {"Docker-Content-Digest": "d"}),
        )
        assert rm.http_fetch("https://x", {}) == (200, {"docker-content-digest": "d"}, b"{}")

    def test_http_fetch_returns_http_errors_instead_of_raising(self, monkeypatch) -> None:
        def urlopen(request, timeout):
            raise urllib.error.HTTPError("https://x", 404, "nf", {"Retry-After": "1"}, io.BytesIO(b"gone"))

        monkeypatch.setattr(rm.urllib.request, "urlopen", urlopen)
        assert rm.http_fetch("https://x", {}) == (404, {"retry-after": "1"}, b"gone")

    def test_network_errors_are_retried_then_succeed(self) -> None:
        attempts = []

        def fetch(url, headers):
            attempts.append(url)
            if len(attempts) == 1:
                raise OSError("reset")
            return 200, {}, b"{}"

        sleeps: list[float] = []
        assert rm.Registries(fetch, sleeps.append)._request("u", {}) == (200, {}, b"{}")
        assert sleeps == [1]

    def test_retry_after_is_honoured(self) -> None:
        responses = iter([(429, {"retry-after": "3"}, b""), (200, {}, b"{}")])
        sleeps: list[float] = []
        assert rm.Registries(lambda u, h: next(responses), sleeps.append)._request("u", {})[0] == 200
        assert sleeps == [3.0]

    def _registries(self, responses: dict[str, tuple[int, dict, object]]) -> rm.Registries:
        def fetch(url, headers):
            status, response_headers, body = responses[url]
            return status, response_headers, json.dumps(body).encode()

        return rm.Registries(fetch, lambda s: None)

    def test_an_index_without_windows_amd64_is_an_error(self) -> None:
        manifest = "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64"
        index = {"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [{"platform": {"os": "linux"}}]}
        with pytest.raises(rm.RegistryError, match="no windows/amd64"):
            self._registries({manifest: (200, {}, index)}).base(MCR)

    def test_a_missing_base_is_an_error(self) -> None:
        manifest = "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64"
        with pytest.raises(rm.RegistryError, match="not found"):
            self._registries({manifest: (404, {}, {})}).base(MCR)

    def test_a_base_without_a_digest_is_an_error(self) -> None:
        manifest = "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64"
        blob = "https://mcr.microsoft.com/v2/windows/nanoserver/blobs/sha256:cfg"
        responses = {manifest: (200, {}, {"config": {"digest": "sha256:cfg"}}), blob: (200, {}, {})}
        with pytest.raises(rm.RegistryError, match="no digest"):
            self._registries(responses).base(MCR)

    def test_bases_are_cached(self) -> None:
        manifest = "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64"
        blob = "https://mcr.microsoft.com/v2/windows/nanoserver/blobs/sha256:cfg"
        responses = {
            manifest: (200, {"docker-content-digest": "sha256:m"}, {"config": {"digest": "sha256:cfg"}}),
            blob: (200, {}, {"os.version": "10.0.20348.1"}),
        }
        registries = self._registries(responses)
        first = registries.base(MCR)
        responses.clear()
        assert registries.base(MCR) is first

    def test_published_labels_without_a_token_is_unpublished(self) -> None:
        auth = (
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:zippy1981/windows-nano-php:pull"
        )
        assert self._registries({auth: (404, {}, {})}).published_labels("windows-nano-php", "2022") is None

    def test_published_labels_reads_the_config_labels(self) -> None:
        auth = (
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:zippy1981/windows-nano-php:pull"
        )
        manifest = "https://registry-1.docker.io/v2/zippy1981/windows-nano-php/manifests/2022"
        blob = "https://registry-1.docker.io/v2/zippy1981/windows-nano-php/blobs/sha256:cfg"
        responses = {
            auth: (200, {}, {"token": "t"}),
            manifest: (200, {"docker-content-digest": "sha256:m"}, {"config": {"digest": "sha256:cfg"}}),
            blob: (200, {}, {"config": {"Labels": {"a": "b"}}}),
        }
        assert self._registries(responses).published_labels("windows-nano-php", "2022") == {"a": "b"}

    @pytest.mark.parametrize(
        ("known", "log", "expected"),
        [(1, "", True), (0, "abc\n", True), (0, "", False)],
        ids=["unknown-revision", "changed", "unchanged"],
    )
    def test_git_changed_since(self, monkeypatch, known: int, log: str, expected: bool) -> None:
        def run(cmd, **kw):
            return completed(returncode=known) if cmd[1] == "cat-file" else completed(log)

        monkeypatch.setattr(subprocess, "run", run)
        assert rm.git_changed_since("abc", "nano-server/nano-server-php") is expected

    def _main(self, monkeypatch, entries=None, error=None, warnings=()):
        def plan(specs, registries, force, only, warnings: list[str]):
            if error:
                raise error
            warnings.extend(extra_warnings)
            return entries or []

        extra_warnings = list(warnings)
        monkeypatch.setattr(rm, "discover_images", lambda: [SPEC])
        monkeypatch.setattr(rm, "plan_refresh", plan)

    def test_main_prints_the_matrix_and_writes_github_outputs(self, monkeypatch, tmp_path: Path, capsys) -> None:
        entry = {"image": "windows-nano-php", "reasons": {"2022": "missing"}, "os-versions": {"2022": "10.0"}}
        self._main(monkeypatch, entries=[entry], warnings=["windows-nano-php 2019: probe failed"])
        output, summary = tmp_path / "out", tmp_path / "summary"
        monkeypatch.setenv("GITHUB_OUTPUT", str(output))
        monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
        assert rm.main(["--github-output", "--images", "nano-server/nano-server-php"]) == 0
        assert output.read_text(encoding="utf-8").startswith("matrix=[")
        assert "| `windows-nano-php` | 2022 | missing |" in summary.read_text(encoding="utf-8")
        assert "::warning::windows-nano-php 2019: probe failed" in capsys.readouterr().err

    def test_main_reports_warnings_on_stderr_without_github_output(self, monkeypatch, capsys) -> None:
        self._main(monkeypatch, warnings=["something"])
        assert rm.main([]) == 0
        assert "refresh_matrix: warning: something" in capsys.readouterr().err

    def test_main_fails_on_a_registry_error(self, monkeypatch, capsys) -> None:
        self._main(monkeypatch, error=rm.RegistryError("down"))
        assert rm.main([]) == 1
        assert "refresh_matrix: down" in capsys.readouterr().err

    def test_main_fails_when_no_base_resolves(self, monkeypatch, capsys) -> None:
        self._main(monkeypatch, warnings=["windows-nano-php 2022: base image lookup failed"])
        assert rm.main([]) == 1
        assert "no base image could be resolved" in capsys.readouterr().err


# --- repo_status ---


def test_repo_status_lists_prs_runners_and_dirty_worktrees(capsys) -> None:
    def fake(args: list[str]) -> str:
        if args[:2] == ["gh", "pr"]:
            return json.dumps(
                [
                    {"number": 2, "isDraft": True, "headRefName": "b", "baseRefName": "a", "statusCheckRollup": []},
                    {
                        "number": 1,
                        "isDraft": False,
                        "headRefName": "a",
                        "baseRefName": "main",
                        "statusCheckRollup": [{"conclusion": "SKIPPED"}],
                    },
                ]
            )
        if args[:2] == ["gh", "repo"]:
            return "o/r\n"
        if args[:2] == ["gh", "api"] and "runners" in args[2]:
            return json.dumps({"runners": [{"busy": True, "status": "online"}, {"busy": False, "status": "offline"}]})
        if args[:2] == ["gh", "api"]:
            return json.dumps({"total_count": 4})
        if args[:2] == ["git", "worktree"]:
            return "worktree /a\nbranch refs/heads/main\n\nworktree /b\ndetached\n"
        if args[2] == "/b":
            raise subprocess.CalledProcessError(128, "git")
        return " M x\n"

    assert repo_status.main([], run_cmd=fake) == 0
    out = capsys.readouterr().out
    assert "- #1 a: 1 skip" in out and "- #2 (draft) b -> a: no checks" in out
    assert "1/2 online, 1 busy" in out and "queued workflow runs: 4" in out
    assert "/a [main] 1 dirty" in out and "/b [(detached)] -1 dirty" in out


# --- union_merge ---


class TestUnionMergeMain:
    def test_needs_a_file(self, capsys) -> None:
        assert union_merge.main([]) == 2
        assert "usage" in capsys.readouterr().err

    def test_resolves_a_file_in_place(self, tmp_path: Path, capsys) -> None:
        path = tmp_path / "README.md"
        path.write_text("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\n", encoding="utf-8")
        assert union_merge.main([str(path)]) == 0
        assert path.read_text(encoding="utf-8") == "ours\ntheirs\n"
        assert "resolved 1 conflict(s)" in capsys.readouterr().out
