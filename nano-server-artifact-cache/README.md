# Artifact cache (Caddy) for nanoserver ltsc2025

A caching HTTPS proxy for build artifacts (issue [#24](https://github.com/zippy1981/windows-nano-demos/issues/24), [ADR 0012](../docs/adr/0012-artifact-cache-with-caddy-on-ltsc2025.md)). It runs on the CI host so image builds can download Go, Rust, MinGit and other pinned artifacts once instead of on every build.

The image contains:

- [Caddy](https://caddyserver.com/) v2.11.8, built for windows/amd64 with [xcaddy](https://github.com/caddyserver/xcaddy) v0.4.7 and Go 1.27.3
- [cache-handler](https://github.com/caddyserver/cache-handler) v0.17.0 (Souin)
- the [simplefs](https://github.com/darkweak/storages/tree/main/simplefs) storage v0.0.22, which keeps one file per cached response under `C:\cache` and persists its index there, so the cache survives restarts

This image is only built for **nanoserver ltsc2025**. It's an exception to [ADR 0008](../docs/adr/0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md): the cache runs on the host, which runs ltsc2025, so its workflow passes `windows-versions: '["2025"]'` to the shared build workflow.

## How it works

The [Caddyfile](Caddyfile) has one HTTPS site per cached host. Each site uses `tls internal`, so its certificate comes from Caddy's own CA, and reverse-proxies every request to the same host over HTTPS. The cache container resolves the upstream with its own DNS. A client that resolves `github.com` to the cache and trusts the CA gets the real response, and the cache keeps a copy.

| What | Cached? |
| --- | --- |
| `GET` of a path ending in `.zip .7z .tar .tgz .gz .xz .bz2 .msi .exe .nupkg .whl .deb .rpm` | Yes, keyed on the full URL |
| `GET` on `release-assets.githubusercontent.com` and `objects.githubusercontent.com` | Yes, keyed on the URL without the query string, which is a short-lived signature |
| Anything else, any request with `Authorization`, and any non-`GET` | No, passed through with `X-Artifact-Cache: BYPASS` |

Cached responses keep for 30 days whatever the upstream's `Cache-Control` says (`mode bypass`, because the URLs are pinned versions), and stay a further 7 days as stale. The cache is capped at 100 GB. Only `200` responses are stored, so a redirect such as github.com's `302` to its release blob host is always fetched upstream.

Cached hosts: `github.com`, `codeload.github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, `nodejs.org`, `windows.php.net`, `cdn.mysql.com`, `static.rust-lang.org`, `go.dev`, `dl.google.com`, `download.docker.com`, `www.7-zip.org`, `nginx.org`, `aka.ms` and `download.visualstudio.microsoft.com`.

Every response carries a `Cache-Status` header from cache-handler, for example `ArtifactCache; fwd=uri-miss; stored; key=...` on a miss and `ArtifactCache; hit; ttl=...; key=...` on a hit. The JSON access log on stdout (`docker logs windows-nano-artifact-cache`) includes the URL and the response headers, so it records MISS, HIT and BYPASS for each request.

Port 8080 serves plain HTTP:

- `http://<cache>:8080/healthz` answers `ok`
- `http://<cache>:8080/root.crt` is the root CA certificate clients must trust

## Building

```cmd
build.cmd
```

That builds `windows-nano-artifact-cache:2025`. Building Caddy downloads and compiles a few hundred Go modules, so it takes several minutes.

## Running it on the host

```pwsh
./nano-server-artifact-cache/Start-ArtifactCache.ps1
```

`Start-ArtifactCache.ps1` creates the host folders if they are missing and starts the container detached with `--restart unless-stopped` and process isolation (pass `-Isolation hyperv` if the host can't run ltsc2025 with process isolation). It bind-mounts:

- `C:\ProgramData\windows-nano-demos\artifact-cache\cache` on `C:\cache`, the cached files
- `C:\ProgramData\windows-nano-demos\artifact-cache\caddy-data` on `C:\caddy-data`, Caddy's data, including the internal CA, so certificates stay the same across restarts

It limits `caddy-data` to Administrators and SYSTEM, then waits for `/healthz`, writes `root.crt` and `use-artifact-cache.cmd` to `C:\ProgramData\windows-nano-demos\artifact-cache`, and prints the container's IP address. `-Image`, `-Name`, `-Root`, `-CachePath`, `-DataPath` and `-Isolation` change the defaults.

`Stop-ArtifactCache.ps1` removes the container and keeps the folders.

> [!WARNING]
> `caddy-data\pki\authorities\local\root.key` is the CA's private key. Anyone who can read it can impersonate github.com and every other cached host to any container that trusts the CA. Keep `caddy-data` readable only by administrators, and never copy it into an image or a repository. Deleting `caddy-data` creates a new CA, and clients must then import the new `root.crt`.

The container's IP address on the `nat` network can change when it restarts. Run `Start-ArtifactCache.ps1` again to print it and rewrite `use-artifact-cache.cmd`.

## Using the cache from a build

Images don't use the cache unless their build opts in. Nanoserver has neither `certoc.exe` nor `certutil.exe`, and docker ignores `--add-host` for Windows containers, so a client needs two kinds of commands, run as `ContainerAdministrator`:

- `reg add` of the root CA into `HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\<thumbprint>`, which `curl.exe` (Schannel), Go, .NET and PowerShell all read
- `ssl-revoke-best-effort` in the `.curlrc` of ContainerAdministrator and ContainerUser, since the CA's certificates have no revocation endpoints
- `echo <cache ip> <host>>>C:\Windows\System32\drivers\etc\hosts` for each cached host

[`New-ArtifactCacheClientSetup.ps1`](New-ArtifactCacheClientSetup.ps1) writes them from `root.crt` and the cache's address, and `Start-ArtifactCache.ps1` saves them as `use-artifact-cache.cmd`. For example, to try it in a container:

```pwsh
$line = ./nano-server-artifact-cache/New-ArtifactCacheClientSetup.ps1 -RootCertificate C:\ProgramData\windows-nano-demos\artifact-cache\root.crt -CacheAddress 172.20.80.5 -SingleLine
docker run --rm -u ContainerAdministrator mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64 cmd /S /C "$line && curl.exe -fsSL -D - -o NUL https://www.7-zip.org/a/7zr.exe"
```

In a Dockerfile, copy `use-artifact-cache.cmd` into the build context and run it in a build stage before the downloads:

```dockerfile
USER ContainerAdministrator
COPY use-artifact-cache.cmd C:/
RUN C:\use-artifact-cache.cmd
```

Do this only in build stages that are thrown away, or the final image keeps trusting the cache's CA and sending the cached hosts to its address.

## Testing

```pwsh
./nano-server-artifact-cache/smoke-test.ps1 -Image windows-nano-artifact-cache:2025
```

The smoke test starts the cache with throwaway named volumes, then nanoserver client containers set up as above. It checks `/healthz` and `/root.crt`, that a GitHub release download and a 7-Zip download are a MISS and then a HIT with the same SHA-256, that an HTML page is a BYPASS, that entries survive a restart of the cache, and that the access log records the cache status. It removes only the containers and volumes it created.

## Limits

- Range requests (`206`) aren't stored. A range request for an uncached file is passed to the upstream, and Souin doesn't serve ranges from a cached full response.
- simplefs reads and writes each response whole, in memory, and compresses it with lz4, so a large artifact costs that much memory while it's stored or served.
- `codeload.github.com` archive paths such as `/owner/repo/zip/refs/tags/v1` have no file extension, so they pass through uncached.
- Serving stale entries when the upstream fails is configured (`stale 168h`) but not tested yet.
- cache-handler provisions one simplefs instance per site, all on `C:\cache`. Each one restores the shared index at startup, but the 100 GB cap is counted per instance, not for the folder as a whole.
- `curl.exe` needs `ssl-revoke-best-effort`, which the client setup writes to `.curlrc`, because the internal CA's certificates have no revocation endpoints. Without it Schannel fails with `CRYPT_E_NO_REVOCATION_CHECK`.
