"""Work out which images need rebuilding after a base image update (plans/patch-tuesday-image-refresh.md).

For every image (a workflow job that calls the shared build workflow) and every Windows version it compares:

- the current digest of its Microsoft base image on MCR with the base digest label on the published Docker Hub image
- the image folder's commits with the revision label on the published image

It prints a JSON list with one entry per image that needs work, in the shape that image-refresh.yml feeds to
build-windows-image.yml. The base image is pinned to the detected digest, so the build uses exactly what was detected
even if MCR moves the tag mid-run (ADR 0004).

    uv run python scripts/refresh_matrix.py [--force] [--images nano-server-php,nano-server-go] [--github-output]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
REUSABLE_WORKFLOW_REF = "./.github/workflows/build-windows-image.yml"
WINDOWS_VERSIONS = ("2019", "2022", "2025")
DOCKER_HUB_NAMESPACE = "zippy1981"

MCR_REGISTRY = "https://mcr.microsoft.com"
MCR_PREFIX = "mcr.microsoft.com/"
HUB_REGISTRY = "https://registry-1.docker.io"
HUB_AUTH = "https://auth.docker.io/token"
BASE_DIGEST_LABEL = "org.opencontainers.image.base.digest"
REVISION_LABEL = "org.opencontainers.image.revision"

MANIFEST_ACCEPT = (
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json, "
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json"
)
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
BASE_IMAGE_ARG = re.compile(
    r"^ARG BASE_IMAGE=mcr\.microsoft\.com/windows/(nanoserver|servercore):ltsc\$\{WINDOWS_VERSION\}-amd64\s*$",
    re.MULTILINE,
)
TIMEOUT_SECONDS = 30

# (url, headers) -> (status, headers with lower-case keys, body)
Fetch = Callable[[str, dict[str, str]], tuple[int, dict[str, str], bytes]]


def http_fetch(url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read()
    except urllib.error.HTTPError as error:
        return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read()


@dataclass(frozen=True)
class BaseImage:
    reference: str  # mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64
    digest: str
    os_version: str

    @property
    def pinned(self) -> str:
        return f"{self.reference}@{self.digest}"


@dataclass(frozen=True)
class ImageSpec:
    context: str
    image: str
    workflow: str
    bases: dict[str, str]  # Windows version -> base image reference, without digest


class RegistryError(RuntimeError):
    pass


class Registries:
    """Reads manifests and image configs from MCR (anonymous) and Docker Hub (anonymous pull token)."""

    def __init__(self, fetch: Fetch = http_fetch) -> None:
        self._fetch = fetch
        self._bases: dict[str, BaseImage] = {}

    def _get_json(self, url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], Any]:
        status, response_headers, body = self._fetch(url, headers)
        if status == 404:
            return status, response_headers, None
        if status != 200:
            raise RegistryError(f"GET {url} returned {status}")
        return status, response_headers, json.loads(body)

    def _config(
        self, registry: str, repository: str, reference: str, headers: dict[str, str]
    ) -> tuple[str, Any] | None:
        """The manifest digest and the image config for one image, resolving an index to windows/amd64."""
        auth = dict(headers, Accept=MANIFEST_ACCEPT)
        _, response_headers, manifest = self._get_json(f"{registry}/v2/{repository}/manifests/{reference}", auth)
        if manifest is None:
            return None
        digest = response_headers.get("docker-content-digest", "")
        if manifest.get("mediaType") in INDEX_TYPES:
            entry = next(
                (
                    m
                    for m in manifest["manifests"]
                    if m.get("platform", {}).get("os") == "windows" and m["platform"].get("architecture") == "amd64"
                ),
                None,
            )
            if entry is None:
                raise RegistryError(f"{repository}:{reference} has no windows/amd64 image")
            digest = entry["digest"]
            _, _, manifest = self._get_json(f"{registry}/v2/{repository}/manifests/{digest}", auth)
        _, _, config = self._get_json(f"{registry}/v2/{repository}/blobs/{manifest['config']['digest']}", headers)
        return digest, config

    def base(self, reference: str) -> BaseImage:
        if reference in self._bases:
            return self._bases[reference]
        if not reference.startswith(MCR_PREFIX) or ":" not in reference:
            raise RegistryError(f"only tagged MCR base images are supported, not {reference}")
        repository, tag = reference.removeprefix(MCR_PREFIX).rsplit(":", 1)
        found = self._config(MCR_REGISTRY, repository, tag, {})
        if found is None:
            raise RegistryError(f"{reference} not found on MCR")
        digest, config = found
        if not digest:
            raise RegistryError(f"MCR returned no digest for {reference}")
        base = BaseImage(reference, digest, config.get("os.version", ""))
        self._bases[reference] = base
        return base

    def published_labels(self, image: str, tag: str) -> dict[str, str] | None:
        """Labels of zippy1981/<image>:<tag> on Docker Hub, or None if it hasn't been published."""
        repository = f"{DOCKER_HUB_NAMESPACE}/{image}"
        _, _, token = self._get_json(f"{HUB_AUTH}?service=registry.docker.io&scope=repository:{repository}:pull", {})
        if token is None:
            return None
        found = self._config(HUB_REGISTRY, repository, tag, {"Authorization": f"Bearer {token['token']}"})
        if found is None:
            return None
        _, config = found
        return (config.get("config") or {}).get("Labels") or {}


