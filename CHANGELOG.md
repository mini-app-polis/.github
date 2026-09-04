# Changelog

Consumers pin a major tag, and that tag moves within its major. A change
that can fail a build which previously passed cuts a new major instead.
This file is how consumers find out what moved. Maintained by hand —
there is no release automation here.

## v2 — 2026-09-04

BREAKING for TypeScript consumers. Python consumers are unaffected — the
Python path is byte-identical — and can stay on `@v1` or move to `@v2`
whenever convenient.

Two changes, both in the Node dependency audit:

- **`pnpm audit` replaced with `osv-scanner`.** Both `pnpm audit` and
  `npm audit` POST the resolved tree to npm's advisory endpoint. That
  endpoint returned nothing — connection open, zero bytes, no error —
  across three CI runs in two repos, while the registry itself served
  package metadata in under 100ms and npm's status page reported 100%
  uptime for Security Audit. A raw `curl` reproduces it with no package
  manager involved, from two unrelated networks; the same call succeeds
  from a residential connection, so it appears specific to CI address
  space. A scanner that cannot reach its database cannot gate anything,
  and this one failed as a silent hang rather than a message.

  `osv-scanner` reads the committed lockfile and queries OSV.dev — the
  same shape as the Python path: resolve the dependency set, check it
  against a vulnerability database. SEC-003 permits the substitution
  directly: "the requirement is that the ecosystem's installed
  dependency graph is checked against a vulnerability database on every
  change, not that a particular tool does it."

- **The `moderate` severity floor is gone.** `pnpm audit --audit-level
  moderate` ignored `low` findings; `osv-scanner` has no severity filter,
  so the Node gate now fails on any known vulnerability. That aligns it
  with `pip-audit --strict`, which the Python path has always enforced —
  but a TypeScript repo that passed under v1 can fail under v2 with no
  change of its own. This is the breaking part.

Consequences worth knowing before moving a repo to `@v2`:

- The Node audit installs nothing. `osv-scanner` reads `pnpm-lock.yaml` /
  `package-lock.json` directly, so `setup-node`, `pnpm/action-setup` and
  `pnpm install --frozen-lockfile` are gone from that job. It is
  substantially faster.
- The `package-manager` input is now ignored for TypeScript. It still
  selects `uv` vs `pip` for Python.
- `upload-sarif` is disabled. The security-tab upload requires GitHub
  Advanced Security on private repos; with it enabled the upload fails
  and takes the gate down with it.
- The "no Node dependencies, skip cleanly" behaviour from v1 is
  preserved, but now as a `node-manifest` preflight job — a called
  workflow cannot carry that shell guard itself. Repos with no lockfile
  skip the audit as before.

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
