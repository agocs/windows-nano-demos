"""Tests for scripts/refresh_matrix.py. The registries are faked, so these run offline."""

from __future__ import annotations

import json

import pytest
import refresh_matrix as rm
from repo_conventions import image_dirs

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
    context="nano-server-php",
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
    assert rm.plan_refresh([SPEC], FakeRegistries({}), never_changed, force=True, only={"nano-server-go"}) == []


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
        assert contexts == {p.name for p in image_dirs()}

    def test_uses_the_dockerfile_default_base(self) -> None:
        far = next(s for s in rm.discover_images() if s.context == "nano-server-far")
        assert far.bases["2022"] == "mcr.microsoft.com/windows/servercore:ltsc2022-amd64"

    def test_applies_base_image_overrides(self) -> None:
        ssh = next(s for s in rm.discover_images() if s.context == "nano-server-ssh")
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
