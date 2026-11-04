ARG WINDOWS_VERSION=2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# Thin probe layer: the image under test is not changed, only apiprobe.exe,
# the L1/L2 inventory for this Windows version and the baselines are added.
ARG WINDOWS_VERSION
COPY bin/apiprobe.exe C:/api-tests/apiprobe.exe
COPY data/${WINDOWS_VERSION}/ C:/api-tests/data/
COPY expectations/ C:/api-tests/expectations/
ENV APIPROBE_WINDOWS_VERSION=${WINDOWS_VERSION}
ENTRYPOINT ["cmd", "/S", "/C"]
