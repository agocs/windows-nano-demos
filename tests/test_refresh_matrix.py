"""Tests for scripts/refresh_matrix.py. The registries are faked, so these run offline."""

from __future__ import annotations

import json

import pytest
import refresh_matrix as rm
from repo_conventions import image_context, image_dirs

NANO_2022 = "mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64"


def base(reference: str, digest: str = "sha256:new") -> rm.BaseImage:
    return rm.BaseImage(reference, digest, "10.0.20348.9999")


class FakeRegistries(rm.Registries):
    def __init__(self, published: dict[tuple[str, str], dict[str, str] | None], digest: str = "sha256:new") -> None:
        super().__init__(fetch=lambda url, headers: (500, {}, b""))
        self.published = published
        self.digest = digest
        self.base_calls: list[str] = []

    def base(self, reference: str) -> rm.BaseImage:
        self.base_calls.append(reference)
        return base(reference, self.digest)

    def published_labels(self, image: str, tag: str) -> dict[str, str] | None:
        return self.published.get((image, tag))


SPEC = rm.ImageSpec(
    context="nano-server/nano-server-php",
    image="windows-nano-php",
    workflow="php-container.yml",
    bases={v: f"mcr.microsoft.com/windows/nanoserver:ltsc{v}-amd64" for v in rm.WINDOWS_VERSIONS},
)


def current(revision: str = "abc") -> dict[str, str]:
    return {rm.BASE_DIGEST_LABEL: "sha256:new", rm.REVISION_LABEL: revision}


def all_current() -> dict[tuple[str, str], dict[str, str] | None]:
    return {("windows-nano-php", v): current() for v in rm.WINDOWS_VERSIONS}


def never_changed(revision: str, context: str) -> bool:
    return False


def test_nothing_to_do_gives_an_empty_matrix() -> None:
    assert rm.plan_refresh([SPEC], FakeRegistries(all_current()), never_changed) == []


def test_base_change_rebuilds_that_version_with_the_base_pinned() -> None:
    published = all_current()
    published[("windows-nano-php", "2022")] = {rm.BASE_DIGEST_LABEL: "sha256:old", rm.REVISION_LABEL: "abc"}
    (entry,) = rm.plan_refresh([SPEC], FakeRegistries(published), never_changed)
    assert json.loads(entry["windows-versions"]) == ["2022"]
    assert json.loads(entry["base-image-overrides"]) == {"2022": f"{NANO_2022}@sha256:new"}
    assert entry["reasons"] == {"2022": "base-changed"}


def test_unpublished_image_is_missing() -> None:
    published = all_current()
    published[("windows-nano-php", "2025")] = None
    (entry,) = rm.plan_refresh([SPEC], FakeRegistries(published), never_changed)
    assert entry["reasons"] == {"2025": "missing"}


def test_source_change_rebuilds_every_version() -> None:
    (entry,) = rm.plan_refresh([SPEC], FakeRegistries(all_current()), lambda revision, context: True)
    assert set(entry["reasons"].values()) == {"source-changed"}
    assert json.loads(entry["windows-versions"]) == list(rm.WINDOWS_VERSIONS)


def test_missing_revision_label_counts_as_source_changed() -> None:
    published = all_current()
    published[("windows-nano-php", "2019")] = {rm.BASE_DIGEST_LABEL: "sha256:new"}
    (entry,) = rm.plan_refresh([SPEC], FakeRegistries(published), never_changed)
    assert entry["reasons"] == {"2019": "source-changed"}


def test_force_rebuilds_everything_without_reading_docker_hub() -> None:
    registries = FakeRegistries({})
    (entry,) = rm.plan_refresh([SPEC], registries, never_changed, force=True)
    assert set(entry["reasons"].values()) == {"forced"}


def test_only_limits_the_images() -> None:
    assert (
        rm.plan_refresh([SPEC], FakeRegistries({}), never_changed, force=True, only={"nano-server/nano-server-go"})
        == []
    )


def test_summary_says_nothing_to_rebuild() -> None:
    assert "Nothing to rebuild" in rm.summary_markdown([])


def test_summary_lists_each_leg() -> None:
    published = all_current()
    published[("windows-nano-php", "2022")] = None
    text = rm.summary_markdown(rm.plan_refresh([SPEC], FakeRegistries(published), never_changed))
    assert "| `windows-nano-php` | 2022 | missing | 10.0.20348.9999 |" in text


