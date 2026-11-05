# EXPERIMENTAL - not wired into CI. Part of plans/go-cgo.md.
# Layers Zig (zig cc as the C compiler) onto an already built windows-nano-go image.
ARG GO_IMAGE=windows-nano-go:2025
FROM ${GO_IMAGE}

ENV ZIG_VERSION=0.17.1 \
    TOOLCHAIN_DIR="C:\\Program Files\\zig"

RUN curl -fLO https://ziglang.org/download/%ZIG_VERSION%/zig-x86_64-windows-%ZIG_VERSION%.zip && \
    tar -xf zig-x86_64-windows-%ZIG_VERSION%.zip -C "%ProgramFiles%" && \
    ren "%ProgramFiles%\zig-x86_64-windows-%ZIG_VERSION%" zig && \
    del zig-x86_64-windows-%ZIG_VERSION%.zip

ENV CGO_ENABLED=1 CC="zig cc -target x86_64-windows-gnu" CXX="zig c++ -target x86_64-windows-gnu"
RUN setx PATH "%TOOLCHAIN_DIR%;%GOROOT%\bin;%GOPATH%\bin;%MINGIT_DIR%\cmd;%MICROEDITOR_PATH%"
