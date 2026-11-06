# Artifact cache (Caddy) for nanoserver ltsc2025

A caching HTTPS proxy for build artifacts (issue #24, ADR 0013). It runs beside the GitHub Actions runners on the CI host, so image builds download Go, Rust, MinGit and other pinned artifacts once instead of on every build.

This is a fresh implementation for issue #24. It deliberately does not reuse PR #31.

This image is only built for nanoserver ltsc2025, because the cache only runs on the runner host, which runs ltsc2025 containers. That is an exception to ADR 0008, recorded in ADR 0013 and in `WINDOWS_VERSION_EXCEPTIONS`.

## How it works

The Caddyfile has one HTTPS site per allowlisted host. Each site terminates TLS with a certificate from Caddy's internal CA, proxies to the real host, and caches the response on disk.

| What | Cached |
| --- | --- |
| Unauthenticated `GET` ending in `.zip .7z .tar .tgz .gz .xz .bz2 .msi .exe .nupkg .whl .deb .rpm` | Yes, 30 days, then 7 days stale, keyed on the full URL |
| Unauthenticated `GET` on `release-assets.githubusercontent.com` or `objects.githubusercontent.com` | Yes, keyed without the signed query string |
| Anything else | No, passed through with `X-Artifact-Cache: BYPASS` |

Every cached response carries a `Cache-Status` header, and the JSON access log on stdout records the status per request. The total cache is capped at 500 GB on disk under `C:\cache`.

Port 8080 serves `http://<cache>:8080/healthz` and `/root.crt`, the root CA certificate clients must trust.

## Known gaps against issue #24

- Minimum and maximum artifact sizes, and unknown-size responses, are not yet enforced. The cache handler cannot reject a response by size before storing it, so this needs a later change.
- Range (`206`), stale-on-error and concurrent-download behaviour are not yet proven. The smoke test covers MISS, HIT, BYPASS and restart persistence first.
- Image builds do not use the cache yet. Wiring a build in needs the client to trust the CA and resolve the allowlisted hosts to the cache, and a cache address that survives restarts. That is follow-up work, not part of this image.
- The official NGINX Windows build cannot be used here: it is 32-bit, and Nano Server has no WoW64 (see DEVELOPER.md). Caddy is the 64-bit replacement.

## Building

```cmd
build.cmd
```

That builds `windows-nano-artifact-cache:2025`. Building Caddy compiles a few hundred Go modules in the Server Core build stage, so it takes several minutes.

## Running it on the host

```pwsh
./nano-server/nano-server-artifact-cache/Start-ArtifactCache.ps1
```

That bind-mounts `C:\ProgramData\windows-nano-demos\artifact-cache\cache` and `caddy-data`, so cached files and the CA survive container replacement.

> [!WARNING]
> `caddy-data` holds the internal CA private key. Anyone who can read it can impersonate every cached host to clients that trust the CA. Keep that folder readable only by Administrators and SYSTEM. Deleting it creates a new CA, and every client must trust the new root.