class TestDiscovery:
    def test_finds_every_image_folder(self) -> None:
        contexts = {spec.context for spec in rm.discover_images()}
        assert contexts == {image_context(p) for p in image_dirs()}

    def test_uses_the_dockerfile_default_base(self) -> None:
        far = next(s for s in rm.discover_images() if s.context == "server-core/server-core-far")
        assert far.bases["2022"] == "mcr.microsoft.com/windows/servercore:ltsc2022-amd64"

    def test_applies_base_image_overrides(self) -> None:
        ssh = next(s for s in rm.discover_images() if s.context == "nano-server/nano-server-ssh")
        assert ssh.bases["2022"] == "mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64"
        assert ssh.bases["2025"] == "mcr.microsoft.com/windows/servercore:ltsc2025-amd64"


class TestRegistries:
    def _fetch(self, responses: dict[str, tuple[int, dict[str, str], object]]) -> rm.Fetch:
        def fetch(url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
            status, response_headers, body = responses[url]
            return status, response_headers, json.dumps(body).encode()

        return fetch

    def test_base_reads_digest_and_os_version_from_mcr(self) -> None:
        manifest_url = "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64"
        registries = rm.Registries(
            self._fetch(
                {
                    manifest_url: (
                        200,
                        {"docker-content-digest": "sha256:aaa"},
                        {
                            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                            "config": {"digest": "sha256:cfg"},
                        },
                    ),
                    "https://mcr.microsoft.com/v2/windows/nanoserver/blobs/sha256:cfg": (
                        200,
                        {},
                        {"os.version": "10.0.20348.1"},
                    ),
                }
            )
        )
        assert registries.base(NANO_2022) == rm.BaseImage(NANO_2022, "sha256:aaa", "10.0.20348.1")

    def test_base_resolves_an_index_to_windows_amd64(self) -> None:
        registries = rm.Registries(
            self._fetch(
                {
                    "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/ltsc2022-amd64": (
                        200,
                        {"docker-content-digest": "sha256:index"},
                        {
                            "mediaType": "application/vnd.oci.image.index.v1+json",
                            "manifests": [
                                {"digest": "sha256:arm", "platform": {"os": "windows", "architecture": "arm64"}},
                                {"digest": "sha256:x64", "platform": {"os": "windows", "architecture": "amd64"}},
                            ],
                        },
                    ),
                    "https://mcr.microsoft.com/v2/windows/nanoserver/manifests/sha256:x64": (
                        200,
                        {},
                        {"mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": "sha256:cfg"}},
                    ),
                    "https://mcr.microsoft.com/v2/windows/nanoserver/blobs/sha256:cfg": (
                        200,
                        {},
                        {"os.version": "10.0.20348.2"},
                    ),
                }
            )
        )
        assert registries.base(NANO_2022).digest == "sha256:x64"

    def test_unpublished_hub_image_is_none(self) -> None:
        registries = rm.Registries(
            self._fetch(
                {
                    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:zippy1981/windows-nano-php:pull": (
                        200,
                        {},
                        {"token": "t"},
                    ),
                    "https://registry-1.docker.io/v2/zippy1981/windows-nano-php/manifests/2025": (404, {}, {}),
                }
            )
        )
        assert registries.published_labels("windows-nano-php", "2025") is None

    def test_rejects_non_mcr_bases(self) -> None:
        with pytest.raises(rm.RegistryError):
            rm.Registries(self._fetch({})).base("docker.io/library/ubuntu:24.04")


def test_discovery_honours_a_narrowed_version_list(tmp_path) -> None:
    (tmp_path / ".github" / "workflows").mkdir(parents=True)
    (tmp_path / ".github" / "workflows" / "x.yml").write_text(
        "jobs:\n"
        "  build:\n"
        "    uses: ./.github/workflows/build-windows-image.yml\n"
        "    with:\n"
        "      context: nano-server/nano-server-x\n"
        "      image: windows-nano-x\n"
        '      windows-versions: \'["2022", "2025"]\'\n',
        encoding="utf-8",
    )
    (tmp_path / "nano-server" / "nano-server-x").mkdir(parents=True)
    (tmp_path / "nano-server" / "nano-server-x" / "Dockerfile").write_text(
        "ARG WINDOWS_VERSION=2025\nARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64\n",
        encoding="utf-8",
    )
    (spec,) = rm.discover_images(tmp_path)
    assert sorted(spec.bases) == ["2022", "2025"]


def test_refresh_never_plans_a_version_an_image_doesnt_build() -> None:
    spec = rm.ImageSpec(
        context="nano-server/nano-server-x",
        image="windows-nano-x",
        workflow="x.yml",
        bases={v: f"mcr.microsoft.com/windows/nanoserver:ltsc{v}-amd64" for v in ("2022", "2025")},
    )
    (entry,) = rm.plan_refresh([spec], FakeRegistries({}), never_changed, force=True)
    assert json.loads(entry["windows-versions"]) == ["2022", "2025"]


# --- Robustness (the first refresh runs failed on Docker Hub's 401 for repositories never pushed) ---

