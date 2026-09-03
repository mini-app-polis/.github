# Changelog

Consumers pin `@v1`, and that tag moves. This file is how they find out
what moved. Maintained by hand — there is no release automation here.

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
