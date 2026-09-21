# .github

Org-wide GitHub configuration for **mini-app-polis**. Four reusable
workflows, one per stage of a repo's `ci.yml` (ecosystem-standards CD-026):

| Stage | Workflow |
|---|---|
| `security` | `security.yml` — the fleet's shared security controls |
| `test` | `python-test.yml` — lock check, lint, format and tests for a uv repo |
| `deploy` | `lambda-deploy.yml` — build, prove and upload a cog's Lambda zip |
| `evaluate` | `evaluate.yml` — ask for the repository to be evaluated |

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

## Shared test stage

`.github/workflows/python-test.yml` is the `test` job for a uv-managed
Python repo: `uv lock --check` (CD-020), `uv sync --locked`, `ruff check`,
`ruff format --check`, then pytest. It is the union of what the cogs ran
inline, so adopting it removes no check a caller had.

```yaml
jobs:
  test:
    uses: mini-app-polis/.github/.github/workflows/python-test.yml@v3
```

| Input | Default | Meaning |
|---|---|---|
| `python-version` | `3.11` | Match the runtime the repo deploys to |
| `pytest-args` | `--cov=src --cov-report=term-missing` | Appended to pytest |

## Shared Lambda deploy

`.github/workflows/lambda-deploy.yml` builds a cog's function zip from its
lockfile, proves it starts in Lambda's own runtime, uploads it, and fails
unless the checksum AWS reports is the one it built. Each cog's `infra/`
owns the function's configuration; this owns only its code.

```yaml
jobs:
  deploy:
    needs: release
    if: needs.release.outputs.tag != ''
    permissions:
      id-token: write
      contents: read
    uses: mini-app-polis/.github/.github/workflows/lambda-deploy.yml@v3
    with:
      ref: ${{ needs.release.outputs.tag }}
      handler: deejay_cog.worker.lambda_handler
      architecture: x86_64
      role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
      region: ${{ vars.AWS_REGION }}
      function-name: ${{ vars.AWS_FUNCTION_NAME }}
```

Called as a job after `release`, never `on: release` — semantic-release
publishes with `GITHUB_TOKEN`, and GitHub starts no workflows from that
token's events. A job that must run on the new code (evaluator-cog's fleet
sweep) `needs: deploy`.

| Input | Default | Meaning |
|---|---|---|
| `ref` | *(required)* | The release tag to build |
| `handler` | *(required)* | `module.function`, as `handler` in the cog's `infra/worker.tf` |
| `architecture` | *(required)* | `x86_64` or `arm64`, as `architectures` in `infra/worker.tf`. The deploy refuses a function whose architecture differs |
| `python-version` | `3.11` | As `runtime` in `infra/worker.tf` |
| `strip` | *(none)* | Top-level paths to drop from the zip because the cog never imports them. boto3 is always dropped |
| `role-arn`, `region`, `function-name` | *(required)* | From the cog's `terraform output` |

### Three guards, because one was not enough

1. **Wheels are chosen for the target, not the runner** —
   `--python-platform <arch>-manylinux_2_17` for the Amazon Linux 2
   runtimes. Left to itself uv picks what the Ubuntu runner can load.
2. **No compiled library may need a newer glibc than the runtime has.**
   Names the offending file.
3. **Every module imports, and the handler answers a probe record, inside
   `public.ecr.aws/lambda/python:<version>`** for the target architecture
   (arm64 under QEMU). A pass means the function will start.

Each exists because of the one before it failing. The deploy these replace
chose wheels for the runner and checked imports on the runner: deejay-cog's
first deploy passed that check and failed at import on Lambda (cryptography
needing GLIBC_2.28, runtime has 2.26), and evaluator-cog had been shipping
x86_64 builds of pydantic-core and cryptography to an arm64 function
without tripping it only because nothing it ran imported them.

## Versioning

Consumers pin a major — `evaluate.yml@v3`, `security.yml@v2` — and that tag
moves. semantic-release cuts `v3.0.1` from the commit messages, and
`scripts/move-major-tag.sh` runs as its `successCmd` to force-push `v3` onto
it. A run with no releasable commits never reaches that script, so the major
tag correctly stays put.

| Tag | Contains |
|---|---|
| `v1` | `security.yml` only, before the osv-scanner swap |
| `v2` | `security.yml` as most of the fleet calls it today |
| `v3` | the same `security.yml`, plus `evaluate.yml`, `python-test.yml` and `lambda-deploy.yml`. Moves with each release |

`security.yml` is byte-identical across `v2` and `v3`, so a repo calling it
may pin either. A repo pinning two different majors is correct, not a
mistake.

### Why this is automated rather than documented

It used to be a step in a person's head: cut the change, then remember to
retag. On 2026-09-13 that step was missed three times in one afternoon.
Every time, consumers kept resolving the previous file, and every time the
symptom was a CI failure that read as a bug in the workflow — a stale caller
and a current one produce identical output, so there was nothing in a log to
say which had run.

Two things came out of that. The retag is now part of the release rather
than a thing to remember, and the job announces its own version on its first
line so a stale caller is visible rather than inferred.

`CHANGELOG.md` is how a consumer finds out what moved under them. Entries
above the `v3 — 2026-09-13` heading are generated by semantic-release;
everything below it was maintained by hand, before this repo had a release
job at all.

## Conformance

This repo is registered in `ecosystem-standards/ecosystem.yaml` as type
`shared-workflows`, so the steps above are evaluated in their own right —
once, rather than once per consumer. That is what makes the delegation
escape hatch honest: a repo that calls this workflow is not skipping the
check, it is pointing at a copy that is itself checked.
