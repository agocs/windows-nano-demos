# Runner artifact cache

## Goal

Add an NGINX-based HTTP caching proxy to `nano-server-gh-runner/` that intercepts build artifact downloads (GitHub releases, nodejs.org, windows.php.net, etc.), caches allowlisted types (tar\*, zip, 7z, msi, exe, nupkg, whl, deb, rpm), enforces size and TTL limits (1 MB to 5 GB per file, 500 GB total, 30-day TTL, 90-day eviction), handles concurrency and ranges, persists across host reboots, and is transparent to builders via HTTP_PROXY/HTTPS_PROXY environment variables and tool-specific mirror configs.

## Context

- GitHub Actions runners in `nano-server-gh-runner/` download large artifacts (Rust, PHP, Node.js, Go, PowerShell, MinGit, 7-Zip, Far Manager) during every image build. Builds run on `[self-hosted, windows, docker]`, persisting between jobs on a single host. Layer caching reduces redundant image rebuilds, but artifact downloads are not cached between job runs.
- Issue #24 requests the cache to reduce bandwidth, build time, and load on upstream servers.
- The proxy runs on the host and is accessible to runner containers and build containers (which run via `docker build` against the host daemon).
- The issue specifies an nginx.org Windows build. Nginx.org's Windows binaries are historically x86-only (32-bit). Nanoserver has no WoW64, so it cannot run x86 binaries. Ltsc2025 (and ltsc2022, ltsc2019) nanoserver cannot host the proxy directly. A servercore container can.
- All artifact URLs in Dockerfiles are HTTPS. A forward HTTP proxy cannot cache HTTPS without TLS interception (private CA, key on host, CA trusted by every tool). Alternatively, Dockerfiles can use explicit mirror URLs with HTTP.
- The proxy must deduplicate concurrent downloads (lock to first downloader, serve cached result to others), serve stale on upstream errors, and support HTTP 206 ranges (for partial downloads and resume).

## Decisions

**All three items below require user decision before Phases 2+ begin.**

### (a) HTTPS handling **Needs user decision**

Almost every artifact URL is HTTPS. A forward proxy sees only `CONNECT` tunnels and cannot cache responses without TLS interception. Options:

1. **TLS interception (private CA approach):** The proxy runs as a CONNECT tunnel interceptor. Generate a private CA cert and key, store them on the host, embed the CA cert in the runner image and every build stage that needs the cache, trust the CA in the Windows certificate store (system root), and configure curl, OpenSSL, PowerShell (Schannel), and other tools to use it. The proxy decrypts traffic, caches, re-encrypts. Pros: transparent to Dockerfiles. Cons: complex CA management, every build container needs the CA cert, cert pinning breaks, new tool stacks (e.g., Go) may not work.

2. **Reverse-proxy/mirror mode:** Dockerfiles are updated to fetch through explicit HTTP mirror URLs: `curl http://cache:8080/github.com/PowerShell/Win32-OpenSSH/releases/download/...` instead of HTTPS. The proxy maps incoming URLs to upstream HTTPS URLs, fetches, caches, serves. The proxy itself uses HTTPS to upstreams. Pros: simple, cache is transparent in URL space, no CA or cert store changes. Cons: every Dockerfile needs mirror URL updates, the pattern is unfamiliar.

3. **Manual mirror + rsync:** Pre-populate the cache on the host with known release URLs using a separate tool or schedule. Not dynamic or responsive to new versions. Ruled out.

**Recommendation:** **Reverse-proxy/mirror mode (option 2).** It is simpler to deploy, requires no private CA (nanoserver can trust one, but every tool in every image and build stage would need it, and the CA key becomes a secret on the host). The trade-off (updating Dockerfiles to use mirror URLs) is worth the simplicity.

### (b) x86 nginx vs nanoserver/servercore **Needs user decision**

Nginx.org's official Windows build is 32-bit (x86). Nanoserver has no WoW64 and cannot run x86 binaries. Options:

1. **Servercore-based proxy container:** Run the proxy in a servercore container (ltsc2025, ltsc2022, ltsc2019) that can run x86 nginx. Upside: official nginx binary, well-tested, minimal changes. Downside: servercore containers are ~3–5 GB; the proxy is large. The runner host must run the container separately, or the runner image becomes large.

2. **Community x64 nginx builds:** Search for a maintained x64 Windows build (e.g., GitHub releases, unofficial builds). Upside: smaller. Downside: trust and maintenance uncertainty.

3. **Caddy reverse proxy (x64):** Caddy publishes official x64 Windows binaries. Upside: x64, official. Downside: different tool (not nginx), feature parity and observability may differ.

