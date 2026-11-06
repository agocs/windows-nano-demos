---
name: coverage-gaps
description: Find exactly which lines of scripts/ the tests don't cover, with the function each gap is in and a few lines of code, instead of reading whole scripts or coverage tables. Use when the 95% coverage gate fails, before writing tests for a script, or when asked what is untested.
---

# Coverage gaps

The `Repo tests` workflow and the pre-commit hook fail when the tests cover less than 95% of `scripts/` (`fail_under` in `pyproject.toml`). To see what's missing, don't read the scripts or the full coverage table. Run:

```bash
uv run pytest -q --cov --cov-report=json   # writes coverage.json (git-ignored)
uv run python scripts/coverage_gaps.py     # --lines 5 shows more code per gap
```

For each file below 100%, it prints the uncovered line ranges, the function or method each range is in, and its first lines of code. Then read only those functions, and write tests for them:

- Put the tests in the script's test file. For I/O and `main()` code, follow `tests/test_script_io.py`: fake `gh`, `git`, HTTP and files with `monkeypatch`, or with the injectable callables the scripts take (`run_gh`, `run_cmd`, `fetch`, `sleep`), so tests run offline.
- Parametrize over cases and repo items rather than looping inside one test.
- Iterate with `uv run pytest -q --lf` or `-k <name>`, and run the full `--cov` suite once at the end.

A gap that is truly unreachable, such as a defensive `raise`, can stay uncovered while the total stays at 95% or more. Never lower `fail_under` to make a branch pass.

For a pull request's coverage on Codecov, including the patch coverage of the changed lines, use the `codecov` skill.
