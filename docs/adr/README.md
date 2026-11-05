# Architecture decision records

These records explain why this repo is built the way it is. Each one covers a single decision in MADR style: status, context, decision, consequences, and alternatives considered. To add one, use the `adr` agent or copy the layout of an existing record into the next number, and add it to this table. To change a decision, write a new record that supersedes the old one.

| Number | Title | Status | Date |
| --- | --- | --- | --- |
| 0001 | [Record architecture decisions](0001-record-architecture-decisions.md) | Accepted | 2026-11-04 |
| 0002 | [Build every image for ltsc2019, ltsc2022, and ltsc2025](0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md) | Accepted | 2026-11-04 |
| 0003 | [Self-hosted nanoserver runners using the host docker daemon via named pipe](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md) | Accepted | 2026-11-04 |
| 0004 | [Rebuild all images on base-image digest change](0004-rebuild-all-images-on-base-image-digest-change.md) | Proposed | 2026-11-04 |
| 0005 | [Tagging scheme for Windows images](0005-tagging-scheme-for-windows-images.md) | Proposed | 2026-11-04 |
| 0006 | [Publish to Docker Hub only from main via the image refresh workflow](0006-publish-to-docker-hub-only-from-main-via-scheduled-workflow.md) | Proposed | 2026-11-04 |
| 0007 | [Separate tool-version bumps from base-image refreshes](0007-separate-tool-version-bumps-from-base-image-refreshes.md) | Proposed | 2026-11-04 |
| 0008 | [Images take the Windows version as an argument, default to 2025, and build as a matrix](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) | Accepted | 2026-11-04 |
| 0009 | [All image builds use one reusable workflow](0009-all-image-builds-use-one-reusable-workflow.md) | Accepted | 2026-11-04 |
| 0010 | [Python tooling uses uv, with the Python version set by the `UV_PYTHON` environment variable](0010-python-tooling-uses-uv-with-the-python-version-from-uv-python.md) | Accepted | 2026-11-04 |
| 0011 | [Repository conventions are enforced by tests in CI](0011-repository-conventions-are-enforced-by-tests-in-ci.md) | Accepted | 2026-11-04 |
| 0012 | [Images live in a directory for their base image](0012-images-live-in-a-directory-for-their-base-image.md) | Accepted | 2026-11-05 |
