"""Work out which images need rebuilding after a base image update (plans/patch-tuesday-image-refresh.md).

For every image (a workflow job that calls the shared build workflow) and every Windows version it compares:

- the current digest of its Microsoft base image on MCR with the base digest label on the published Docker Hub image
- the image folder's commits with the revision label on the published image

It prints a JSON list with one entry per image that needs work, in the shape that image-refresh.yml feeds to
build-windows-image.yml. The base image is pinned to the detected digest, so the build uses exactly what was detected
even if MCR moves the tag mid-run (ADR 0004).

    uv run python scripts/refresh_matrix.py [--force] [--images nano-server/nano-server-php,nano-server/nano-server-go] [--github-output]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
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

RETRY_ATTEMPTS = 4
RETRY_STATUSES = {429, 500, 502, 503, 504}
MAX_RETRY_AFTER = 60.0
# Registry error codes that mean the repository or tag doesn't exist (yet), as opposed to a real failure
NOT_PUBLISHED_CODES = {"UNAUTHORIZED", "NAME_UNKNOWN", "MANIFEST_UNKNOWN", "NOT_FOUND"}


def hub_not_published(status: int, body: bytes) -> bool:
    """Docker Hub returns 401 UNAUTHORIZED, not 404, for a repository that has never been pushed."""
    if status == 404:
        return True
    if status != 401:
        return False
    try:
        codes = {error.get("code") for error in json.loads(body).get("errors", [])}
    except (ValueError, AttributeError):
        return False
    return bool(codes & NOT_PUBLISHED_CODES)


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
    bases: dict[str, str]  # Windows version -> base image reference, without digest, for the versions it builds
    # Variant images (ADR 0005, amended): one spec per entry of the caller's matrix, such as each Go version
    build_args: str = "{}"  # JSON map passed to the shared workflow's build-args
    variant: str = ""  # CI tag disambiguator
    tag_prefix: str = ""  # published tags are <tag_prefix>-<ver>...; empty means the plain <ver>... tags
    also_plain_tags: bool = False  # the image's default variant also publishes the plain <ver>... tags

    def published_tag(self, version: str) -> str:
        """The moving tag this spec publishes for a Windows version, which detection reads labels from."""
        return f"{self.tag_prefix}-{version}" if self.tag_prefix else version


_MATRIX_EXPRESSION = re.compile(r"\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}")


def matrix_combinations(strategy: dict[str, Any] | None) -> list[dict[str, Any]]:
    """The combinations a job's strategy.matrix produces: the product of its keys, then include and exclude.

    This covers what this repo's workflows use. Like GitHub, an include entry extends every combination whose
    original keys it matches, and is added as a new combination if it matches none.
    """
    matrix = dict((strategy or {}).get("matrix") or {})
    includes = matrix.pop("include", []) or []
    excludes = matrix.pop("exclude", []) or []
    combos: list[dict[str, Any]] = [{}]
    for key, values in matrix.items():
        combos = [dict(combo, **{key: value}) for combo in combos for value in values]
    if not matrix:
        combos = []
    original_keys = set(matrix)
    for entry in includes:
        matching = [c for c in combos if all(c.get(k) == v for k, v in entry.items() if k in original_keys)]
        if matching and any(k in original_keys for k in entry):
            for combo in matching:
                combo.update({k: v for k, v in entry.items() if k not in original_keys})
        else:
            combos.append(dict(entry))
    combos = [c for c in combos if not any(all(c.get(k) == v for k, v in ex.items()) for ex in excludes)]
    return combos or [{}]


def render(value: Any, combo: dict[str, Any]) -> Any:
    """Substitute ${{ matrix.<key> }} in a workflow input. A value that is only one expression keeps its type."""
    if not isinstance(value, str):
        return value
    whole = _MATRIX_EXPRESSION.fullmatch(value.strip())
    if whole:
        return combo.get(whole.group(1), "")

    def text(match: re.Match[str]) -> str:
        found = combo.get(match.group(1), "")
        return str(found).lower() if isinstance(found, bool) else str(found)

    return _MATRIX_EXPRESSION.sub(text, value)


class RegistryError(RuntimeError):
    pass


class Registries:
    """Reads manifests and image configs from MCR (anonymous) and Docker Hub (anonymous pull token).

    Transient failures (network errors, 429 and 5xx) are retried with backoff. Docker Hub answers a pull for a
    repository that doesn't exist yet with 401 UNAUTHORIZED, not 404, so that counts as "not published".
    """

    def __init__(
        self, fetch: Fetch = http_fetch, sleep: Callable[[float], None] = time.sleep, attempts: int = RETRY_ATTEMPTS
    ) -> None:
        self._fetch = fetch
        self._sleep = sleep
        self._attempts = attempts
        self._bases: dict[str, BaseImage] = {}

    def _request(self, url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
        for attempt in range(1, self._attempts + 1):
            try:
                status, response_headers, body = self._fetch(url, headers)
            except OSError as error:  # URLError, timeouts and connection resets are all OSError
                if attempt == self._attempts:
                    raise RegistryError(f"GET {url} failed after {attempt} attempts: {error}") from error
                self._sleep(2 ** (attempt - 1))
                continue
            if status not in RETRY_STATUSES or attempt == self._attempts:
                return status, response_headers, body
            retry_after = response_headers.get("retry-after", "")
            self._sleep(min(float(retry_after), MAX_RETRY_AFTER) if retry_after.isdigit() else 2 ** (attempt - 1))
        raise AssertionError("unreachable")

    def _get_json(
        self,
        url: str,
        headers: dict[str, str],
        missing: Callable[[int, bytes], bool] = lambda status, body: status == 404,
    ) -> tuple[int, dict[str, str], Any]:
        status, response_headers, body = self._request(url, headers)
        if missing(status, body):
            return status, response_headers, None
        if status != 200:
            raise RegistryError(f"GET {url} returned {status}: {body[:200]!r}")
        return status, response_headers, json.loads(body)

    def _config(
        self,
        registry: str,
        repository: str,
        reference: str,
        headers: dict[str, str],
        missing: Callable[[int, bytes], bool] = lambda status, body: status == 404,
    ) -> tuple[str, Any] | None:
        """The manifest digest and the image config for one image, resolving an index to windows/amd64."""
        auth = dict(headers, Accept=MANIFEST_ACCEPT)
        _, response_headers, manifest = self._get_json(
            f"{registry}/v2/{repository}/manifests/{reference}", auth, missing
        )
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
        found = self._config(
            HUB_REGISTRY, repository, tag, {"Authorization": f"Bearer {token['token']}"}, hub_not_published
        )
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
            raw_inputs = job.get("with") or {}
            if "${{" in str(raw_inputs.get("context", "")) and "matrix.context" in str(raw_inputs.get("context")):
                continue  # image-refresh.yml itself, which calls the shared workflow from this script's output
            # A caller with a matrix (for example one entry per Go version) is one spec per combination
            for combo in matrix_combinations(job.get("strategy")):
                inputs = {key: render(value, combo) for key, value in raw_inputs.items()}
                context = str(inputs.get("context", ""))
                dockerfile = (root / context / "Dockerfile").read_text(encoding="utf-8")
                match = BASE_IMAGE_ARG.search(dockerfile)
                if not match:
                    raise ValueError(f"{context}/Dockerfile doesn't declare the BASE_IMAGE argument (ADR 0008)")
                overrides = json.loads(inputs.get("base-image-overrides") or "{}")
                # An image's workflow can narrow the versions it builds (ADR 0008 exceptions); never publish the others
                versions = json.loads(inputs.get("windows-versions") or json.dumps(list(WINDOWS_VERSIONS)))
                bases = {
                    version: overrides.get(version, f"{MCR_PREFIX}windows/{match.group(1)}:ltsc{version}-amd64")
                    for version in WINDOWS_VERSIONS
                    if version in versions
                }
                plain = inputs.get("also-plain-tags", False)
                specs.append(
                    ImageSpec(
                        context,
                        str(inputs["image"]),
                        path.name,
                        bases,
                        build_args=str(inputs.get("build-args") or "{}"),
                        variant=str(inputs.get("variant") or ""),
                        tag_prefix=str(inputs.get("tag-prefix") or ""),
                        also_plain_tags=plain is True or str(plain).lower() == "true",
                    )
                )
    check_variants(specs)
    return specs


def check_variants(specs: list[ImageSpec]) -> None:
    """Variants of one image must publish distinct tags, and exactly one of them owns the plain <ver> tags."""
    by_image: dict[str, list[ImageSpec]] = {}
    for spec in specs:
        by_image.setdefault(spec.image, []).append(spec)
    for image, group in by_image.items():
        if len(group) == 1:
            continue
        prefixes = [s.tag_prefix for s in group]
        if "" in prefixes or len(set(prefixes)) != len(prefixes):
            raise ValueError(f"{image}: every variant needs its own non-empty tag-prefix, got {prefixes}")
        owners = [s.tag_prefix for s in group if s.also_plain_tags]
        if len(owners) != 1:
            raise ValueError(f"{image}: exactly one variant must set also-plain-tags, got {owners or 'none'}")


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


def rebuild_reason(
    labels: dict[str, str] | None, base: BaseImage, spec: ImageSpec, changed_since: Callable[[str, str], bool]
) -> str | None:
    """Why a published leg needs rebuilding, or None if it's current."""
    if labels is None:
        return "missing"
    if labels.get(BASE_DIGEST_LABEL) != base.digest:
        return "base-changed"
    if not labels.get(REVISION_LABEL) or changed_since(labels[REVISION_LABEL], spec.context):
        return "source-changed"
    return None


