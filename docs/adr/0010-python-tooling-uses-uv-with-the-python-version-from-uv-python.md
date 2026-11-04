# 0010. Python tooling uses uv, with the Python version set by the `UV_PYTHON` environment variable

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md)

## Context

The repo needs a small amount of Python, starting with the convention tests in [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md), which parse workflow YAML. That needs a third-party package (PyYAML) and a reproducible environment on developer machines and in CI. The repo has no other Python, and the hosts don't have a dependable system Python. On Windows, `python` is often just the Microsoft Store stub.

## Decision

- [uv](https://docs.astral.sh/uv/) manages Python and the packages. The root `pyproject.toml` declares the dependencies, with `[tool.uv] package = false` because the repo isn't a Python package. `uv.lock` is committed.
- PyYAML parses YAML. pytest runs the tests. Both are pinned through `uv.lock`.
- The Python interpreter version comes from the `UV_PYTHON` environment variable, together with `UV_PYTHON_PREFERENCE=only-managed`. uv then downloads exactly that CPython version and never uses a Python already on the machine. CI sets both at workflow level. `pyproject.toml` sets only a lower bound (`requires-python`). Locally, a developer sets `UV_PYTHON` the same way, and gets uv's default managed Python if they don't.
- Commands run through `uv run`, for example `uv run pytest`. Nobody activates a virtual environment by hand.

## Consequences

- One tool installs Python, creates the environment and runs the tests, on Windows and Linux alike. CI only needs `astral-sh/setup-uv`, pinned to a commit.
- A Python upgrade is a one-line environment variable change in the workflow, separate from any dependency change.
- Contributors need uv installed (`winget install astral-sh.uv`).

## Alternatives considered

- **pip and venv with `requirements.txt`.** It needs a system Python first and has no lock file with hashes unless pip-tools is added.
- **`.python-version` file.** uv supports it, but the requirement was that the version is set through an environment variable, which CI can also override per job or in a matrix.
- **`actions/setup-python`.** It works only in CI, so local runs would use a different interpreter.
