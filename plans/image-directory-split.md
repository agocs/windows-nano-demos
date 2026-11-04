# Image directory split

## Goal

Reorganize image folders into two top-level directories—`nano-server/nano-server-FOO` for nanoserver-based images and `server-core/server-core-FOO` for servercore-based images—to clarify each image's base, update image names and labels, and enforce the structure with tests.

## Context

Today all images live in top-level `nano-server-*` folders: `nano-server-php`, `nano-server-rust`, `nano-server-ssh`, `nano-server-go`, `nano-server-powershell`, `nano-server-far`, and `nano-server-gh-runner`. The folder names suggest they all run on nanoserver, but `nano-server-far` requires servercore (Far needs desktop DLLs nanoserver lacks), and `nano-server-ssh` uses servercore for ltsc2025 (nanoserver 2025 rejects all local-account logons). The naming is misleading.

This work is issue #25, which requests the split. Three open branches (vim/neovim #16, wine-tools #21, api-tests #22) were created before this structure change and will need rebasing.

Tests in `tests/repo_conventions.py` and `tests/test_images.py` discover images as top-level folders with a Dockerfile. After the move, they must discover images under two subdirectories instead.

## Decisions

1. **Directory structure:** `nano-server/nano-server-FOO` for images built on the nanoserver base, `server-core/server-core-FOO` for images built on servercore. This matches the base image inside the Dockerfile (ADR 0008), making the structure self-documenting. ADR needed: "Directory structure for base-image-specific images."

2. **Issue #25 typo:** The issue text says "namo-server" in the path description; this is a typo for "nano-server". The plan uses "nano-server" (hyphenated, 2 words).

3. **nano-server-ssh location:** SSH stays in `nano-server/nano-server-ssh` because:
   - It is fundamentally a nanoserver image (2019 and 2022 use nanoserver successfully).
   - The 2025 servercore requirement is a workaround handled by `base-image-overrides` in the workflow, not a primary design.
   - ADR 0008 explicitly allows version-specific base image overrides.
   - Keeping it in nanoserver reflects its primary use and historical design.

4. **Docker Hub image names:** `windows-nano-FOO` for nanoserver-based images and `windows-servercore-FOO` for servercore-based images. Local build tags follow the same pattern: `windows-nano-php:2025`, `windows-servercore-far:2025`. This makes the source and Docker Hub names consistent.

5. **Image labels:** Every image gets labels set by `docker build --label` in the reusable workflow (see ADR 0009) and defines its own `LABEL` instructions in the Dockerfile for `org.opencontainers.image.base.name` (nanoserver or servercore). The `build-windows-image.yml` reusable workflow is extended to pass the base name as a build argument, computed from the Dockerfile or supplied via `base-image-overrides`.

6. **Test discovery:** `image_dirs()` in `repo_conventions.py` is updated from discovering top-level folders with a Dockerfile to discovering folders in `nano-server/` and `server-core/` subdirectories with a Dockerfile. The tests then check that each image's base matches its directory (nanoserver images have `ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:...`, servercore images have `servercore:...`).

