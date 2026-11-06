# Artifact cache (Caddy) for nanoserver ltsc2025

A caching HTTPS proxy for build artifacts (issue #24, ADR 0014). It runs beside the GitHub Actions runners on the CI host, so image builds download Go, Rust, MinGit and other pinned artifacts once instead of on every build.

This is a fresh implementation for issue #24. It deliberately does not reuse PR #31.

This image is only built for nanoserver ltsc2025, because the cache only runs on the runner host, which runs ltsc2025 containers. That is an exception to ADR 0008, recorded in ADR 0014 and in `WINDOWS_VERSION_EXCEPTIONS`.

## How it works

The Caddyfile has one HTTPS site per allowlisted host. Each site terminates TLS with a certificate from Caddy's internal CA, proxies to the real host, and caches the response on disk.

| What | Cached |
| --- | --- |
| Unauthenticated `GET` ending in `.zip .7z .tar .tgz .gz .xz .bz2 .msi .exe .nupkg .whl .deb .rpm` | Yes, 30 days, then 7 days stale, keyed on the full URL |
| Unauthenticated `GET` on `release-assets.githubusercontent.com` or `objects.githubusercontent.com` | Yes, keyed without the signed query string |
| Anything else | No, passed through with `X-Artifact-Cache: BYPASS` |

Every cached response carries a `Cache-Status` header, and the JSON access log on stdout records the status per request. The total cache is capped at 500 GB on disk under `C:\cache`.

Port 8080 serves `http://<cache>:8080/healthz` and `/root.crt`, the root CA certificate clients must trust.

## How the cache is stored on disk

The cache handler is [Souin](https://github.com/darkweak/souin) (v1.7.9 under cache-handler v0.17.0), and `C:\cache` is written by its [simplefs](https://github.com/darkweak/storages/tree/main/simplefs) storage (v0.0.22). Simplefs does not keep the downloaded file under its own name. A cached artifact looks like this:

```text
C:\cache\
  5878554692879206298          457,420 bytes  lz4 frame: whole HTTP response, 7zr.exe (602,624 bytes)
  10893980105756012850      40,707,204 bytes  lz4 frame: node-v26.13.0-win-x64.zip
  15782013875559861339      77,286,537 bytes  lz4 frame: go1.27.3.windows-amd64.zip (varied key, see below)
  .simplefs-index\
    5878554692879206298            102 bytes  protobuf index for the 7zr.exe key
    10893980105756012850           124 bytes  protobuf index for the Node key
    4578865327147983338            132 bytes  protobuf index for the Go base key
```

- **File name.** Souin builds a key from the request, such as `GET-https-www.7-zip.org-/a/7zr.exe`. That is the `key=` in the `Cache-Status` header. Because the Caddyfile sets `key { hash }`, the key is replaced by its xxhash64 as a decimal string, so `GET-https-www.7-zip.org-/a/7zr.exe` becomes `5878554692879206298`. Simplefs then URL-escapes that and uses it as the file name. The URL appears nowhere on disk. To find a URL's file, hash its key.
- **Vary.** The payload is named after the *varied* key: the base key plus `{-VARY-}` and one `Header:value` for each header the upstream lists in `Vary`, joined with `;`. The index file is named after the base key. With no `Vary`, as for 7-zip.org and nodejs.org, both names are the same. dl.google.com sends `Vary: Accept-Encoding`, and `curl.exe` sends no `Accept-Encoding`. So the Go payload is the hash of `GET-https-dl.google.com-/go/go1.27.3.windows-amd64.zip{-VARY-}Accept-Encoding:`, which is `15782013875559861339`, while its index is the hash of the base key, `4578865327147983338`. A client that sends a different `Accept-Encoding` gets its own payload under the same index.
- **Redirects.** The `302` from `go.dev` to `dl.google.com` is not stored (`detail=UNCACHEABLE-STATUS-CODE`). Each download still makes one small round trip to go.dev, and only the target is cached.
- **Payload.** Each payload is one [lz4](https://github.com/pierrec/lz4) frame, starting with the magic bytes `04 22 4D 18`. Inside is the full response as Souin replays it: `HTTP/1.1 200 OK`, the upstream headers, a blank line, then the body. It is not the bare artifact, so `C:\cache` cannot be used as a download mirror. Zip files barely compress, so a payload is about the size of the artifact.
- **Index.** `.simplefs-index\<base key>` is a protobuf `StorageMapper`. It maps each varied key to the time stored, fresh until (now plus 720h), stale until (plus 168h), the varied headers, the ETag and the hashed real key. It is written to a `tmp-` file and renamed into place, so a crash cannot leave a partial index.
- **Writes happen only on a MISS.** A MISS writes the payload with one `os.WriteFile`, then rewrites the index. A HIT reads the payload and writes nothing. [Measure-ArtifactCache.ps1](Measure-ArtifactCache.ps1) checks this: every file's size, creation time and write time are identical before and after the HITs. A refetch after expiry overwrites the same file names.
- **Restart.** Simplefs keeps its index in memory and reloads it from `.simplefs-index` at start-up. An entry past its fresh time is dropped and its payload deleted. Any lz4 payload that no index entry points to is also deleted. Don't put files into `C:\cache` by hand: they are either ignored or purged.
- **Size cap and memory.** `directory_size 500GB` is enforced by evicting the oldest entries before a write. Souin buffers the whole upstream body in memory, then simplefs lz4-compresses it in memory before writing. A MISS therefore holds several copies of the artifact in RAM at once, and the client gets no bytes until the upstream download has finished. That is why a MISS is slower than a direct download. Container memory must allow for the largest artifact several times over.

## Listing the cache

[Get-ArtifactCacheEntry.ps1](Get-ArtifactCacheEntry.ps1) lists what the cache holds without talking to Souin, so it also works on a stopped cache or a copied folder:

```pwsh
./nano-server/nano-server-artifact-cache/Get-ArtifactCacheEntry.ps1 -FromLog | Format-Table Hash, Url, Bytes, State
```

It reads the payload files and the `.simplefs-index` protobuf files directly, and writes one object per payload with `Hash`, `IndexHash`, `Url`, `Bytes`, `StoredAt`, `FreshUntil`, `StaleUntil`, `ETag`, `VariedHeaders` and `State` (`Fresh`, `Stale`, `Expired`, or `Orphan` for a payload no index points to). It never writes to the cache folder.

Because the Caddyfile hashes its keys, the URL is stored nowhere, so the script works it out by hashing candidate URLs and matching the hashes against the file names. Candidates come from `-Url`, from the running cache's access log with `-FromLog`, or, when neither supplies any, from download URLs in this repo's Dockerfiles on a best-effort basis. Entries no candidate matches are still listed, by hash, with a null `Url`.

The parser only understands the storage format of the cache-handler and simplefs versions pinned in the Dockerfile, and the script records the versions it was validated against. A test in `tests/` fails when either pin changes, so a version bump forces a re-check against fresh fixtures. The Pester tests in `Get-ArtifactCacheEntry.Tests.ps1` run against the fixture cache under `fixtures/`.

## Using the cache from a Dockerfile

Plain `curl.exe` in a `RUN` step can use the cache, with no change to the download line. Three things are needed, all found by building on this host:

- **Reach the cache.** `docker build --network <net>` puts the build on the cache's network. Windows' classic builder **ignores `--add-host`**: the download went straight to the real host. Instead, the build stage appends `<cache-ip> <host>` lines to its own `C:\Windows\System32\drivers\etc\hosts`. That file is inside the build container, not the host's.
- **Trust the CA.** Nano Server ltsc2025 has no `certoc.exe`, so the root can't be added to the Windows store, and `curl.exe` (8.21, Schannel) **ignores `CURL_CA_BUNDLE`**. `--cacert` works, and so does `cacert = ...` in a `.curlrc` found through `CURL_HOME`.
- **Skip the revocation check.** With the CA trusted, Schannel still fails with `(60) the revocation status is unknown`, because Caddy's internal CA publishes no CRL or OCSP. `--ssl-revoke-best-effort`, or `ssl-revoke-best-effort` in the `.curlrc`, fixes that.

```dockerfile
FROM mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64 AS download
ARG CACHE_IP
USER ContainerAdministrator
RUN if defined CACHE_IP ( mkdir C:\curl && curl.exe -fsS -o C:\curl\cache-root.crt http://%CACHE_IP%:8080/root.crt && (echo %CACHE_IP% nodejs.org& echo %CACHE_IP% go.dev& echo %CACHE_IP% dl.google.com)>> C:\Windows\System32\drivers\etc\hosts && (echo cacert = "C:/curl/cache-root.crt"& echo ssl-revoke-best-effort)> C:\curl\.curlrc )
ENV CURL_HOME=C:\\curl
RUN curl.exe -fsSL -o C:\node.zip https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip

FROM mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64
COPY --from=download C:/node.zip C:/node.zip
```

Build it with `docker build --network <cache-network> --build-arg CACHE_IP=<cache-ip> .`. Without `CACHE_IP`, the same Dockerfile downloads directly. Keep the hosts entries, CA and `.curlrc` in a download stage, as above, so they don't reach the final image. Every host a download redirects to must also be listed, such as `go.dev` to `dl.google.com`.

## Measuring it

```pwsh
./nano-server/nano-server-artifact-cache/Measure-ArtifactCache.ps1 -Image windows-nano-artifact-cache:dev2025
```

This creates its own nat network, a cache and a nanoserver client, all named `claude-ac-measure-<random>`, and removes them at the end. For each artifact it times direct downloads, the MISS and repeat HITs, and checks:

- every HIT has `Cache-Status: ...; hit`;
- the SHA-256 is the same for direct, MISS and HIT downloads;
- the cache folder's files are byte-for-byte unchanged in size, creation time and write time across the HITs;
- every payload is an lz4 frame.

Then it builds the Dockerfile above once directly and twice through the cache, and checks the `Cache-Status` the build's curl saw.

The script bind-mounts a temp folder into the client and the cache, because `docker cp` cannot reach a running Hyper-V isolated container. It is a local tool. CI runners must not bind-mount, so it does not run in CI.

## Known gaps against issue #24

- Minimum and maximum artifact sizes, and unknown-size responses, are not yet enforced. The cache handler cannot reject a response by size before storing it, so this needs a later change.
- Range (`206`), stale-on-error and concurrent-download behaviour are not yet proven. The smoke test covers MISS, HIT, BYPASS and restart persistence first.
- Image builds do not use the cache yet. [Using the cache from a Dockerfile](#using-the-cache-from-a-dockerfile) shows a build can use it. Wiring the repo's builds in still needs a cache address that survives restarts, and the build network and `CACHE_IP` passed through `build-windows-image.yml`. That is follow-up work, not part of this image.
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
