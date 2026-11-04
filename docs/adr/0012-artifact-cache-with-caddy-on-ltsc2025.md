# 0012. Artifact cache with Caddy on ltsc2025

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Amends: [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) (one image builds only 2025)
- Related: [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), [0009](0009-all-image-builds-use-one-reusable-workflow.md), [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md), issue [#24](https://github.com/zippy1981/windows-nano-demos/issues/24), [`nano-server-artifact-cache/`](../../nano-server-artifact-cache/README.md)

## Context

Every image build downloads the same pinned artifacts (Go, Rust, PHP, Node.js, MinGit, micro, 7-Zip and more) again, because docker's layer cache doesn't survive a changed earlier layer or a new base image. Issue #24 asks for a cache on the runner host. Nearly every artifact URL is HTTPS, so a cache has to terminate TLS to see and store responses. nginx.org only ships 32-bit Windows builds, and nanoserver has no WoW64. The runner host is a Windows 11 build 26300 machine, which runs ltsc2025 containers with process isolation.

## Decision

- The cache is Caddy, built for 64-bit Windows with xcaddy, the `cache-handler` (Souin) module and the `simplefs` storage, which keeps each cached response as a file and persists its index across restarts. It runs as the `windows-nano-artifact-cache` nanoserver image.
- It intercepts TLS. The Caddyfile has one site per allowlisted artifact host with `tls internal`, so certificates come from Caddy's own CA, and reverse-proxies each request to the same host over HTTPS, resolved with the cache container's own DNS. Only `GET` requests without `Authorization` for allowlisted file types are cached, for 30 days, keyed on the full URL. GitHub's release blob hosts are cached without their short-lived query string. Everything else passes through.
- Clients opt in. A build stage running as `ContainerAdministrator` adds the cache's root CA to the machine Root store with `reg add` and appends the cached host names to its `hosts` file. It also sets `ssl-revoke-best-effort` in `.curlrc`, because the internal CA's certificates have no revocation endpoints and `curl.exe`'s Schannel backend otherwise rejects them. Nanoserver has neither `certoc.exe` nor `certutil.exe`, and docker ignores `--add-host` for Windows containers, so neither of the more obvious routes works. `New-ArtifactCacheClientSetup.ps1` writes the commands.
- On the host, `Start-ArtifactCache.ps1` runs the container with `--restart unless-stopped` and bind-mounts host folders for the cache and for Caddy's data, so the cache and the CA outlive the container.
- The image is built and tested only for ltsc2025. The shared workflow takes a `windows-versions` input, which defaults to all three versions, and the cache's workflow passes `["2025"]`. The tests in [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md) allow that only for images listed as exceptions, each backed by an ADR.

## Consequences

- The CA's private key is in `caddy-data` on the host. Anyone who can read it can impersonate github.com and the other cached hosts to every client that trusts the CA, so that folder must stay readable by administrators only. Deleting `caddy-data` creates a new CA, and clients must import the new root.
- Clients that pin certificates or ship their own CA bundle, rather than using the Windows store, don't trust the cache. Tools that use Schannel or CryptoAPI, such as `curl.exe`, Go, .NET and PowerShell, do.
- Images don't use the cache until their Dockerfiles opt in. Wiring it into the builds is a later change.
- simplefs reads and writes whole responses in memory and compresses them with lz4, so very large artifacts cost memory while they are stored or served.
- A second exception to [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) now needs only a new ADR and an entry in the test's exception list.

## Alternatives considered

- **nginx in a servercore container.** The official x86 build would need servercore's WoW64, a much larger image, and nginx can't intercept TLS for arbitrary hosts without a matching certificate setup anyway.
- **Mirror URLs over plain HTTP** (`http://cache:8080/github.com/...`). No CA is needed, but every Dockerfile has to rewrite every URL, and images built that way only work where the cache exists.
- **A forward proxy with `HTTPS_PROXY`.** Without interception it only sees `CONNECT` tunnels and can't cache anything.
- **Badger or another embedded database for storage.** It works, but it hides the cache in database files, and simplefs keeps the artifacts as plain files on the host.
- **Build for all three versions.** The cache only runs on the host, which runs ltsc2025, so older builds would add CI time without a user.