4. **Squid x64 Windows build:** Squid has x64 Windows binaries. Upside: x64, mature cache. Downside: not nginx, different config.

5. **Build nginx x64:** Compile nginx from source as x64. Upside: full control. Downside: CI build complexity, ongoing maintenance.

**Recommendation:** **Servercore-based proxy container (option 1).** Using the official nginx binary is the safest path. The container size is a one-time cost. It can be started on the host before runners launch and persist via a scheduled task. The runner image remains nanoserver-based and small.

### (c) Proxy architecture: same container or sidecar **Needs user decision**

Options:

1. **One proxy container per runner:** Each runner container has its own NGINX instance (inside the container). Upside: isolation, no port conflicts. Downside: N copies of NGINX, redundant caches, higher resource use, each proxy only caches for one runner.

2. **One shared proxy container on the nat network:** A single servercore-based NGINX container runs on the host or in a separate container on the docker network. All runner containers and build containers reach it via HTTP at a well-known hostname (e.g., `cache.local` or `cache:8080`). Upside: one cache, shared across all runners and builds, efficient, simple. Downside: requires network config (DNS or hosts), a single point of failure if the proxy crashes (mitigation: supervisor), and the proxy must be restarted on host reboot.

**Recommendation:** **One shared proxy container (option 2).** Runner containers persist between jobs (registration lives in the container), so a single cache shared across all runners and all builds in a job is efficient and matches the host's architecture. Use a host-side scheduled task or entrypoint script to start the proxy before runners. Use `docker network create` to create a network for the proxy, or use the default `nat` network with port mapping.

---

## Plan

### Phase 0: Architectural validation **Gated on user decisions A, B, C**

Once the user decides on (a), (b), and (c), proceed to Phase 1.

- [ ] **cicd-engineer**: Document the chosen architecture in a new ADR or amendment: HTTPS strategy, nginx in servercore, shared proxy container, network setup, supervisor/restart strategy. Accept: ADR draft is clear on the rationale and trade-offs.

### Phase 1: Proxy container image and bootstrap **Gated on Phase 0**

- [ ] **container-author**: Create `server-core-cache-proxy/` folder with:
  - A `Dockerfile` that builds on `servercore:ltsc2025` (and 2019, 2022 variants), installs nginx.org x86 build, configures it as a reverse HTTP caching proxy (see Phase 2), persists cache to a volume at `C:\cache`, and exposes port 8080.
  - A `build.cmd` following repo conventions (defaulting to 2025, accepting `WINDOWS_VERSION`, `BASE_IMAGE`, `BASE_IMAGE_NAME` args).
  - Nginx conf (as a multi-stage or COPY): caching rules, no-cache for 200/206 responses and ranges, TTL 30 days, max file 5 GB, total 500 GB, lock for concurrent downloads, stale-while-error, allowlist for tar*, zip, 7z, msi, exe, nupkg, whl, deb, rpm.
  - Accept: `docker build server-core-cache-proxy -t windows-servercore-cache-proxy:2025` succeeds.

- [ ] **powershell-author**: Write `nano-server-gh-runner/Start-CacheProxy.ps1` script that:
  - Checks if a `windows-servercore-cache-proxy` container is already running; if yes, skip.
  - Creates a docker network if it doesn't exist (e.g., `docker network create cache-net --driver nat`, or use the default nat).
  - Starts the proxy container with a persistent volume at `C:\ProgramData\cache` on the host (or via a mount).
  - Logs the proxy's hostname/port to the runner's output.
  - Accept: script runs without error, and `docker ps` shows the proxy container.

- [ ] **powershell-author**: Write `nano-server-gh-runner/Stop-CacheProxy.ps1` script that stops and removes the proxy container (for cleanup or in case of updates). Accept: script removes the container cleanly.

### Phase 2: Proxy configuration (nginx caching rules) **Gated on Phase 1**

- [ ] **container-author**: Write nginx configuration in `server-core-cache-proxy/nginx.conf` (or inline in Dockerfile) with:
  - `proxy_cache_path`: persistent disk cache, `/cache`, 500 GB size, `inactive=90d` (evict unused files after 90 days).
  - `upstream github.com`, `upstream nodejs.org`, etc.: HTTPS upstreams.
  - `server` block on port 8080: reverse-proxy rules.
    - Allowlist: cache GET requests for `*.tar*`, `*.zip`, `*.7z`, `*.msi`, `*.exe`, `*.nupkg`, `*.whl`, `*.deb`, `*.rpm`.
    - Min size 1 MB (skip caching smaller files), max 5 GB.
    - `proxy_cache_key` uses the full upstream URL.
    - `proxy_cache_valid 200 206 30d`: cache 200 OK and 206 Partial Content for 30 days.
    - `proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504`: if upstream is down, serve stale.
    - `proxy_cache_lock on`: deduplicate concurrent requests (first downloader fetches, others wait for cache).
    - `proxy_cache_lock_timeout 60s`: wait up to 60 seconds for first downloader.
  - Accept: nginx config syntax is valid (`nginx -t`), and a manual test (e.g., `curl http://localhost:8080/github.com/...`) returns a 200 or 206 with `X-Cache-Status` headers.

