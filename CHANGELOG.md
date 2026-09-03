# Changelog

Consumers pin `@v1`, and that tag moves. This file is how they find out
what moved. Maintained by hand — there is no release automation here.

## v1 — 2026-09-03 (2)

Fixes found by the first real run.

- Action majors now match the rest of the fleet: `checkout@v6`,
  `setup-python@v6`, `setup-node@v6`, `setup-uv@v7`,
  `upload-artifact@v7`, `pnpm/action-setup@v5`. The first cut used v4/v5
  majors that still target Node 20, which GitHub now warns about on
  every job.
- The dependency audit no longer falls back to a bare `pip-audit`. With
  no `--requirement` it audits the *runner's* ambient environment and
  reports whatever GitHub ships in its image — the first run failed on
  `setuptools 79.0.1`, a package no repo here depends on. A repo with no
  `pyproject.toml` or `requirements.txt` now skips the audit with a
  message instead.
- `uv` is installed via `astral-sh/setup-uv@v7` rather than `pip install
  uv`, matching the fleet.
- Two classes of line are stripped from the resolved requirements before
  auditing, because `--strict` treats "not on PyPI" as a hard error: the
  project's own `-e .` entry, and dependencies pulled from git (the
  fleet's internal libraries, which are audited in their own repos).
  Both were fatal — every consumer would have failed on `-e .` alone.
  What is excluded is printed, so it is visible rather than silent.
- The Node branch skips cleanly when there is no `package.json`.

## v1 — 2026-09-03

Initial shared security workflow.

- `secret-scan` — gitleaks 8.28.0, installed from the pinned release
  binary rather than an action, scanning full history. Gating.
- `dependency-audit` — `pip-audit` for Python (resolving through `uv
  export` when `package-manager: uv`), `pnpm audit` / `npm audit` for
  TypeScript. Gating. No severity threshold is passed: the flag
  spellings differ between the tools and change between versions, and
  ecosystem-standards SEC-006 declares the response deadlines instead.
- `static-analysis` — semgrep, `continue-on-error: true` by design.
- `sbom` — syft 1.29.1 producing CycloneDX JSON, uploaded as a build
  artifact from the same job. Retained 90 days.

Inputs: `language`, `package-manager`, `sbom`, `gitleaks-version`,
`syft-version`.