def plan_refresh(
    specs: Iterable[ImageSpec],
    registries: Registries,
    changed_since: Callable[[str, str], bool] = git_changed_since,
    force: bool = False,
    only: set[str] | None = None,
    warnings: list[str] | None = None,
) -> list[dict[str, Any]]:
    """One matrix entry per image that has at least one Windows version to rebuild.

    One registry failure never stops detection for the other images. If the base image can't be resolved, that leg
    is skipped, because it can't be pinned. If the published image can't be read for a reason other than "not
    published", that leg is rebuilt, because rebuilding and republishing is harmless. Both are added to `warnings`.
    """
    warnings = warnings if warnings is not None else []
    entries: list[dict[str, Any]] = []
    for spec in specs:
        if only and spec.context not in only:
            continue
        versions: list[str] = []
        pinned: dict[str, str] = {}
        reasons: dict[str, str] = {}
        os_versions: dict[str, str] = {}
        for version in (v for v in WINDOWS_VERSIONS if v in spec.bases):
            try:
                base = registries.base(spec.bases[version])
            except RegistryError as error:
                warnings.append(f"{spec.image} {version}: skipped, base image lookup failed: {error}")
                continue
            if force:
                reason = "forced"
            else:
                try:
                    labels = registries.published_labels(spec.image, spec.published_tag(version))
                    reason = rebuild_reason(labels, base, spec, changed_since)
                except RegistryError as error:
                    warnings.append(f"{spec.image} {version}: rebuilding, published image unreadable: {error}")
                    reason = "unknown-published-state"
                except (subprocess.CalledProcessError, OSError) as error:
                    # The git history check failed (for example a shallow clone): rebuilding is the safe answer
                    warnings.append(f"{spec.image} {version}: rebuilding, git history check failed: {error}")
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
                    "build-args": spec.build_args,
                    "variant": spec.variant,
                    "tag-prefix": spec.tag_prefix,
                    "also-plain-tags": spec.also_plain_tags,
                    "reasons": reasons,
                    "os-versions": os_versions,
                }
            )
    return entries