HUB_TOKEN_URL = (
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:zippy1981/windows-nano-far:pull"
)
HUB_MANIFEST_URL = "https://registry-1.docker.io/v2/zippy1981/windows-nano-far/manifests/2019"
# What Docker Hub really returns for zippy1981/windows-nano-far, which has never been pushed
NEVER_PUSHED = {
    "errors": [
        {
            "code": "UNAUTHORIZED",
            "message": "authentication required",
            "detail": [{"Type": "repository", "Name": "zippy1981/windows-nano-far", "Action": "pull"}],
        }
    ]
}


def scripted_fetch(responses: dict[str, list[tuple[int, dict[str, str], object]]]) -> rm.Fetch:
    """Each URL returns its queued responses in order; an exception in the queue is raised."""

    def fetch(url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
        status, response_headers, body = responses[url].pop(0)
        if isinstance(body, Exception):
            raise body
        return status, response_headers, json.dumps(body).encode()

    return fetch


def no_sleep(seconds: float) -> None:
    pass


def test_never_pushed_repository_counts_as_not_published() -> None:
    registries = rm.Registries(
        scripted_fetch({HUB_TOKEN_URL: [(200, {}, {"token": "t"})], HUB_MANIFEST_URL: [(401, {}, NEVER_PUSHED)]}),
        sleep=no_sleep,
    )
    assert registries.published_labels("windows-nano-far", "2019") is None


def test_other_401s_are_still_errors() -> None:
    registries = rm.Registries(
        scripted_fetch(
            {
                HUB_TOKEN_URL: [(200, {}, {"token": "t"})],
                HUB_MANIFEST_URL: [(401, {}, {"errors": [{"code": "DENIED", "message": "nope"}]})],
            }
        ),
        sleep=no_sleep,
    )
    with pytest.raises(rm.RegistryError):
        registries.published_labels("windows-nano-far", "2019")


def test_rate_limits_and_network_errors_are_retried() -> None:
    sleeps: list[float] = []
    registries = rm.Registries(
        scripted_fetch(
            {
                HUB_TOKEN_URL: [(0, {}, OSError("connection reset")), (200, {}, {"token": "t"})],
                HUB_MANIFEST_URL: [(429, {"retry-after": "3"}, {}), (404, {}, {})],
            }
        ),
        sleep=sleeps.append,
    )
    assert registries.published_labels("windows-nano-far", "2019") is None
    assert sleeps == [1, 3.0]


def test_retries_give_up_after_the_last_attempt() -> None:
    registries = rm.Registries(scripted_fetch({HUB_TOKEN_URL: [(503, {}, {})] * rm.RETRY_ATTEMPTS}), sleep=no_sleep)
    with pytest.raises(rm.RegistryError, match="503"):
        registries.published_labels("windows-nano-far", "2019")


class FlakyRegistries(FakeRegistries):
    def __init__(self, broken_bases: set[str] = frozenset(), broken_hub: set[str] = frozenset()) -> None:
        super().__init__({})
        self.broken_bases, self.broken_hub = broken_bases, broken_hub

    def base(self, reference: str) -> rm.BaseImage:
        if any(v in reference for v in self.broken_bases):
            raise rm.RegistryError("MCR down")
        return super().base(reference)

    def published_labels(self, image: str, tag: str) -> dict[str, str] | None:
        if tag in self.broken_hub:
            raise rm.RegistryError("Docker Hub 500")
        return current()


def test_an_unreadable_published_image_is_rebuilt_not_fatal() -> None:
    warnings: list[str] = []
    (entry,) = rm.plan_refresh([SPEC], FlakyRegistries(broken_hub={"2022"}), never_changed, warnings=warnings)
    assert entry["reasons"] == {"2022": "unknown-published-state"}
    assert len(warnings) == 1 and "2022" in warnings[0]


def test_a_failed_base_lookup_skips_only_that_leg() -> None:
    warnings: list[str] = []
    entries = rm.plan_refresh(
        [SPEC], FlakyRegistries(broken_bases={"2019"}), never_changed, force=True, warnings=warnings
    )
    (entry,) = entries
    assert json.loads(entry["windows-versions"]) == ["2022", "2025"]
    assert "base image lookup failed" in warnings[0]


def test_summary_lists_warnings() -> None:
    assert "### Warnings" in rm.summary_markdown([], ["windows-nano-far 2019: skipped"])


def test_a_failed_git_history_check_rebuilds_that_leg() -> None:
    import subprocess

    def broken_git(revision: str, context: str) -> bool:
        raise subprocess.CalledProcessError(128, ["git", "log"])

    warnings: list[str] = []
    (entry,) = rm.plan_refresh([SPEC], FakeRegistries(all_current()), broken_git, warnings=warnings)
    assert set(entry["reasons"].values()) == {"source-changed"}
    assert len(warnings) == 3 and all("git history check failed" in w for w in warnings)


def test_publish_step_retries_and_continues_after_a_failed_push() -> None:
    from repo_conventions import REUSABLE_WORKFLOW, jobs, workflows

    (job,) = jobs(workflows()[REUSABLE_WORKFLOW]).values()
    publish = next(s["run"] for s in job["steps"] if "docker push" in s.get("run", ""))
    assert "Invoke-WithRetry" in publish, "pushes must be retried"
    assert "$failed +=" in publish, "a failed tag must be recorded and the loop must go on to the next tag"
    assert "| Out-Host" in publish, "the retried command's output must not become the function's return value"


# --- Variant images (ADR 0005, amended) ---


class TestMatrixExpansion:
    def test_include_only(self) -> None:
        combos = rm.matrix_combinations({"matrix": {"include": [{"go": "1"}, {"go": "2"}]}})
        assert combos == [{"go": "1"}, {"go": "2"}]

    def test_product_extended_by_include_and_reduced_by_exclude(self) -> None:
        strategy = {
            "matrix": {
                "go": ["1", "2"],
                "cgo": ["0", "1"],
                "include": [{"go": "1", "prefix": "one"}, {"go": "3", "cgo": "0"}],
                "exclude": [{"go": "2", "cgo": "1"}],
            }
        }
        combos = rm.matrix_combinations(strategy)
        assert {"go": "1", "cgo": "0", "prefix": "one"} in combos
        assert {"go": "1", "cgo": "1", "prefix": "one"} in combos
        assert {"go": "2", "cgo": "1"} not in combos
        assert {"go": "3", "cgo": "0"} in combos

    def test_no_strategy_is_one_combination(self) -> None:
        assert rm.matrix_combinations(None) == [{}]

    def test_render_keeps_the_type_of_a_whole_expression(self) -> None:
        assert rm.render("${{ matrix.plain }}", {"plain": True}) is True
        assert rm.render('{"GO_VERSION": "${{ matrix.go }}"}', {"go": "1.26.10"}) == '{"GO_VERSION": "1.26.10"}'
        assert rm.render("x-${{ matrix.flag }}", {"flag": False}) == "x-false"


def variant(prefix: str, plain: bool = False) -> rm.ImageSpec:
    return rm.ImageSpec(
        "nano-server/nano-server-go",
        "windows-nano-go",
        "go-container.yml",
        {"2025": "mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64"},
        build_args=f'{{"GO_VERSION": "{prefix}"}}',
        variant=f"go{prefix}",
        tag_prefix=prefix,
        also_plain_tags=plain,
    )


class TestVariants:
    def test_published_tag_has_the_prefix(self) -> None:
        assert variant("1.26.10").published_tag("2025") == "1.26.10-2025"
        assert SPEC.published_tag("2025") == "2025"

    def test_go_is_discovered_as_one_spec_per_version(self) -> None:
        go = [s for s in rm.discover_images() if s.image == "windows-nano-go"]
        assert len(go) >= 3
        assert sum(s.also_plain_tags for s in go) == 1
        # The prefix starts with the Go version it builds; the -cgo variant also builds with CGO=1 (ADR 0013)
        assert all(s.tag_prefix and s.tag_prefix.split("-")[0] in s.build_args for s in go)
        assert all(('"CGO": "1"' in s.build_args) == s.tag_prefix.endswith("-cgo") for s in go)

    def test_duplicate_prefixes_are_rejected(self) -> None:
        with pytest.raises(ValueError, match="tag-prefix"):
            rm.check_variants([variant("1.27.3", True), variant("1.27.3")])

    def test_exactly_one_variant_owns_the_plain_tags(self) -> None:
        with pytest.raises(ValueError, match="also-plain-tags"):
            rm.check_variants([variant("1.27.3"), variant("1.26.10")])
        with pytest.raises(ValueError, match="also-plain-tags"):
            rm.check_variants([variant("1.27.3", True), variant("1.26.10", True)])

    def test_detection_reads_each_variants_own_tag_and_passes_its_inputs(self) -> None:
        seen: list[tuple[str, str]] = []

        class Recording(FakeRegistries):
            def published_labels(self, image: str, tag: str) -> dict[str, str] | None:
                seen.append((image, tag))
                return None

        (entry,) = rm.plan_refresh([variant("1.26.10")], Recording({}), never_changed)
        assert seen == [("windows-nano-go", "1.26.10-2025")]
        assert entry["tag-prefix"] == "1.26.10" and entry["also-plain-tags"] is False
        assert entry["variant"] == "go1.26.10" and json.loads(entry["build-args"]) == {"GO_VERSION": "1.26.10"}
