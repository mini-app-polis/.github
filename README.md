# .github

Org-wide GitHub configuration for **mini-app-polis**. Today that means one
thing: the fleet's shared security workflow.

## Shared security workflow

`.github/workflows/security.yml` is a reusable workflow that runs four
controls:

| Job | Rule | Gating |
|---|---|---|
| `secret-scan` | SEC-001 / SEC-002 | yes — a detected secret fails the build |
| `dependency-audit` | SEC-003 | yes — a vulnerable resolved dependency fails the build |
| `static-analysis` | SEC-004 | no — advisory by design |
| `sbom` | SEC-005 | n/a — generates and retains a CycloneDX SBOM |

### Using it

Add one job to an existing workflow that triggers on `pull_request`:

```yaml
jobs:
  security:
    uses: mini-app-polis/.github/.github/workflows/security.yml@v1
    with:
      language: python
      package-manager: uv
```

The doubled `.github` in the path is correct: the first is the repository,
the second is the directory inside it.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `language` | `python` | `python` or `typescript` — selects the audit and SAST tooling |
| `package-manager` | `uv` | `uv`, `pip`, `pnpm` or `npm` — how dependencies are resolved before the audit |
| `sbom` | `true` | Generate and retain a CycloneDX SBOM |
| `gitleaks-version` | `8.28.0` | Pinned gitleaks release |
| `syft-version` | `1.29.1` | Pinned syft release |

### Not required

Calling this workflow is one of two conformant shapes. A repo may equally
carry its own secret-scan, audit, SAST and SBOM steps inline —
ecosystem-standards SEC-002 through SEC-005 accept either. The shared
workflow exists so the tooling, the pinned versions and the gating
decisions live in one place rather than being copied into every repo and
drifting; it is not a mandate.

### Secret scanning is two halves

The workflow covers CI. SEC-001 asks for the same gitleaks in a local
pre-commit hook, which each repo must add for itself — a hook in this
repo does not run in yours. Copy `.pre-commit-config.yaml` from here.

## Versioning

Consumers pin `@v1`. That tag moves: a backwards-compatible change is
published by retagging `v1` at the new commit. Anything that would break a
consumer — an input removed or renamed, a job made gating that was not —
gets a new major tag (`v2`) instead, and consumers migrate deliberately.

`CHANGELOG.md` is how a consumer finds out what moved under them. It is
maintained by hand; there is no release automation in this repo.

## Conformance

This repo is registered in `ecosystem-standards/ecosystem.yaml` as type
`shared-workflows`, so the steps above are evaluated in their own right —
once, rather than once per consumer. That is what makes the delegation
escape hatch honest: a repo that calls this workflow is not skipping the
check, it is pointing at a copy that is itself checked.
