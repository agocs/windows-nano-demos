# 0014. Artifact cache with Caddy on ltsc2025

- Status: Proposed
- Date: 2026-11-06
- Related: [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md), [0009](0009-all-image-builds-use-one-reusable-workflow.md), [0012](0012-images-live-in-a-directory-for-their-base-image.md), issue #24

## Context

Every image build downloads the same pinned artifacts again, because Docker's layer cache does not survive a changed earlier layer or a new base image. Issue #24 asks for an artifact caching proxy on the runner host.

The issue's first candidate, the official NGINX for Windows, cannot run on Nano Server on any Windows version. It is a 32-bit build, Nano Server has no WoW64 layer, the binary exits with `0xC0000135`, and transplanting Server Core's WoW64 fails at 32-bit process startup with `0xC0000481` (see DEVELOPER.md). NGINX in a Server Core container would be much larger and still cannot intercept TLS for arbitrary hosts without a matching certificate setup.

Almost every artifact URL is HTTPS, so a useful cache must terminate TLS with a CA that clients trust. A plain forward proxy only sees `CONNECT` tunnels and cannot cache their contents.

## Decision

- The cache is a separate `windows-nano-artifact-cache` container beside the runners, not a process inside the runner image, so the cache survives runner replacement and runner registration is untouched.
- It is 64-bit Caddy, built with xcaddy, the cache-handler module and the simplefs filesystem storage, in a Server Core build stage. The final stage is Nano Server.
- It TLS-intercepts one site per allowlisted host with Caddy's internal CA. Unauthenticated `GET`s of allowlisted artifact extensions are cached for 30 days plus 7 days stale, keyed on the full URL. GitHub's release blob hosts are cached without their signed query string. Everything else passes through uncached.
- Cache files and Caddy data, including the CA, live on host-mounted folders, so both survive container replacement and host restarts.
- The image is built only for ltsc2025. The runner host runs ltsc2025 containers, so older versions would add CI time without a user. Its workflow passes `windows-versions: '["2025"]'`, and `tests/repo_conventions.py` lists it in `WINDOWS_VERSION_EXCEPTIONS`.
- This work is a fresh implementation for issue #24 and does not reuse PR #31.

## Consequences

- The CA private key on the host can impersonate every cached host to trusting clients, so its folder must stay readable only by Administrators and SYSTEM. Deleting it creates a new CA that every client must re-trust.
- Minimum and maximum artifact sizes, and unknown-size responses, are not enforced. The cache handler stores whole responses before size could be judged, and simplefs holds them in memory while storing and serving. Issue #24's size limits stay open until this is solved or accepted as a deviation.
- Range, stale-on-error and concurrent-download behaviour are configured but not yet proven by tests.
- No image build uses the cache yet. Client wiring, including a cache address that survives container restarts, is follow-up work.
- Clients that pin certificates or use their own CA bundle instead of the Windows trust store will not trust the cache.

## Alternatives considered

- **NGINX on Nano Server.** Ruled out above: the official Windows build is 32-bit and Nano Server has no WoW64.
- **NGINX in a Server Core container.** Runs under WoW64, but is a much larger image and still cannot intercept TLS for arbitrary hosts without a matching certificate setup.
- **A custom caching proxy in Go.** It could enforce the issue's size limits exactly, at the cost of writing and maintaining TLS interception, caching, eviction and range handling. Revisit only if the size limits prove mandatory.
- **A plain `HTTP_PROXY` forward proxy.** Without TLS interception it cannot see or cache HTTPS artifact downloads.
- **Rewrite download URLs to plain HTTP cache URLs.** No CA is needed, but every Dockerfile must rewrite every URL, and images built that way only work where the cache exists.
- **Build for 2019, 2022 and 2025.** The cache only runs on the ltsc2025 runner host, so the extra legs buy nothing.