- [ ] **container-author**: Add logging and observability:
  - Nginx access log with cache status (`$upstream_cache_status`).
  - Cache hit ratio and disk usage reporting: a simple PowerShell endpoint or script that reads nginx stats and reports cache size, hit count, miss count.
  - Accept: `docker logs <proxy-container>` shows cache hits/misses, and `du -sh C:\cache` on the host shows cache usage.

### Phase 3: Runner environment and tool configuration **Gated on Phase 2**

- [ ] **container-author**: Update `nano-server-gh-runner/Dockerfile` to:
  - Set environment variables for the proxy:
    - `HTTP_PROXY=http://cache:8080` (or IP if DNS isn't available)
    - `HTTPS_PROXY=http://cache:8080` (forward HTTPS requests to the HTTP proxy as a fallback, or use mirror URLs)
    - `NO_PROXY=localhost,127.0.0.1,.local` (don't proxy localhost)
  - Accept: environment variables are set and visible in a running container.

- [ ] **container-author**: Update tool-specific configs in the runner image:
  - **Git:** `C:\ProgramData\ssh\gitconfig` (or global): `http.proxy`, `https.proxy` if HTTP_PROXY isn't picked up.
  - **npm:** Run `npm config set registry http://cache:8080/registry.npmjs.org` or use a `.npmrc` file in the build context (if npm is used in the runner; check `nano-server-gh-runner/README.md`).
  - **NuGet:** `%AppData%\NuGet\NuGet.Config`: proxy settings (if NuGet is used).
  - **pip:** `pip config set global.index-url http://cache:8080/pypi.org/simple` (if Python is in runner builds).
  - **pwsh:** No special proxy config needed; uses HTTP_PROXY.
  - Accept: each tool reads its proxy config when tested.

- [ ] **powershell-author**: Update `nano-server-gh-runner/run-runner.ps1` to call `Start-CacheProxy.ps1` before starting the runner, and ensure the proxy is healthy. Accept: `run-runner.ps1` starts the proxy and confirms it's running.

### Phase 4: Mirror URL updates in image Dockerfiles **Gated on Phase 3 and decision (a) = mirror mode**

- [ ] **container-author**: For each image Dockerfile, review URLs and update HTTPS to mirror URLs where applicable:
  - Example: `https://github.com/PowerShell/Win32-OpenSSH/releases/download/v10.4.0.0p1-Preview/OpenSSH-Win64.zip` becomes `http://cache:8080/github.com/PowerShell/Win32-OpenSSH/releases/download/v10.4.0.0p1-Preview/OpenSSH-Win64.zip`.
  - Create a mapping or helper script to generate mirror URLs from upstream URLs.
  - Test builds with mirror URLs to confirm the proxy is hit.
  - Accept: `docker build --network=<proxy-network>` completes, and proxy logs show cache hits.

- [ ] **windows-dockerfile-reviewer**: Review Dockerfile changes for correctness (URLs, curl/wget commands, etc.). Accept: review finds no issues.

### Phase 5: Testing and validation **Gated on Phase 4**

- [ ] **windows-container-tester**: Write smoke tests to validate the proxy:
  - Test cache eligibility: a 2 MB ZIP should be cached, a 50 KB file should not.
  - Test size limits: a file larger than 5 GB is rejected or skipped.
  - Test concurrency: launch 3 parallel downloads of the same URL, verify only one hits the upstream and others use cache.
  - Test ranges: `curl -r 0-999 http://cache:8080/...` returns 206 Partial Content and is cached.
  - Test eviction: add files until total exceeds 500 GB, verify oldest files are removed.
  - Test stale-while-error: block upstream, serve cached response, then recover.
  - Test persistence: restart the proxy container, verify cache files remain.
  - Test that `windows-nano-<x>` images build with the proxy active and cache hits are logged.
  - Accept: all smoke tests pass on the runner host.

- [ ] **python-author**: Optionally add tests to `tests/repo_conventions.py` to verify that image Dockerfiles use mirror URLs (grep for `http://cache` or check for `HTTP_PROXY` in ENV). Accept: tests pass.

- [ ] **workflow-author**: Update `.github/workflows/build-windows-image.yml` to start the cache proxy before building (or rely on `run-runner.ps1` to start it). Confirm proxy logs are captured in the job summary. Accept: workflow runs green and proxy logs appear.

### Phase 6: Documentation and observability **Gated on Phase 5**

- [ ] **container-author**: Write `server-core-cache-proxy/README.md` documenting:
  - Purpose: caching reverse proxy for artifact downloads.
  - Configuration: environment variables, mirror URLs, tool-specific configs.
  - Cache statistics: hit ratio, disk usage, eviction policy.
  - Troubleshooting: cache miss, upstream errors, proxy container crashes.
  - Accept: README is clear and complete.

- [ ] **container-author**: Update `nano-server-gh-runner/README.md` to document:
  - Proxy startup and shutdown.
  - Environment variables (`HTTP_PROXY`, etc.).
  - How to disable the proxy (set `DISABLE_PROXY=1` before `run-runner.ps1`).
  - Cache hit ratio and performance impact.
  - Accept: README explains the proxy's role in the runner.

- [ ] **powershell-author**: Write a helper script `scripts/Get-ProxyStats.ps1` that reads nginx logs and returns cache hit ratio, total bytes cached, and recent misses. Accept: script runs and produces a report.

- [ ] **markdown-reviewer**: Review `server-core-cache-proxy/README.md` and updates to `nano-server-gh-runner/README.md`. Accept: lint clean and clear.

### Phase 7: Host-level automation and updates **Gated on Phase 6**

- [ ] **cicd-engineer**: Document the host setup: how the proxy container is started (e.g., on host reboot via a scheduled task or as part of `nano-server-gh-runner/run-runner.ps1`), volume mounts, network setup. Accept: setup doc is clear.

- [ ] **powershell-author**: Optionally add a check to `nano-server-host-doctor.ps1` (if it exists) to verify the proxy is running and the cache volume has free space. Accept: health check passes.

### Phase 8: Monitoring and incident response **Gated on Phase 7**

- [ ] **cicd-engineer**: Set up monitoring (optional): if the proxy crashes, restart it. Log proxy errors to a file on the host. Alert if cache disk usage exceeds 90%. Accept: monitoring is in place or a plan is documented.

- [ ] **governance**: Audit after all phases land: proxy container is built, tests pass, all image Dockerfiles use mirror URLs, runner environment is configured, workflows start the proxy. Accept: audit finds no gaps.

## Risks

- **Proxy crashes or network issues:** Build containers lose cache access but can still fetch from upstream. Mitigation: `curl` and other tools have fallback to direct HTTPS, and runner image tests confirm proxy is running.
- **Cache disk fills:** 500 GB limit may not be enough if many large artifacts are cached. Mitigation: eviction policy (90-day inactive) and monitoring alert if free space drops.
- **Mirror URL maintenance:** Every tool URL must be rewritten as a mirror URL. Adding a new tool requires updating Dockerfiles. Mitigation: helper script to generate mirror URLs, and review process to catch new URLs.
- **Nanoserver containers can't reach the proxy:** Network misconfiguration, hostname resolution fails. Mitigation: use IP address instead of hostname if needed; `docker network inspect` confirms connectivity.
- **TLS interception (if chosen instead of mirrors):** CA cert not trusted by a new tool, pinning breaks, cert rotation complexity. Mitigation: mirrors are simpler, so this is avoided.
- **Proxy performance:** If many builders hit the proxy concurrently, it may become a bottleneck. Mitigation: nginx is fast; the host's CPU and disk I/O are the limits. Upgrade host resources if needed.

## Owners

| Agent | Tasks |
| --- | --- |
| `cicd-engineer` | Architecture decision doc, host setup and automation, monitoring |
| `container-author` | Proxy Dockerfile, nginx config, mirror URL Dockerfile updates, READMEs |
| `powershell-author` | `Start-CacheProxy.ps1`, `Stop-CacheProxy.ps1`, `Get-ProxyStats.ps1`, runner integration |
| `windows-container-tester` | Proxy smoke tests, integration tests with image builds |
| `windows-dockerfile-reviewer` | Review of Dockerfile changes for mirror URLs |
| `python-author` | Optional tests for mirror URL patterns in Dockerfiles |
| `workflow-author` | Update `build-windows-image.yml` to manage proxy, add proxy logs to job summary |
| `markdown-reviewer` | Review proxy and runner README updates |
| `governance` | Post-rollout audit |
