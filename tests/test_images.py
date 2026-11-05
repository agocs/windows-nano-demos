"""Every image takes the Windows version as a build argument and defaults to 2025 (ADR 0008)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from repo_conventions import (
    BASE_IMAGE_ARG,
    DEFAULT_WINDOWS_VERSION,
    dockerfile_lines,
    image_dirs,
)

IMAGES = image_dirs()


def test_images_exist() -> None:
    assert IMAGES, "no image folders found"


@pytest.mark.parametrize("image_dir", IMAGES, ids=lambda p: p.name)
class TestDockerfile:
    def _global_args(self, image_dir: Path) -> list[str]:
        lines = dockerfile_lines(image_dir)
        first_from = next(i for i, line in enumerate(lines) if line.upper().startswith("FROM "))
        return lines[:first_from]

    def test_windows_version_argument_defaults_to_2025(self, image_dir: Path) -> None:
        args = self._global_args(image_dir)
        assert f"ARG WINDOWS_VERSION={DEFAULT_WINDOWS_VERSION}" in args, (
            f"{image_dir.name}/Dockerfile must declare ARG WINDOWS_VERSION={DEFAULT_WINDOWS_VERSION} before its first FROM"
        )

    def test_base_image_argument_follows_the_version(self, image_dir: Path) -> None:
        args = self._global_args(image_dir)
        assert any(BASE_IMAGE_ARG.match(a) for a in args), (
            f"{image_dir.name}/Dockerfile must declare "
            "ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64 (or servercore) before its first FROM"
        )

    def test_windows_version_is_declared_before_base_image(self, image_dir: Path) -> None:
        args = self._global_args(image_dir)
        version = next(i for i, a in enumerate(args) if a.startswith("ARG WINDOWS_VERSION="))
        base = next(i for i, a in enumerate(args) if a.startswith("ARG BASE_IMAGE="))
        assert version < base

    def test_final_stage_is_the_base_image(self, image_dir: Path) -> None:
        froms = [line for line in dockerfile_lines(image_dir) if line.upper().startswith("FROM ")]
        assert re.fullmatch(r"FROM \$\{BASE_IMAGE\}( AS \S+)?", froms[-1], re.IGNORECASE), (
            f"{image_dir.name}/Dockerfile's last stage must be FROM ${{BASE_IMAGE}}, not {froms[-1]!r}"
        )

    def test_no_hardcoded_windows_version_in_from(self, image_dir: Path) -> None:
        hardcoded = [
            line
            for line in dockerfile_lines(image_dir)
            if line.upper().startswith("FROM ") and re.search(r"ltsc20\d\d", line)
        ]
        assert not hardcoded, f"{image_dir.name}/Dockerfile hardcodes a version: {hardcoded}"


@pytest.mark.parametrize("image_dir", IMAGES, ids=lambda p: p.name)
class TestBuildScript:
    def _script(self, image_dir: Path) -> str:
        path = image_dir / "build.cmd"
        assert path.is_file(), f"{image_dir.name}/build.cmd is missing"
        return path.read_text(encoding="utf-8")

    def test_defaults_windows_version_to_2025(self, image_dir: Path) -> None:
        assert re.search(
            rf'set "?WINDOWS_VERSION={DEFAULT_WINDOWS_VERSION}"?', self._script(image_dir), re.IGNORECASE
        ), f"{image_dir.name}/build.cmd must default WINDOWS_VERSION to {DEFAULT_WINDOWS_VERSION}"

    def test_passes_the_version_to_docker(self, image_dir: Path) -> None:
        assert re.search(
            r'--build-arg "?WINDOWS_VERSION=%WINDOWS_VERSION%"?', self._script(image_dir), re.IGNORECASE
        ), f"{image_dir.name}/build.cmd must pass --build-arg WINDOWS_VERSION=%WINDOWS_VERSION%"

    def test_forwards_base_image(self, image_dir: Path) -> None:
        assert re.search(r'--build-arg "?BASE_IMAGE=%BASE_IMAGE%"?', self._script(image_dir), re.IGNORECASE), (
            f"{image_dir.name}/build.cmd must pass BASE_IMAGE through when it's set"
        )