def load_workflow(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    # PyYAML follows YAML 1.1, which reads the bare key `on` as the boolean True
    if True in data:
        data["on"] = data.pop(True)
    return data


def discover_images(root: Path = REPO_ROOT) -> list[ImageSpec]:
    """Every image built through the shared workflow, with its base image per Windows version."""
    specs: list[ImageSpec] = []
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        for job in (load_workflow(path).get("jobs") or {}).values():
            if job.get("uses") != REUSABLE_WORKFLOW_REF:
                continue
            inputs = job.get("with") or {}
            context = str(inputs.get("context", ""))
            if "${{" in context:
                continue  # image-refresh.yml itself, which calls the shared workflow from this script's output
            dockerfile = (root / context / "Dockerfile").read_text(encoding="utf-8")
            match = BASE_IMAGE_ARG.search(dockerfile)
            if not match:
                raise ValueError(f"{context}/Dockerfile doesn't declare the BASE_IMAGE argument (ADR 0008)")
            overrides = json.loads(inputs.get("base-image-overrides") or "{}")
            bases = {
                version: overrides.get(version, f"{MCR_PREFIX}windows/{match.group(1)}:ltsc{version}-amd64")
                for version in WINDOWS_VERSIONS
            }
            specs.append(ImageSpec(context, str(inputs["image"]), path.name, bases))
    return specs


def git_changed_since(revision: str, context: str, root: Path = REPO_ROOT) -> bool:
    """True if the folder changed after revision, or if revision isn't in this clone's history."""
    known = subprocess.run(
        ["git", "cat-file", "-e", f"{revision}^{{commit}}"], cwd=root, capture_output=True, check=False
    )
    if known.returncode != 0:
        return True
    log = subprocess.run(
        ["git", "log", "--format=%H", f"{revision}..HEAD", "--", context],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    return bool(log.stdout.strip())


def plan_refresh(
    specs: Iterable[ImageSpec],
    registries: Registries,
    changed_since: Callable[[str, str], bool] = git_changed_since,
    force: bool = False,
    only: set[str] | None = None,
) -> list[dict[str, Any]]:
    """One matrix entry per image that has at least one Windows version to rebuild."""
    entries: list[dict[str, Any]] = []
    for spec in specs:
        if only and spec.context not in only:
            continue
        versions: list[str] = []
        pinned: dict[str, str] = {}
        reasons: dict[str, str] = {}
        os_versions: dict[str, str] = {}
        for version in WINDOWS_VERSIONS:
            base = registries.base(spec.bases[version])
            reason = None
            if force:
                reason = "forced"
            else:
                labels = registries.published_labels(spec.image, version)
                if labels is None:
                    reason = "missing"
                elif labels.get(BASE_DIGEST_LABEL) != base.digest:
                    reason = "base-changed"
                elif not labels.get(REVISION_LABEL) or changed_since(labels[REVISION_LABEL], spec.context):
                    reason = "source-changed"
            if reason:
                versions.append(version)
                pinned[version] = base.pinned
                reasons[version] = reason
                os_versions[version] = base.os_version
        if versions:
            entries.append(
                {
                    "context": spec.context,
                    "image": spec.image,
                    # Strings, because build-windows-image.yml takes them as JSON-string inputs
                    "windows-versions": json.dumps(versions),
                    "base-image-overrides": json.dumps(pinned),
                    "reasons": reasons,
                    "os-versions": os_versions,
                }
            )
    return entries


def summary_markdown(entries: list[dict[str, Any]]) -> str:
    if not entries:
        return "## Image refresh\n\nNothing to rebuild: every published image matches its base image and source.\n"
    lines = [
        "## Image refresh",
        "",
        "| Image | Windows | Reason | Base OS build |",
        "| --- | --- | --- | --- |",
    ]
    for entry in entries:
        for version, reason in entry["reasons"].items():
            lines.append(f"| `{entry['image']}` | {version} | {reason} | {entry['os-versions'][version]} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="rebuild every image and version")
    parser.add_argument("--images", default="", help="comma-separated image folders to consider (default: all)")
    parser.add_argument(
        "--github-output",
        action="store_true",
        help="also write matrix=<json> to $GITHUB_OUTPUT and a summary to $GITHUB_STEP_SUMMARY",
    )
    args = parser.parse_args(argv)

    only = {name.strip() for name in args.images.split(",") if name.strip()} or None
    try:
        entries = plan_refresh(discover_images(), Registries(), force=args.force, only=only)
    except (RegistryError, ValueError) as error:
        print(f"refresh_matrix: {error}", file=sys.stderr)
        return 1

    matrix = json.dumps(entries)
    print(json.dumps(entries, indent=2))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"matrix={matrix}\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(summary_markdown(entries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
