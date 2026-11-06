"""Get-ArtifactCacheEntry.ps1 is tied to the cache versions pinned in its Dockerfile (issue #61).

The script hand-parses Souin's simplefs protobuf indexes, which is only safe for the
cache-handler and simplefs versions it was validated against. When a pin changes,
these tests fail so the parser and its fixtures get re-checked before the bump lands.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
IMAGE_DIR = REPO_ROOT / "nano-server" / "nano-server-artifact-cache"
SCRIPT = IMAGE_DIR / "Get-ArtifactCacheEntry.ps1"


def dockerfile_pin(name: str) -> str:
    match = re.search(rf"^\s*{name}=(\S+)", (IMAGE_DIR / "Dockerfile").read_text(encoding="utf-8"), re.MULTILINE)
    assert match, f"{name} is not pinned in the artifact-cache Dockerfile"
    return match.group(1)


def script_validated(name: str) -> str:
    match = re.search(rf"\$script:{name} = '([^']+)'", SCRIPT.read_text(encoding="utf-8"))
    assert match, f"{name} is not recorded in Get-ArtifactCacheEntry.ps1"
    return match.group(1)


def test_validated_cache_handler_matches_the_dockerfile_pin() -> None:
    assert script_validated("ValidatedCacheHandlerVersion") == dockerfile_pin("CACHE_HANDLER_VERSION")


def test_validated_simplefs_matches_the_dockerfile_pin() -> None:
    assert script_validated("ValidatedSimplefsVersion") == dockerfile_pin("SIMPLEFS_VERSION")


def test_pester_tests_and_fixtures_exist() -> None:
    tests = IMAGE_DIR / "Get-ArtifactCacheEntry.Tests.ps1"
    assert tests.is_file(), "Get-ArtifactCacheEntry.Tests.ps1 is missing"
    cache = IMAGE_DIR / "fixtures" / "cache"
    payloads = [p for p in cache.iterdir() if p.is_file()]
    assert len(payloads) >= 4, "fixtures need at least a fresh, a stale, an expired and an orphan payload"
    indexes = list((cache / ".simplefs-index").iterdir())
    assert len(indexes) >= 3, "fixtures need index files for the indexed payloads"
