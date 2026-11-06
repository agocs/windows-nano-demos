# windows-nano-artifact-cache: Caddy HTTPS caching proxy for build artifacts, ltsc2025 only (issue #24, ADR 0013).
#
# It TLS-intercepts allowlisted download hosts with its own CA and caches artifact files on disk,
# so repeated Windows image builds download Go, Rust, MinGit and similar pinned files once.
# Only ltsc2025 is built: the cache runs on the runner host, which runs ltsc2025 containers.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-artifact-cache):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2025 -t windows-nano-artifact-cache:2025 .
# Each build argument is described where it is declared below.

# Windows Server LTSC version to build for: only 2025 is supported for this image. Set with --build-arg WINDOWS_VERSION=2025.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# Build stage on Server Core: it has the shells and tools the Go build needs. Only caddy.exe leaves this stage.
FROM mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION}-amd64 AS build

ENV \
    GO_VERSION=1.27.3 \
    XCADDY_VERSION=v0.4.7 \
    CADDY_VERSION=v2.11.8 \
    CACHE_HANDLER_VERSION=v0.17.0 \
    SIMPLEFS_VERSION=v0.0.22

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop';"]

# Build Caddy with the cache handler and the filesystem storage in one layer, then delete the Go tree.
RUN New-Item -ItemType Directory -Force C:\build, C:\out | Out-Null; \
    curl.exe -fL -o C:\build\go.zip https://go.dev/dl/go$env:GO_VERSION.windows-amd64.zip; \
    tar.exe -xf C:\build\go.zip -C C:\build; \
    $env:PATH = 'C:\build\go\bin;C:\build\gopath\bin;' + $env:PATH; \
    $env:GOPATH = 'C:\build\gopath'; $env:GOCACHE = 'C:\build\gocache'; $env:CGO_ENABLED = '0'; \
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@$env:XCADDY_VERSION; \
    xcaddy build $env:CADDY_VERSION --output C:\out\caddy.exe \
        --with github.com/caddyserver/cache-handler@$env:CACHE_HANDLER_VERSION \
        --with github.com/darkweak/storages/simplefs/caddy@$env:SIMPLEFS_VERSION \
        --with github.com/darkweak/storages/simplefs@$env:SIMPLEFS_VERSION; \
    C:\out\caddy.exe version; \
    Remove-Item -Recurse -Force C:\build

FROM ${BASE_IMAGE}

COPY --from=build ["C:/out/caddy.exe", "C:/Program Files/Caddy/caddy.exe"]
COPY Caddyfile "C:/Program Files/Caddy/Caddyfile"

USER ContainerAdministrator
RUN mkdir C:\cache && mkdir C:\caddy-data

VOLUME ["C:/cache", "C:/caddy-data"]
EXPOSE 443 8080

WORKDIR "C:/Program Files/Caddy"
ENTRYPOINT ["C:\\Program Files\\Caddy\\caddy.exe"]
CMD ["run", "--config", "C:\\Program Files\\Caddy\\Caddyfile", "--adapter", "caddyfile"]
