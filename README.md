# .github

Org-wide GitHub configuration for **mini-app-polis**. Two reusable
workflows: the fleet's shared security controls, and the trigger that asks
for a repository to be evaluated when it releases.

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
    uses: mini-app-polis/.github/.github/workflows/security.yml@v2
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

## Shared evaluation trigger

`.github/workflows/evaluate.yml` asks api-kaianolevine-com to evaluate a
repository's conformance. The API hands the job to evaluator-cog and
acknowledges; the evaluation runs after the calling job is gone.

A repository's conformance changes when that repository changes, so its own
release is the event that should evaluate it. Before this, a daily cron
swept the whole fleet at 09:00 — which graded a release up to a day late and
re-graded twelve repositories that had not changed.

### Using it

Add one job that runs after your release job:

```yaml
jobs:
  release:
    ...
  evaluate:
    needs: release
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    uses: mini-app-polis/.github/.github/workflows/evaluate.yml@v3
    secrets:
      api-key: ${{ secrets.CI_VALIDATOR_API_KEY }}
```

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `scope` | `repo` | `repo` evaluates the calling repository; `fleet` evaluates every repository in the registry |
| `ref` | the default branch | Branch or tag to evaluate |
| `repo` | the calling repository | Repository name, without the org |
| `org` | the calling owner | Owning GitHub org |
| `repo-id` | *(none)* | The id findings are filed under. Monorepo apps only |
| `mode` | `deterministic` | `deterministic` or `llm` |
| `api-url` | `https://api.kaianolevine.com` | Base URL of api-kaianolevine-com |
| `wait-seconds` | `0` | Pause before asking. For a repo whose release redeploys a service the evaluation needs |

`secrets.api-key` is required: the `ci-validator` machine key, held as an
organisation secret. It carries one scope, `evaluations.runs.create`, and
cannot write a finding — a leaked CI key can cause work to happen, but
cannot forge the result of that work.

### Two repos sweep, the rest do not

`scope: fleet` belongs to **ecosystem-standards** and **evaluator-cog**, and
to nothing else. A new rule catalog or a new evaluator invalidates every
repository's last result at once; every other release invalidates one. The
sweep also carries the three checks that scope to no repository at all
(EVAL-003, MONO-003, EVAL-007), which is why it is not merely a loop over
the single-repository path.

Nothing in the credential enforces that split — every repo's CI holds the
same key. What enforces it is which workflows pass `scope: fleet`, which is
a property of this file and its callers rather than of a secret.

### `wait-seconds` exists for exactly one repo

evaluator-cog's release redeploys the evaluator — the thing being asked.
Railway takes longer to swap a container than curl's retries cover, so a
request sent immediately reaches a process that is going away, or nothing.
That repo passes `wait-seconds: 120`. Everywhere else the default of zero
is correct and the step is skipped.

### It fails when the request does

The evaluation itself runs after this job ends, so the job cannot report on
it. What it does report is whether the request landed, and a rejected or
unreachable API fails the step. A silently dropped trigger leaves a
repository's conformance record frozen at its last good state while looking
healthy, which is the failure shape the fleet's delivery assertions exist to
catch.

It distinguishes three outcomes rather than collapsing them into one exit
code, because they need different people to fix them:

| What came back | What it means |
|---|---|
| 2xx | The API accepted the job. The evaluation runs after this job ends |
| Non-2xx with an HTML body | The edge refused the request and the API never saw it. A WAF or bot-protection problem, not authentication and not dispatch |
| Non-2xx with a JSON body | The API answered and refused. The error code says why — a missing scope, an unconfigured dispatcher, an unreachable evaluator |

The middle row is the one worth spelling out. A 403 from Cloudflare and a
403 from authorization are the same status code and entirely different
problems, and dumping a challenge page into a CI log leaves whoever reads
it to work that out for themselves.

## Versioning

Consumers pin a major tag. Three exist:

| Tag | Contains |
|---|---|
| `v1` | `security.yml` only, before the osv-scanner swap |
| `v2` | `security.yml` as the fleet calls it today |
| `v3` | the same `security.yml`, plus `evaluate.yml` |

A backwards-compatible change is normally published by retagging the
major at the new commit, and anything that would break a consumer — an
input removed or renamed, a job made gating that was not — gets a new
major instead.

`evaluate.yml` arrived on `v2` and then needed two fixes in the same
afternoon. Both were additive, so both were eligible for a retag, and
both were missed: the callers kept resolving the stale file, and a caller
running it was indistinguishable from one running the fix. `v3` cuts that
knot — a fixed tag that has to be moved to deliberately. It is also why
the job's first log line names its own version: whichever way the policy
goes, the running revision has to be visible from the log rather than
inferred from which error message appeared.

`security.yml` is byte-identical across `v2` and `v3`, so a repo calling
it may pin either. The fleet pins `@v2` and there is no reason to churn
that; a repo calling both workflows pinning two different majors is
correct, not a mistake.

`CHANGELOG.md` is how a consumer finds out what moved under them. It is
maintained by hand; there is no release automation in this repo.

## Conformance

This repo is registered in `ecosystem-standards/ecosystem.yaml` as type
`shared-workflows`, so the steps above are evaluated in their own right —
once, rather than once per consumer. That is what makes the delegation
escape hatch honest: a repo that calls this workflow is not skipping the
check, it is pointing at a copy that is itself checked.
