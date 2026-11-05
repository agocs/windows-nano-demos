"""Images live in the directory for their base and are published under the matching name (ADR 0012)."""

from __future__ import annotations

from pathlib import Path

import pytest
from repo_conventions import (
    BASE_IMAGE_ARG,
    HUB_PREFIXES,
    IMAGE_PARENTS,
    callers_of_reusable,
    dockerfile_lines,
    image_context,
    image_dirs,
    top_level_image_dirs,
)


def test_no_images_in_the_repo_root() -> None:
    assert not top_level_image_dirs(), (
        f"move {[p.name for p in top_level_image_dirs()]} under {sorted(IMAGE_PARENTS)} (ADR 0012)"
    )


@pytest.mark.parametrize("image_dir", image_dirs(), ids=image_context)
class TestImageLayout:
    def test_folder_name_starts_with_its_directory(self, image_dir: Path) -> None:
        parent = image_dir.parent.name
        assert image_dir.name.startswith(f"{parent}-"), f"{image_context(image_dir)} must be named {parent}-<name>"

    def test_directory_matches_the_base_image(self, image_dir: Path) -> None:
        bases = {m.group(1) for line in dockerfile_lines(image_dir) if (m := BASE_IMAGE_ARG.match(line))}
        wanted = IMAGE_PARENTS[image_dir.parent.name]
        assert bases == {wanted}, (
            f"{image_context(image_dir)} defaults BASE_IMAGE to {bases or 'nothing'}, so it belongs under "
            f"{[d for d, b in IMAGE_PARENTS.items() if b in bases] or 'a base directory'}, not {image_dir.parent.name}/"
        )

    def test_published_name_matches_the_directory(self, image_dir: Path) -> None:
        parent = image_dir.parent.name
        wanted = HUB_PREFIXES[parent] + image_dir.name.removeprefix(f"{parent}-")
        images = {
            str(job["with"].get("image"))
            for _, _, job in callers_of_reusable()
            if job.get("with", {}).get("context") == image_context(image_dir)
        }
        assert images == {wanted}, f"{image_context(image_dir)} must be published as {wanted}, not {images}"