def summary_markdown(entries: list[dict[str, Any]], warnings: list[str] | None = None) -> str:
    lines = ["## Image refresh", ""]
    if not entries:
        lines.append("Nothing to rebuild: every published image matches its base image and source.")
    else:
        lines += ["| Image | Windows | Reason | Base OS build |", "| --- | --- | --- | --- |"]
        for entry in entries:
            for version, reason in entry["reasons"].items():
                name = f"{entry['image']}:{entry['tag-prefix']}" if entry.get("tag-prefix") else entry["image"]
                lines.append(f"| `{name}` | {version} | {reason} | {entry['os-versions'][version]} |")
    if warnings:
        lines += ["", "### Warnings", ""] + [f"- {warning}" for warning in warnings]
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
    warnings: list[str] = []
    try:
        specs = discover_images()
        entries = plan_refresh(specs, Registries(), force=args.force, only=only, warnings=warnings)
    except (RegistryError, ValueError) as error:
        print(f"refresh_matrix: {error}", file=sys.stderr)
        return 1
    for warning in warnings:
        # GitHub Actions shows these as annotations on the run
        print(f"::warning::{warning}" if args.github_output else f"refresh_matrix: warning: {warning}", file=sys.stderr)

    matrix = json.dumps(entries)
    print(json.dumps(entries, indent=2))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"matrix={matrix}\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(summary_markdown(entries, warnings))
    legs = sum(len(spec.bases) for spec in specs if not only or spec.context in only)
    skipped = sum("base image lookup failed" in warning for warning in warnings)
    if legs and skipped == legs:
        print("refresh_matrix: no base image could be resolved, so nothing can be planned", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
