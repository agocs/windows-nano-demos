# Caching HTTPS proxy for build artifacts (issue #24, ADR 0012).
# Only built for nanoserver ltsc2025; the caller workflow restricts the matrix to 2025.
ARG WINDOWS_VERSION=2025
# Use the official Microsoft Windows Nano Server image unless BASE_IMAGE overrides it
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# Build stage: Go, then xcaddy, then Caddy with the cache handler and a filesystem storage.
FROM ${BASE_IMAGE} AS build

ENV \
    GO_VERSION=1.27.3 \
    XCADDY_VERSION=v0.4.7 \
    CADDY_VERSION=v2.11.8 \
    CACHE_HANDLER_VERSION=v0.17.0 \
    SIMPLEFS_VERSION=v0.0.22 \
    GOROOT="C:\\build\\go" \
    GOPATH="C:\\build\\gopath" \
    GOCACHE="C:\\build\\gocache" \
    GOTMPDIR="C:\\build\\tmp" \
    CGO_ENABLED=0 \
    GOOS=windows \
    GOARCH=amd64

USER ContainerAdministrator

# One RUN step that removes Go, the module cache and the build cache before it ends, so the
# layer docker commits holds only caddy.exe. Committing tens of thousands of small files is slow.
# The Go zip is downloaded to a file first; piping a zip into tar does not always extract every file.
# simplefs stores each cached response as a file and persists its index, so the cache survives restarts.
# simplefs/caddy v0.0.22 still requires simplefs v0.0.21, so simplefs itself is pinned too.
RUN mkdir C:\build\tmp C:\out && \
    curl -fL -o C:\build\go.zip https://go.dev/dl/go%GO_VERSION%.windows-amd64.zip && \
    tar -xf C:\build\go.zip -C C:\build && \
    set "PATH=%PATH%;%GOROOT%\bin;%GOPATH%\bin" && \
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@%XCADDY_VERSION% && \
    xcaddy build %CADDY_VERSION% \
        --output C:\out\caddy.exe \
        --with github.com/caddyserver/cache-handler@%CACHE_HANDLER_VERSION% \
        --with github.com/darkweak/storages/simplefs/caddy@%SIMPLEFS_VERSION% \
        --with github.com/darkweak/storages/simplefs@%SIMPLEFS_VERSION% && \
    C:\out\caddy.exe version && \
    C:\out\caddy.exe list-modules --packages --skip-standard && \
    go clean -modcache && \
    cd \ && rmdir /s /q C:\build

# Image stage
FROM ${BASE_IMAGE}

COPY --from=build ["C:/out/caddy.exe", "C:/Program Files/Caddy/caddy.exe"]
COPY ["Caddyfile", "C:/Program Files/Caddy/Caddyfile"]

# C:\cache holds cached responses and C:\caddy-data holds Caddy's state, including the
# internal CA's private key. Start-ArtifactCache.ps1 bind-mounts host folders over both.
USER ContainerAdministrator
RUN mkdir C:\cache && mkdir C:\caddy-data
VOLUME ["C:/cache", "C:/caddy-data"]

# 443 is the intercepting proxy, 8080 serves /healthz and /root.crt over plain HTTP
EXPOSE 443 8080

WORKDIR "C:/Program Files/Caddy"
ENTRYPOINT ["C:\\Program Files\\Caddy\\caddy.exe"]
CMD ["run", "--config", "C:\\Program Files\\Caddy\\Caddyfile", "--adapter", "caddyfile"]
