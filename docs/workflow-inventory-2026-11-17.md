# Workflow inventory — 2026-11-17

A dated snapshot of every mini-app-polis repository's GitHub Actions
workflows, grouped by stage, made as the first step of the canonical
pipeline work. It records what was there on this date and is not kept up
to date: the canonical pipeline's specification and conformance rules
replace it.

Read on 2026-11-17 from each repository's `dev` branch (`main` for this
repository, which has no `dev`). The commit read is given with each
repository below. `wcs-wiki` is private and has no workflows (the repository
status page shows no checks for it), so it has no section.

Deploy settings outside GitHub were read the same day: Railway's service
source settings through the Railway API, and Cloudflare Pages' Git
integration from `infra` (`cloudflare_pages.tf`, `cloudflare_pages_sites.tf`).

## Stage model

Every job is put in one of these stages:

| Stage | Meaning |
|---|---|
| verify | lint, format, type check, unit and integration tests, contract tests, smoke tests and end-to-end tests |
| build | producing an artifact that later stages use (today only the SBOM is produced and kept) |
| security | secret scan, dependency audit, static analysis |
| evaluate | asking evaluator-cog to grade the repository |
| release | semantic-release cutting a version and tag |
| deploy | putting a release where it runs: Lambda, Railway, Cloudflare Pages, Terraform apply |

