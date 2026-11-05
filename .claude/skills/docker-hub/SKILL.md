---
name: docker-hub
description: Interact with this repo's Docker Hub images (zippy1981/windows-nano-*). Read-only lookups that need no login (does an image or tag exist, which tags are published, sizes, OCI labels such as the base digest and source revision, pull rate limit), plus guarded write operations (login, push, delete a tag, update a description) that need the user's explicit go-ahead. Use when checking what is published, debugging the image refresh, or before any manual push.
---

# Docker Hub

This repo publishes its images to Docker Hub as `zippy1981/<image>:<tag>`, for example `zippy1981/windows-nano-php:2025`. Only the image refresh workflow publishes, from `main` ([ADR 0006](../../../docs/adr/0006-publish-to-docker-hub-only-from-main-via-scheduled-workflow.md)). The tags follow [ADR 0005](../../../docs/adr/0005-tagging-scheme-for-windows-images.md): `:<ver>`, `:<ver>-<os-build>`, `:<ver>-YYYY-MM` and `:<ver>-<os-build>-<sha7>`.

Everything in "Read-only lookups" is safe to run at any time. Everything in "Write operations" changes what other people pull. **Do it only when the user explicitly asks, and confirm the exact repository and tags first.**

## Read-only lookups

These use Docker Hub's public APIs and need no login. The examples are PowerShell. On this Windows host `python3` is only the Microsoft Store stub, so don't rely on it for parsing JSON. If you're on bash, use `curl` and `uv run --no-project python -c ...`.

### List the account's repositories

```pwsh
(Invoke-RestMethod 'https://hub.docker.com/v2/repositories/zippy1981/?page_size=100').results |
    Select-Object name, is_private, pull_count, last_updated
```

### List an image's tags

```pwsh
(Invoke-RestMethod 'https://hub.docker.com/v2/repositories/zippy1981/windows-nano-php/tags?page_size=100').results |
    Select-Object name, full_size, last_updated
```

A repository that has never been pushed returns 404 from this API, so `Invoke-RestMethod` throws. Treat that as "not published".

### Read an image's labels and digest

Labels such as `org.opencontainers.image.base.digest` and `org.opencontainers.image.revision` live in the image config, which comes from the registry API. Get an anonymous pull token first:

```pwsh
$repo = 'zippy1981/windows-nano-php'; $tag = '2025'
$token = (Invoke-RestMethod "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull").token
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' }
$manifest = Invoke-RestMethod "https://registry-1.docker.io/v2/$repo/manifests/$tag" -Headers $headers
# For an index (multi-platform), pick the windows/amd64 entry and fetch that manifest first
$config = Invoke-RestMethod "https://registry-1.docker.io/v2/$repo/blobs/$($manifest.config.digest)" -Headers @{ Authorization = "Bearer $token" }
$config.config.Labels
$config.'os.version'
```

**A never-pushed repository returns 401, not 404.** The registry answers a pull for it with `401 {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}`, so it doesn't reveal whether a private repository exists. A 401 with code `UNAUTHORIZED` (or `NAME_UNKNOWN`, `MANIFEST_UNKNOWN`) means "not published", not "bad credentials". `scripts/refresh_matrix.py` handles it this way, so reuse its `Registries.published_labels` instead of writing new code:

```bash
uv run python -c "import sys; sys.path.insert(0, 'scripts'); import refresh_matrix as rm; print(rm.Registries().published_labels('windows-nano-php', '2025'))"
```

### See what the image refresh would rebuild

```bash
UV_PYTHON=3.14 UV_PYTHON_PREFERENCE=only-managed uv run python scripts/refresh_matrix.py
```

The script prints one entry per image that needs work, with a reason for each Windows version: `missing`, `base-changed`, `source-changed`, `forced` or `unknown-published-state`.

### Check the pull rate limit

Anonymous pulls are limited per IP address. Docker's test repository reports what's left without counting against the limit:

```pwsh
$token = (Invoke-RestMethod 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull').token
(Invoke-WebRequest -Method Head 'https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest' -Headers @{ Authorization = "Bearer $token" }).Headers['ratelimit-remaining']
```

The answer is `remaining;w=<window seconds>`, for example `98;w=3600`.

### Badges

The root README uses shields.io badges such as `https://img.shields.io/docker/image-size/zippy1981/<image>/<tag>`. They read "repository or tag not found" until a tag is published.

## Write operations (only on an explicit request)

**Pushing is public and hard to undo, because people may already have pulled a tag.** Prefer letting the image refresh workflow publish: push or merge to `main`, or dispatch it with `gh workflow run image-refresh.yml -f images=<folder> -f force=true`. For a manual push, use the `windows-image-publisher` agent, which follows the checklist below.

1. **Credentials:**
   - Use a Docker Hub personal access token, never the account password.
   - CI reads `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` from the `Docker Hub zippy1981` GitHub environment, which only `main` can use.
   - On a developer machine, ask the user to log in themselves (`! docker login`). Never handle the token yourself.
2. **Log in to a throwaway config directory**, so the credential doesn't linger. This is what the shared workflow does:

   ```pwsh
   $env:DOCKER_CONFIG = Join-Path $env:TEMP "docker-config-$([guid]::NewGuid().ToString('n'))"
   $env:DOCKERHUB_TOKEN | docker login --username $env:DOCKERHUB_USERNAME --password-stdin
   # ... docker push ...
   docker logout; Remove-Item -Recurse -Force $env:DOCKER_CONFIG
   ```

3. **Push only tested images**, with the ADR 0005 tags. Windows base layers are "foreign layers" that Docker Hub doesn't store, and pulls fetch them from MCR, so don't treat skipped base layers as an error.
4. **New repositories:** the first push of a repository creates it, with the account's default visibility. Check the result with "List the account's repositories" above.
5. **Deleting tags or changing a repository's description or visibility** goes through the Hub API (`https://hub.docker.com/v2/repositories/zippy1981/<image>/tags/<tag>/` with `DELETE`) and needs a login token from `POST https://hub.docker.com/v2/users/login`. Confirm each tag with the user before deleting anything, never delete the moving `:<ver>` tags, and prefer deleting only immutable `:<ver>-<os-build>-<sha7>` tags from failed experiments.

## Related

- [`windows-image-publisher` agent](../../agents/windows-image-publisher.md): manual pushes
- [`.github/workflows/image-refresh.yml`](../../../.github/workflows/image-refresh.yml) and [`scripts/refresh_matrix.py`](../../../scripts/refresh_matrix.py): automated detection and publishing
- [Docker Hub API reference](https://docs.docker.com/reference/api/hub/latest/)
- [Docker Hub usage and rate limits](https://docs.docker.com/docker-hub/usage/)