7. **Open branches:** Authors of the three open branches (#16, #21, #22) are notified to rebase once this lands. A guide is added to the root README or a new doc for rebasing image branches.

## Plan

### Phase 1: ADR, tests, and discovery

- [ ] **adr**: Write ADR 0012 "Directory structure for base-image-specific images". Title and decision as in Decisions above. Accept: `docs/adr/README.md` lists it as Accepted, and markdownlint passes.

- [ ] **python-author**: Update `image_dirs()` in `repo_conventions.py` to discover `nano-server/nano-server-*` and `server-core/server-core-*` folders with Dockerfiles. Add a new test that verifies nanoserver images are under `nano-server/` and servercore images are under `server-core/` by checking their `ARG BASE_IMAGE` line. Accept: `uv run pytest tests/test_images.py` passes with the updated test, and `pytest tests/repo_conventions.py` passes when run against the old folder structure (before the move).

- [ ] **python-author**: Update `test_workflows.py::TestEveryImageHasACallerWorkflow` to build path expectations from the new discovered image structure. Accept: `uv run pytest tests/test_workflows.py` passes on the old structure.

### Phase 2: Directory structure and image Dockerfiles

- [ ] **container-author**: Create `nano-server/` and `server-core/` directories. Accept: `ls -d C:\Users\JustinDearing\source\repos\wt-plans\{nano-server,server-core}` exists.

- [ ] **container-author**: Move images using `git mv`: `nano-server-php` → `nano-server/nano-server-php`, `nano-server-go` → `nano-server/nano-server-go`, `nano-server-powershell` → `nano-server/nano-server-powershell`, `nano-server-rust` → `nano-server/nano-server-rust`, `nano-server-ssh` → `nano-server/nano-server-ssh`, `nano-server-gh-runner` → `nano-server/nano-server-gh-runner`, and `nano-server-far` → `server-core/server-core-far`. Accept: `git log --oneline` shows one commit moving all folders, and `git diff HEAD~1..HEAD --name-status` shows all M (moved) operations.

- [ ] **container-author**: For each image Dockerfile, update the `LABEL` instruction to set `org.opencontainers.image.base.name` to `nanoserver` or `servercore` based on the image's base. Accept: each Dockerfile contains `LABEL org.opencontainers.image.base.name=nanoserver` or `...servercore`.

- [ ] **container-author**: Update each image `build.cmd` to pass `--build-arg BASE_IMAGE_NAME=nanoserver` (or servercore) if the image always uses that base, and update any existing references to the image name to use the new `windows-nano-FOO` or `windows-servercore-FOO` naming. Accept: `build.cmd` files have the correct image names and build args.

### Phase 3: Workflow path filters and image inputs

- [ ] **workflow-author**: Update every caller workflow (`.github/workflows/*-container.yml`, `.github/workflows/ssh-server.yml`, `.github/workflows/far-manager.yml`, `.github/workflows/gh-runner-container.yml`) to:
  - Update the path filter from `nano-server-FOO/**` to `nano-server/nano-server-FOO/**` or `server-core/server-core-FOO/**`.
  - Update the `context` input to the reusable workflow from `nano-server-FOO` to `nano-server/nano-server-FOO` or `server-core/server-core-FOO`.
  - Update the `image` input to `windows-nano-FOO` or `windows-servercore-FOO`.
  - Accept: actionlint passes on all workflows, and each workflow's path filter matches its image's new location.

- [ ] **workflow-author**: Add a `base-image-name` input to `build-windows-image.yml` (default: derived from the context folder name, but overridable). Update the `docker build` step to pass `--label org.opencontainers.image.base.name=${{ inputs.base-image-name }}`. Accept: actionlint is clean and a test run sets the label correctly.

### Phase 4: Documentation updates

- [ ] **container-author**: Update the root `README.md` to list images under their new directory, for example:

  ```markdown
  ## Nano Server images
  - [nano-server/nano-server-rust](nano-server/nano-server-rust/README.md): Rust...
  - [nano-server/nano-server-php](nano-server/nano-server-php/README.md): PHP...
  ...

  ## Server Core images
  - [server-core/server-core-far](server-core/server-core-far/README.md): Far Manager...
  ```

  Accept: markdownlint passes and every image has a link to its new path.

- [ ] **markdown-fixer**: Fix any markdownlint errors in `README.md` or other updated docs. Accept: markdownlint is clean.

- [ ] **container-author**: Update each image's `README.md` if it references its own path in examples or instructions. For example, change `docker build nano-server-php` to `docker build nano-server/nano-server-php`. Accept: each README's code examples use the correct paths.

- [ ] **container-author**: Add a new doc `docs/REBASING_IMAGES.md` explaining how to rebase image branches (like #16, #21, #22) on top of this change. Example:

  ```bash
  git checkout <branch>
  git rebase main
  # Update paths in commit messages, Dockerfiles, and workflows
  git push -f origin <branch>
  ```

  Accept: document exists and is clear.

### Phase 5: Tests and CI validation

- [ ] **python-author**: Run `uv run pytest tests/` against the new structure to ensure all tests pass. Accept: `uv run pytest tests/` exits with code 0 and all tests pass.

- [ ] **workflow-author**: Ensure `.github/workflows/repo-tests.yml` is clean (it should be, since tests run on `ubuntu-latest`). Accept: `repo-tests` workflow runs green on a test branch.

- [ ] **governance**: Audit after all changes land: verify every image folder is under `nano-server/` or `server-core/`, every workflow path filter is updated, and tests enforce the structure. Accept: audit reports no gaps.

### Phase 6: Notification and cleanup

- [ ] **container-author**: Add a note to the `CHANGELOG.md` or similar (if it exists) documenting the directory structure change and when it occurred. Accept: changelog entry is present.

- [ ] **python-author**: If any utility scripts (e.g., `scripts/check_pins.py` or similar) reference image paths, update them to use the new discovery pattern. Accept: scripts run without errors on the new structure.

## Risks

- **Open branches break:** Branches #16, #21, #22 have commits that reference the old paths. They must be rebased. Mitigation: provide a clear rebasing guide and offer to review rebase commits.
- **Partial updates miss a path:** A workflow, README, or test file might reference the old path and be missed. Mitigation: `grep -r "nano-server-"` before declaring done, excluding `.git/`.
- **Docker Hub tag migration:** Images push to Docker Hub with new names. Old `windows-nano-far` tags become inaccessible. Mitigation: record the old names in the changelog and note that `windows-servercore-far` is the new pull location.
- **Workflow dispatch references:** Any workflow that names an image by its old name (in dispatch inputs or docs) must be updated. Mitigation: grep workflows for old image names.

## Owners

| Agent | Tasks |
| --- | --- |
| `adr` | ADR 0012 (directory structure) |
| `container-author` | Directory creation, git mv operations, Dockerfile labels, build.cmd updates, README updates, rebasing guide, changelog |
| `workflow-author` | Path filter updates, context and image input updates, reusable workflow `base-image-name` input |
| `python-author` | Update `image_dirs()` and discovery tests, run pytest suite |
| `markdown-fixer` | Markdownlint cleanup on updated docs |
| `governance` | Post-migration audit |
