"""Every Dockerfile says what the image is and how to build it, and documents each build argument where it is declared.

The format is in the dockerfile-docs skill (.claude/skills/dockerfile-docs/SKILL.md).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from repo_conventions import image_context, image_dirs

IMAGES = image_dirs()
ARG = re.compile(r"^ARG\s+([A-Za-z_][A-Za-z0-9_]*)")


def raw_lines(image_dir: Path) -> list[str]:
    return (image_dir / "Dockerfile").read_text(encoding="utf-8").splitlines()


def header(lines: list[str]) -> list[str]:
    """The comment block at the top of the file, up to the first blank line or instruction."""
    block = []
    for line in lines:
        if not line.startswith("#"):
            break
        block.append(line)
    return block


def first_declarations(image_dir: Path) -> list[tuple[str, list[str]]]:
    """(name, the comment block directly above it) for the first ARG of each name. A later ARG of the same name only
    brings an earlier one into a build stage, so it needs no comment of its own."""
    lines, seen, found = raw_lines(image_dir), set(), []
    for n, line in enumerate(lines):
        match = ARG.match(line)
        if not match or match.group(1) in seen:
            continue
        seen.add(match.group(1))
        comments = []
        for above in reversed(lines[:n]):
            if not above.startswith("#"):
                break
            comments.insert(0, above)
        found.append((match.group(1), comments))
    return found


ARGS = [(image_dir, name, comments) for image_dir in IMAGES for name, comments in first_declarations(image_dir)]


@pytest.mark.parametrize("image_dir", IMAGES, ids=image_context)
class TestDockerfileHeader:
    def test_starts_with_a_description(self, image_dir: Path) -> None:
        block = header(raw_lines(image_dir))
        first = block[0] if block else ""
        assert re.match(r"^# [\w.-]+: \S.{20,}", first), (
            f"{image_context(image_dir)}/Dockerfile must start with '# <image name>: <what the image is>', "
            f"not {first!r} (dockerfile-docs skill)"
        )

    def test_header_shows_how_to_build_it(self, image_dir: Path) -> None:
        block = "\n".join(header(raw_lines(image_dir)))
        assert "docker build" in block and "--build-arg" in block, (
            f"{image_context(image_dir)}/Dockerfile's header needs a `docker build --build-arg ...` example"
        )


@pytest.mark.parametrize(("image_dir", "name", "comments"), ARGS, ids=[f"{image_context(d)}:{n}" for d, n, _ in ARGS])
class TestBuildArguments:
    def test_is_described_where_it_is_declared(self, image_dir: Path, name: str, comments: list[str]) -> None:
        assert comments, (
            f"{image_context(image_dir)}/Dockerfile: put a comment directly above ARG {name} saying what it is"
        )

    def test_says_how_to_set_it(self, image_dir: Path, name: str, comments: list[str]) -> None:
        assert any(f"--build-arg {name}=" in line for line in comments), (
            f"{image_context(image_dir)}/Dockerfile: the comment above ARG {name} must show how to set it, "
            f"for example '# Set with --build-arg {name}=<example>.'"
        )