Two kinds of workflow are not pipeline stages and are labelled separately.
**Branch flow** is the dev → main model (`promote.yml`, `automerge.yml`,
infra's `sync-dev`). **Outside the pipeline** covers the board agent, fleet
maintenance run from `.github` (`commons-update.yml`, `dependency-fix.yml`)
and on-demand triggers (`sweep-now.yml`).

## Repository types

| Type | Repositories |
|---|---|
| Python Lambda cog | deejay-cog, evaluator-cog, rotator-cog, task-manager-cog, task-refiner-cog, transcription-cog, watcher-cog, wiki-curator-cog |
| Python service on Railway | api-deejaytools, api-kaianolevine-com, db-ops |
| Python library on PyPI | common-python-utils, identity |
| Standards catalog | ecosystem-standards |
| Site on Cloudflare Pages | deejaytools-com, kwalla-dance, website-astro-software, website-astro-wcs, website-astro-wcsmn |
| Terraform infrastructure | infra |
| Shared workflows (main only) | .github |

## What every repository shares

- `agent.yml` (`workflow_dispatch`) calls the shared `agent.yml@v3` in all 20 repositories besides .github, which defines it.
- `promote.yml` (push to `dev`) calls the shared `promote.yml@v3`, in all 20 that have a `dev`.
- `automerge.yml` (after CI completes) calls the shared `automerge.yml@v3` in 19 of those 20; infra has none.
- `ci.yml` has the same skeleton in all but infra: `security` (shared `security.yml@v3`) and `test` run in parallel; `release` and `evaluate` run only on a push to `main`, after both. The workflow-level `concurrency` is `ci-${{ github.ref }}` with `cancel-in-progress: true`, and `permissions` is `contents: read`.
- Every shared workflow is referenced at `@v3`.

## Findings across the fleet

1. **Evaluation does not follow the release.** In 18 of the 20 `ci.yml` files, `evaluate` needs only `test` and `security`, so it runs at the same time as `release` and cannot receive its outputs. It waits a fixed number of seconds (`wait-seconds`) for a deploy it cannot see, and it sends the default branch rather than the released version or commit. Only ecosystem-standards (`evaluate` needs `release`) and evaluator-cog (`evaluate` needs `deploy`) order it after a release, as infra's `terraform.yml` does after its apply.
2. **A release on `main` can be cancelled partway.** `cancel-in-progress: true` applies to `main` as well as `dev`, so a second push to `main` cancels a run whose `release` or `deploy` job is in flight.
3. **No CI job has a timeout.** None of the `ci.yml` jobs declares `timeout-minutes`. Only 14 workflow files declare one anywhere (contract, site, agent and commons-update workflows), so most jobs run up to GitHub's 6-hour default.
4. **No action is pinned by SHA.** All 11 third-party actions are referenced by tag (`actions/checkout@v7`, `astral-sh/setup-uv@v7`, …); none uses a full commit SHA.
5. **Deploys mostly sit outside the pipeline.** Lambda cogs deploy from CI, gated on the release tag. Railway services and Cloudflare Pages sites deploy through the platforms' own branch integrations, on every push, whether or not CI passed or a release was cut (see below).
6. **The only build artifact is the SBOM.** Each later step rebuilds what it needs: `lambda-deploy.yml` builds its own zip from the release tag, Railway builds the Dockerfile, and Pages runs the site build.

## Deploy paths outside GitHub Actions

| Repository | Platform | Environment ← branch | Gate |
|---|---|---|---|
| api-kaianolevine-com | Railway service `api-kaianolevine-com` | production ← `main`; development ← `dev` | none: Railway branch auto-deploy, `checkSuites: false` |
| api-deejaytools | Railway service `api-deejaytools` | production ← `main`; development ← `dev` | none: Railway branch auto-deploy, `checkSuites: false` |
| db-ops | Railway cron services `db-backup`, `db-poller`, `db-drill` | production ← `main` (no development environment) | none: Railway branch auto-deploy, `checkSuites: false` |
| deejaytools-com, website-astro-wcs, website-astro-wcsmn, website-astro-software, kwalla-dance | Cloudflare Pages Git integration (`cloudflare_pages_sites.tf`) | production ← `main`; a preview for every other branch | none: Pages builds every push (`production_deployments_enabled`, `preview_deployment_setting = "all"`) |
| kwalla-dance | Cloudflare Pages deploy hook, from `rebuild.yml` (manual) | production | none; inert until `CLOUDFLARE_DEPLOY_HOOK` is set |
| — (not mini-app-polis repositories) | Cloudflare Pages Git integration in the same account: `bameo-wcs`, `capital-swing-convention`, `wcsmn-com` (`cloudflare_pages.tf`), `website-swingtacular` (domains only) | production ← `main` | out of scope here, listed because they share the account |

Inside GitHub Actions but outside the release gate: watcher-cog's
`deploy.yml` deploys an existing release tag by hand, for a deploy that
failed after its release.
Railway configuration (not code) is applied by `railway-apply.yml` on a
push to `main` that touches `.railway/**`, and infra applies Terraform on a
push to `main` from `terraform.yml`.

## Differences within a type

Each difference is marked **Input**, a variation the canonical pipeline must
accept as a declared input or extension point, or **Drift**, a variation
with no reason to exist that should be removed.

### Python Lambda cogs

| Difference | Repositories | Mark |
|---|---|---|
| `test` is an inline job instead of the shared `python-test.yml` | watcher-cog | Drift |
| `python-test.yml` inputs: `pytest-args` (coverage target), `typecheck` | rotator, task-manager, task-refiner, transcription, wiki-curator set `pytest-args`; deejay-cog and evaluator-cog set only `typecheck` | Input (coverage target per package); the missing coverage args in deejay-cog and evaluator-cog are Drift |
| `release` is an inline job (checkout, uv, deps, Node, the semantic-release action, "Record the release tag") instead of the shared `release.yml` | rotator-cog, task-manager-cog, task-refiner-cog, wiki-curator-cog | Drift: the shared `release.yml` already exposes `tag` |
| `pull_request` runs for every base branch rather than `main`/`dev` | rotator-cog, task-manager-cog, task-refiner-cog, watcher-cog, wiki-curator-cog | Drift |
| Lambda inputs: `handler`, `architecture` (`x86_64` for deejay-cog, `arm64` elsewhere), `trigger: schedule` (watcher-cog), the number of functions (four in deejay-cog) | all | Input |
| `evaluate` after `deploy` | evaluator-cog only | Drift in the other seven (Finding 1) |
| A job after deploy (`rebuild`: ask the API to rebuild every wiki page) | wiki-curator-cog | Input (post-deploy extension point) |
| A scheduled LLM evaluation sweep (`llm-sweep.yml`) | evaluator-cog | Input (scheduled evaluation) |
| A manual deploy of an existing release tag (`deploy.yml`), the way back in when a deploy failed after its release | watcher-cog | Input until the release reconciler resumes failed deploys, then Drift |

### Python services on Railway

| Difference | Repositories | Mark |
|---|---|---|
| `test` is inline in both APIs and the shared `python-test.yml` in db-ops | api-deejaytools, api-kaianolevine-com | Drift: the shared stage should take their extra steps as inputs |
| Extra checks in `test`: Drizzle baseline, the web app's schemas and the conformance suite (api-deejaytools); `facts check` (api-kaianolevine-com) | as named | Input (extension steps) |
| `deployed.yml` on `deployment_status`: smoke test and contract suites against the deployed API | the two APIs; not db-ops | Input (db-ops' cron services have no endpoint to check) |
| `pull_request` runs for every base branch | db-ops | Drift |
| Railway Infrastructure as Code (`railway-plan.yml` on PRs into `main`, `railway-apply.yml` on push to `main`) | all three, identical | consistent |

### Python libraries

| Difference | Repositories | Mark |
|---|---|---|
| `test` is inline (lint, format check, type check, then tests in common-python-utils and the conformance suite in identity) | both | Drift: the shared `python-test.yml` with inputs would serve both |
| `release` is inline and, after semantic-release, records the release and sends `commons-released` to `.github` so the fleet re-locks | both, identical | Input (library profile: publish and notify the fleet) |
| `contract.yml` runs the shared contract suite against the dev API | common-python-utils only | Input |
| `security` with `sbom: 'false'` | both | Drift to settle against the SBOM-retention rule |

### Sites on Cloudflare Pages

| Difference | Repositories | Mark |
|---|---|---|
| Package manager pnpm, `test` running typecheck, lint, test with coverage and build | deejaytools-com | Input (an app with unit tests, not a static site) |
| `test` running install, type check, build | website-astro-software, website-astro-wcs, website-astro-wcsmn | consistent |
| `test` with no type check (install, build only) | kwalla-dance | Drift |
| `contract.yml` (the API contract suite; deejaytools-com adds an end-to-end job against the dev site) | all but kwalla-dance | Input (kwalla-dance reads no fleet API) |
| `site.yml` smoke test after Pages deploys each push | all five | consistent |
| `security` with `sbom: 'false'` | the four Astro sites; deejaytools-com keeps the default | Drift to settle against the SBOM-retention rule |
| A manual deploy hook (`rebuild.yml`) | kwalla-dance | Drift (a deploy path outside the pipeline, inert today) |

### Single-repository types

- **ecosystem-standards**: inline `test` (catalog validation, the release-type check that catalog changes cut a version, compile, `facts check`); inline `release` that publishes the standards catalog after semantic-release; `evaluate` needs `release` with `scope: fleet`; `contract.yml` runs the publish contract suite. Its `security` job is called with `language: typescript`, `package-manager: npm` for a repository whose code is Python and YAML (Drift, or an input to record in the profile).
- **infra**: no `ci.yml` and no `automerge.yml`. `terraform.yml` (PRs into `main` and pushes to `main`) holds the plan with its consistency checks, the apply, `security`, `evaluate` and `sync-dev`, which fast-forwards `dev` to `main` after an apply. `drift.yml` plans daily (`17 9 * * *`), and `contract.yml` runs the task contract suite. Promotion still runs from `dev` through `promote.yml`.
- **.github**: `ci.yml` runs on every pull request and on push to `main`. Its `test` job calls the local `security.yml` with `self-test: 'true'`, so the job named `test` is a security self-test and the repository has no workflow linting or fixture tests. `release` uses the local `release.yml`.

## Per-repository workflows

Generated from the workflow files at the commits named. "What it runs" lists
a reusable workflow's path, or an inline job's steps by name.

### .github

Read at `main` fe6164b.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch`, `workflow_call` | `agent` | outside the pipeline | inline: Check the inputs and the secrets; actions/checkout@v7; Start Postgres; Install uv; Install the repository's dependencies; actions/setup-node@v7; Install pnpm; Install the repository's dependencies (pnpm); Install the repository's dependencies (npm); hashicorp/setup-terraform@v4; Initialise Terraform without a backend; actions/setup-python@v7; Install PyYAML for the repository's scripts; Install Claude Code; Read CI's test stage inputs; List CI's test stage; Write the prompt; Write the agent's tool rules; Run the agent; Decide how the run ended; Regenerate facts.json; CI's test stage; Repair the change; Regenerate facts.json after the repair; CI's test stage after the repair; Settle the outcome; Mint the agent App's token; Push the branch and open a draft pull request; Report the result |
| `automerge.yml` | `workflow_call` | `automerge` | branch flow | inline: Find the pull request and decide; Require the promote App's credentials; Mint an App token; Merge — if `github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion ` |
| `ci.yml` | `pull_request`, `push` (branches main) | `security` | security | local `security.yml` |
|  |  | `test` | verify | local `security.yml` |
|  |  | `release` | release | local `release.yml` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | local `evaluate.yml` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `commons-update.yml` | `repository_dispatch` (types commons-released), `workflow_dispatch` | `discover` | outside the pipeline | inline: actions/checkout@v7; Check the package; Wait for PyPI to serve the release; Describe the trigger; Require the promote App's credentials; Mint an App token; List repositories whose dev lock uses the package |
|  |  | `bump` | outside the pipeline | inline: actions/checkout@v7; Mint an App token for ${{ matrix.repo }}; actions/checkout@v7; Set up Python; Set up uv; Re-lock ${{ needs.discover.outputs.package }}; Open or refresh the pull request; Close a pull request dev no longer needs — needs discover; if `needs.discover.outputs.repos != '[]'` |
| `dependency-fix.yml` | `schedule` `23 10 * * *`, `workflow_dispatch` | `discover` | outside the pipeline | inline: Require the promote App's credentials; Mint an App token; List repositories with a uv.lock or pnpm-lock.yaml on dev |
|  |  | `fix` | outside the pipeline | inline: actions/checkout@v7; Mint an App token for ${{ matrix.repo }}; actions/checkout@v7; Set up Python; Set up uv; Set up Node; Set up pnpm; Restore osv-scanner; Install osv-scanner; Put osv-scanner on PATH; Re-lock vulnerable dependencies; Open or refresh the pull request; Close a pull request dev no longer needs; Fail on advisories re-locking could not clear — needs discover; if `needs.discover.outputs.repos != '[]'` |
| `evaluate-now.yml` | `workflow_dispatch` | `check-inputs` | evaluate | inline: A repo scope names a repository; echo "Requesting ${{ inputs.scope }}${{ inputs.repo && forma |
|  |  | `evaluate` | evaluate | local `evaluate.yml` — needs check-inputs |
| `evaluate.yml` | `workflow_call` | `evaluate` | evaluate | inline: Wait for the deploy this release triggered; Ask for an evaluation |
| `lambda-deploy.yml` | `workflow_call` | `deploy` | deploy | inline: Resolve the target; actions/checkout@v7; Install uv; Build the zip; Guard 2: glibc; Set up QEMU; Guard 3: start in Lambda's own image; Package; aws-actions/configure-aws-credentials@v6; Deploy; Confirm what is deployed |
| `promote.yml` | `workflow_call` | `promote` | branch flow | inline: Require the promote App's credentials; Mint an App token; actions/checkout@v7; Open or refresh the promotion pull request |
| `python-test.yml` | `workflow_call` | `test` | verify | inline: actions/checkout@v7; Show the workflow version; Test stage |
| `railway-apply.yml` | `workflow_call` | `apply` | deploy | inline: Outside the blocked window; actions/checkout@v7; Set up pnpm; actions/setup-node@v7; Install the Railway CLI and IaC SDK; plan; apply |
| `railway-plan.yml` | `workflow_call` | `plan` | deploy (plan) | inline: actions/checkout@v7; Set up pnpm; actions/setup-node@v7; Install the Railway CLI and IaC SDK; plan; refuse unlabelled destroys; summary — if `github.event_name != 'pull_request' // github.event.pull_request.head.repo.full_name == gi` |
| `release.yml` | `workflow_call`, `workflow_dispatch` | `release` | release | inline: actions/checkout@v7; Release |
| `security.yml` | `workflow_call` | `secret-scan` | security | inline: actions/checkout@v7; Restore gitleaks; Install gitleaks; Put gitleaks on PATH; Scan history for secrets |
|  |  | `dependency-audit` | security | inline: actions/checkout@v7; Set up Python; Set up uv; Audit Python dependencies; Prove the GitHub advisory pass — if `inputs.language == 'python'` |
|  |  | `dependency-audit-node` | security | inline: actions/checkout@v7; Restore osv-scanner; Install osv-scanner; Put osv-scanner on PATH; Audit Node dependencies; Set up Python; Check Node dependencies against GitHub's advisory database — if `inputs.language == 'typescript'` |
|  |  | `static-analysis` | security | inline: actions/checkout@v7; Set up Python; Run semgrep |
|  |  | `sbom` | build | inline: actions/checkout@v7; Restore syft; Install syft; Put syft on PATH; Generate SBOM; Retain SBOM — if `inputs.sbom` |

### api-deejaytools

Read at `dev` 8f7bf36.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Install uv; Set up Python; Verify the lockfile matches pyproject; Install dependencies; Lint; Type check; Baseline matches drizzle; Test; Install pnpm; Set up Node; Install conformance suite; Check out the web app; Check the web app's schemas against this document; Conformance |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `deployed.yml` | `deployment_status`, `workflow_dispatch` | `smoke` | verify (post-deploy) | inline: Smoke-test the deployed API — if `github.event_name == 'workflow_dispatch' // (github.event.deployment_status.state == 'succ` |
|  |  | `contract` | verify (contract) | inline: Mint an App token for deejaytools-com; Run the contract suite against the API — needs smoke; if `(github.event_name == 'workflow_dispatch' &&  inputs.environment == 'development' && input` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `railway-apply.yml` | `push` (branches main; paths .railway/**, .github/workflows/railway-apply.yml), `workflow_dispatch` | `apply` | deploy | shared `railway-apply.yml@v3` — if `github.ref_name == 'main'` |
| `railway-plan.yml` | `pull_request` (branches main; types opened/synchronize/reopened/labeled/unlabeled; paths .railway/**, .github/workflows/railway-plan.yml) | `plan` | deploy (plan) | shared `railway-plan.yml@v3` |

### api-kaianolevine-com

Read at `dev` 316fa2b.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Install uv; Set up Python; Verify the lockfile matches pyproject; Install dependencies; Lint; Type check; Test; Facts are current |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `deployed.yml` | `deployment_status` | `smoke` | verify (post-deploy) | inline: Smoke-test the deployed API — if `github.event.deployment_status.state == 'success' && (endsWith(github.event.deployment.env` |
|  |  | `contract` | verify (contract) | inline: Check whether the consumers were already asked about this commit; Mint an App token for the contract consumers; Run the contract suites against the new API — needs smoke; if `endsWith(github.event.deployment.environment, '/ development')` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `railway-apply.yml` | `push` (branches main; paths .railway/**, .github/workflows/railway-apply.yml), `workflow_dispatch` | `apply` | deploy | shared `railway-apply.yml@v3` — if `github.ref_name == 'main'` |
| `railway-plan.yml` | `pull_request` (branches main; types opened/synchronize/reopened/labeled/unlabeled; paths .railway/**, .github/workflows/railway-plan.yml) | `plan` | deploy (plan) | shared `railway-plan.yml@v3` |

### common-python-utils

Read at `dev` a96267e.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Install uv; Set up Python; Verify the lockfile matches pyproject; Install dependencies; Lint; Format check; Type check; Test |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; Setup Node; Release; Record the release; Mint an App token for mini-app-polis/.github; Ask the fleet to take this release; Say how to finish a release whose dispatch failed — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `pull_request` (branches main), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: Check configuration; actions/checkout@v7; Install uv; Set up Python; Install dependencies; Run the contract suite |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### db-ops

Read at `dev` e908017.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `railway-apply.yml` | `push` (branches main; paths .railway/**, .github/workflows/railway-apply.yml), `workflow_dispatch` | `apply` | deploy | shared `railway-apply.yml@v3` — if `github.ref_name == 'main'` |
| `railway-plan.yml` | `pull_request` (branches main; types opened/synchronize/reopened/labeled/unlabeled; paths .railway/**, .github/workflows/railway-plan.yml) | `plan` | deploy (plan) | shared `railway-plan.yml@v3` |

### deejay-cog

Read at `dev` da5a84d.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `deploy-fingerprint` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `deploy-library` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `deploy-intake` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### deejaytools-com

Read at `dev` 76b72b4.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; pnpm/action-setup@v6; actions/setup-node@v7; pnpm install --frozen-lockfile; pnpm typecheck; pnpm lint; pnpm test:coverage; pnpm build |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: Check configuration; actions/checkout@v7; pnpm/action-setup@v6; actions/setup-node@v7; Wait for the dev API to serve api-deejaytools' dev; pnpm install --frozen-lockfile; pnpm test:contract |
|  |  | `e2e` | verify (e2e) | inline: Resolve the dev site URL; actions/checkout@v7; Wait for Cloudflare Pages to deploy this commit; Read the site's Clerk publishable key; pnpm/action-setup@v6; actions/setup-node@v7; pnpm install --frozen-lockfile; pnpm exec playwright install --with-deps chromium; pnpm test:e2e; actions/upload-artifact@v7 — needs contract; if `${{ !cancelled() }}` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `site.yml` | `push` (branches dev/main) | `smoke` | verify (post-deploy) | inline: actions/checkout@v7; Wait for Cloudflare Pages to deploy this commit; Smoke-test the site |

### ecosystem-standards

Read at `dev` 302b9d5.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Set up Python; Install PyYAML; Validate standards catalog and META rules; Fetch tags for the release-type check; Catalog changes must cut a version; Compile standards catalog; Install uv; Facts are current |
|  |  | `release` | release | inline: actions/checkout@v7; actions/setup-node@v7; Release; Set up Python; Install PyYAML; Publish standards catalog — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs release; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: actions/checkout@v7; Set up Python; Install PyYAML; Run the publish contract suite |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### evaluator-cog

Read at `dev` 16cecf6.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs deploy |
| `llm-sweep.yml` | `schedule` `0 9 * * 0`, `0 10 * * 0`, `workflow_dispatch` | `gate` | evaluate | inline: if [ "$EVENT" != "schedule" ]; then |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs gate; if `needs.gate.outputs.run == 'true'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### identity

Read at `dev` 3656390.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; Lint; Format check; Type check; Conformance suite |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; Setup Node; Release; Record the release; Mint an App token for mini-app-polis/.github; Ask the fleet to take this release; Say how to finish a release whose dispatch failed — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### infra

Read at `dev` b096234.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: actions/checkout@v7; Set up Python; Run the task contract suite |
| `drift.yml` | `schedule` `17 9 * * *`, `workflow_dispatch` | `plan` | deploy (plan) | inline: actions/checkout@v7; hashicorp/setup-terraform@v4; aws-actions/configure-aws-credentials@v6; fetch fpcalc; init; GitHub token (read); plan; summary — if `github.ref == 'refs/heads/main'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `terraform.yml` | `pull_request` (branches main; types opened/synchronize/reopened/labeled/unlabeled), `push` (branches main), `workflow_dispatch` | `plan` | deploy (plan) | inline: actions/checkout@v7; check out api-kaianolevine-com's dispatch claims and metrics routes; claim window matches the API's CLAIM_WINDOW; check out watcher-cog's watchers; scheduled watchers are ones watcher-cog publishes; check out api-deejaytools' metrics routes; dashboard routes are ones their APIs publish; check out rotator-cog's secrets inventory; the rotator's IAM users are the ones its inventory rotates; hashicorp/setup-terraform@v4; aws-actions/configure-aws-credentials@v6; fmt; fetch fpcalc; init; validate; GitHub token (read); plan; refuse unlabelled destroys; summary |
|  |  | `apply` | deploy | inline: actions/checkout@v7; hashicorp/setup-terraform@v4; aws-actions/configure-aws-credentials@v6; fetch fpcalc; init; GitHub token (write); apply; file confirmation tasks for new alert subscriptions — needs plan; if `(github.event_name == 'push' // github.event_name == 'workflow_dispatch') && github.ref ==` |
|  |  | `security` | security | shared `security.yml@v3` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs plan, apply; if `always() && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.plan.r` |
|  |  | `sync-dev` | branch flow | inline: actions/checkout@v7; fast-forward dev to main — if `github.event_name == 'push' && github.ref == 'refs/heads/main'` |

### kwalla-dance

Read at `dev` 856d4a8.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Setup Node; Install dependencies; Build |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `rebuild.yml` | `workflow_dispatch` | `trigger` | deploy | inline: Trigger Cloudflare Pages deploy |
| `site.yml` | `push` (branches dev/main) | `smoke` | verify (post-deploy) | inline: Wait for Cloudflare Pages to deploy this commit; Smoke-test the site |

### rotator-cog

Read at `dev` 09f8aeb.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; actions/setup-node@v7; Release; Record the release tag — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### task-manager-cog

Read at `dev` c36a5f7.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; actions/setup-node@v7; Release; Record the release tag — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `sweep-now.yml` | `workflow_dispatch` | `sweep` | outside the pipeline | inline: Ask for a sweep |

### task-refiner-cog

Read at `dev` 73fc0a4.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; actions/setup-node@v7; Release; Record the release tag — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### transcription-cog

Read at `dev` a5f00e1.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### watcher-cog

Read at `dev` 3031f5c.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; astral-sh/setup-uv@v7; Verify the lockfile matches pyproject; uv sync; uv run ruff check src tests; uv run ruff format --check src tests; uv run mypy src/; uv run pytest --cov=watcher_cog --cov-report=term-missing |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `deploy.yml` | `workflow_dispatch` | `deploy` | deploy | shared `lambda-deploy.yml@v3` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |

### website-astro-software

Read at `dev` b41dd40.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Setup Node; Install dependencies; Type check; Build |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: actions/checkout@v7; actions/setup-node@v7; npm run test:contract |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `site.yml` | `push` (branches dev/main) | `smoke` | verify (post-deploy) | inline: Wait for Cloudflare Pages to deploy this commit; Smoke-test the site |

### website-astro-wcs

Read at `dev` d42b5dc.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Setup Node; Install dependencies; Type check; Build |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: actions/checkout@v7; actions/setup-node@v7; npm run test:contract |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `site.yml` | `push` (branches dev/main) | `smoke` | verify (post-deploy) | inline: Wait for Cloudflare Pages to deploy this commit; Smoke-test the site |

### website-astro-wcsmn

Read at `dev` 14c68b9.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` (branches main/dev) | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | inline: actions/checkout@v7; Setup Node; Install dependencies; Type check; Build |
|  |  | `release` | release | shared `release.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `contract.yml` | `push` (branches dev), `repository_dispatch` (types dev-api-deployed), `workflow_dispatch` | `contract` | verify (contract) | inline: actions/checkout@v7; actions/setup-node@v7; npm run test:contract |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
| `site.yml` | `push` (branches dev/main) | `smoke` | verify (post-deploy) | inline: Wait for Cloudflare Pages to deploy this commit; Smoke-test the site |

### wiki-curator-cog

Read at `dev` 0ebb625.

| Workflow | Triggers | Job | Stage | What it runs |
|---|---|---|---|---|
| `agent.yml` | `workflow_dispatch` | `agent` | outside the pipeline | shared `agent.yml@v3` |
| `automerge.yml` | `workflow_run` (types completed; after CI) | `automerge` | branch flow | shared `automerge.yml@v3` |
| `ci.yml` | `push` (branches main/dev), `pull_request` | `security` | security | shared `security.yml@v3` |
|  |  | `test` | verify | shared `python-test.yml@v3` |
|  |  | `release` | release | inline: actions/checkout@v7; Install uv; Set up Python; Install dependencies; actions/setup-node@v7; Release; Record the release tag — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
|  |  | `deploy` | deploy | shared `lambda-deploy.yml@v3` — needs release; if `needs.release.outputs.tag != ''` |
|  |  | `rebuild` | deploy | inline: Rebuild every page — needs deploy |
|  |  | `evaluate` | evaluate | shared `evaluate.yml@v3` — needs test, security; if `github.ref == 'refs/heads/main' && github.event_name == 'push'` |
| `promote.yml` | `push` (branches dev) | `promote` | branch flow | shared `promote.yml@v3` |
