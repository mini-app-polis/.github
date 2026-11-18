# .github

Org-wide GitHub configuration for **mini-app-polis**. Reusable
workflows, one per stage of a repo's `ci.yml` (ecosystem-standards CD-026):

| Stage | Workflow |
|---|---|
| `security` | `security.yml` — the fleet's shared security controls |
| `test` | `python-test.yml` — lock check, lint, format and tests for a uv repo |
| `lint`, `unit`, `integration`, `contract`, `security`, gated by `test` | `stages-test.yml` — the canonical pipeline's stages before `build`, for any profile (see Test stages) |
| `build` | `stages-build.yml` — the commit's one artifact and its SBOM, for any profile (see Build stage) |
| `release` | `release.yml` — semantic-release from the fleet's locked tooling |
| `deploy` | `stages-deploy.yml` — put the build's artifact on the profile's target, unless it already runs that version (see Deploy stage); `lambda-deploy.yml` is its Lambda path, and still callable on its own |
| `verify` | `stages-verify.yml` — ask the target, read-only, whether it runs the release (see Verify stage) |
| `evaluate-pre`, `evaluate-post` | `stages-evaluate.yml` — a deterministic conformance evaluation of the commit before release, which gates it, and of the published release after `verify`, which reports (see Evaluation stages) |
| `evaluate` | `evaluate.yml` — ask for the repository to be evaluated, without waiting: today's callers, and fleet passes |

Two more sit outside the pipeline: `promote.yml` keeps a `dev` → `main`
pull request open whenever `dev` has something to release, and
`automerge.yml` merges a pull request into `dev` once all its checks pass.
`agent.yml` implements one board task in a repository and opens a draft
pull request into `dev` for a person to review.
`railway-plan.yml` and `railway-apply.yml` plan a repository's Railway
Infrastructure as Code on a pull request and plan again and apply on merge,
as infra does for Terraform.

One is not called by any repository: `required.yml` is the organization
ruleset's required workflow, the security controls a repository on the
pipeline cannot skip (see Enforced and subscribed).

Two run from here over the whole fleet and open pull requests into other
repositories' `dev`: `dependency-fix.yml` re-locks packages the dependency
audit flags, and `commons-update.yml` re-locks a consumer onto a new
release of the fleet's own libraries the day it is published.

`evaluate-now.yml` is run by hand from the Actions tab: a fleet pass, one
repository, or an LLM pass, for changes that do not cut a release and for
re-grading everything at once. It calls `evaluate.yml`, so it sends the same
request a release would.

## The canonical pipeline

One pipeline builds, tests, releases, deploys and evaluates every
mini-app-polis repository. A repository subscribes to it with a thin
caller and a profile; it does not copy stages. ecosystem-standards
ADR-0017 records why it runs on GitHub Actions from this repository.

The pipeline's settings that change over time (its current major, the
canary repository, the soak period and the repositories already moved
onto it) live in `pipeline.yaml` at the root of this repository. Conformance rules and the
release reconciler read them from there; nothing else restates them.

### One commit, one run

A commit's whole build is one workflow run. The pipeline is a single
reusable workflow, `pipeline.yml`, and every stage below is a job of it,
so the run's graph shows every stage of that commit with its result.
Nothing a commit needs runs as a separate workflow chained to it: no
`deployment_status`, `workflow_run` or `repository_dispatch` workflow
carries a stage, and no platform builds or deploys from a branch on its
own.

A repository's caller is its `ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main, dev]
  pull_request:
    branches: [main, dev]
  merge_group:
  workflow_dispatch:
    inputs:
      ref:
        description: Release tag to finish (set by the release reconciler)
        type: string
        required: false
jobs:
  pipeline:
    uses: mini-app-polis/.github/.github/workflows/pipeline.yml@v4 # the current major in pipeline.yaml
    with:
      profile: python-service
    secrets: inherit
```

Branch flow stays outside the run, as today: `promote.yml` keeps a
`dev` → `main` pull request open, `automerge.yml` merges a pull request
into `dev` once its checks pass, and releases to `main` are made by
merging the promotion pull request by hand. `agent.yml` and the fleet
jobs (`commons-update.yml`, `dependency-fix.yml`) are not builds and stay
separate workflows.

### Stage graph

| Stage | Job | Runs on | Needs | Gates |
|---|---|---|---|---|
| Lint and type check | `lint` | every event | — | `build` |
| Unit tests | `unit` | every event | — | `build` |
| Integration tests | `integration` | every event | — | `build` |
| Contract tests | `contract` | every event | — | `build` |
| Security | `security` | every event | — | `build` |
| Test gate | `test` | every event | `lint`, `unit`, `integration`, `contract`, `security` | `build` |
| Build | `build` | every event | `test` | everything after it |
| Pre-release evaluation | `evaluate-pre` | push to `main` | `build` | `release` |
| Release | `release` | push to `main`, and `workflow_dispatch` with `ref` | `evaluate-pre` | `deploy` on `main` |
| Deploy | `deploy` | push to `dev` (development), push to `main` when `release` published (production) | `build`, and `release` on `main` | `verify` |
| Post-deploy verify | `verify` | wherever `deploy` ran | `deploy` | `evaluate-post` |
| Post-release evaluation | `evaluate-post` | push to `main` when `release` published | `verify`, `release` | — |

Each type of test is its own stage, so a failure names the kind of test
that failed. A stage a profile has no use for still appears in the run
and is skipped with its reason in the job summary, never removed. The
required status check is the `test` job, a gate over `lint`, `unit`,
`integration`, `contract` and `security`; its name does not change when
stages are added. Those six jobs are one reusable workflow,
`stages-test.yml`, which `pipeline.yml` calls as one job (see Test stages).

On `dev`, a commit is built, tested, deployed to development and verified
there. On `main`, a commit is built and tested again, evaluated before
release, released, deployed to production behind the `production`
environment, verified and evaluated after release. A pull request runs the
stages up to `build` and deploys nothing.

Release data reaches every later stage through job outputs in the same
run: `evaluate-post` evaluates the version and commit `release` produced,
never a branch name and never a guess at when a deploy finished.

### Stage contracts

Every stage declares its inputs, outputs and artifacts, and the check that
makes running it twice on the same commit safe. Running any stage twice
produces no second release or deploy. An evaluation stage asks again, and
decides on the evaluation it asked for (see Evaluation stages).

| Stage | Inputs | Outputs and artifacts | Safe to re-run because |
|---|---|---|---|
| `lint`, `unit`, `integration`, `contract` | the commit; the profile's commands; for `integration`, the Postgres service container the caller names; for `contract`, the contract suite the caller names, at the release its lock holds, and the development API | what ran and its result in the job summary, or why the stage had nothing to run | `lint`, `unit` and `integration` change nothing outside the run; `contract` writes only fixed rows the development API upserts, so a second run converges on the first |
| `test` | the results of `lint`, `unit`, `integration`, `contract` and `security` | a table of them in the job summary | it only reads them |
| `security` | the commit; the profile's language and package manager | findings in the job summary | it changes nothing outside the run |
| `build` | the commit; the profile's build | `artifact-name`, `artifact-digest`; the artifact (wheel, Lambda zip, container image or site bundle) and its SBOM, kept with the run | an artifact for this commit already in the run is reused, not rebuilt: it is checked against its seal and reported with the same digest |
| `evaluate-pre` | `repo`, `sha`, `phase: pre-release` | `result` (`pass`, `blocked`, `timeout`, `unsupported` or `not-requested`); the evaluation's ids, `message-id` (the request) and `run-id` (the run its findings are filed under); the findings in the job summary | it only asks for an evaluation and reads it: a re-run asks again and decides on the newest evaluation of (repo, sha, phase) that started after its own request. The API does not yet answer a repeated request with the evaluation it already has, so a re-run costs a second evaluation, filed under its own run |
| `release` | the commit, or `ref` from the reconciler | `published` (true or false), `version`, `tag`, `sha` | a tag already on this commit, or a release commit pushed on top of it, is this commit's release: the stage does not run semantic-release, finishes what is missing (the tag, the GitHub release, the major tag) and reports `published`, so the package publish and the fleet notice that run on it finish too, rather than cutting another. It cuts a release on `main` only |
| `deploy` | `artifact-name`, `artifact-digest`, `environment` (`development` or `production`), `version` | `deployed-version`, `deployed` | it reads what the target runs first and skips when that is already this version; a failed deploy re-runs on its own and takes the same artifact by digest |
| `verify` | `environment`, `version` (deploy's `deployed-version`), `build-version`, `sha` (release's `sha` in production), the profile's check | `verified` (`true`, `false`, or `skipped` when the profile has nothing to verify); a commit status, `pipeline/verify (<environment>)`, on `sha` | it only reads the target, and its record is a commit status, of which the newest of a context is the one that counts |
| `evaluate-post` | `repo`, `version`, `sha` and `published` from `release`'s outputs, `phase: post-release` | `result` (`requested`, `not-requested`, or `skipped` when nothing was published); `message-id` | it only asks: a re-run asks again, and the second evaluation of (repo, sha, phase) is filed under its own run, which Pipeline Health shows in place of the first |

Every later stage consumes the artifact `build` produced, by digest,
through the `fetch-artifact` action (see Build stage). No stage rebuilds it.

Every job declares `timeout-minutes`. Network calls (registry pulls,
package publish, deploys, API calls) retry with backoff. `release` and
`deploy` run in per-repository concurrency groups that never cancel a run
in progress; only the stages before `build` cancel superseded runs, and
only off `main`. `contract` is the exception among them when it runs a
suite: it writes to the development API, so it waits in the one group
every such run in the repository shares and is never cancelled partway. `workflow-checks.yml` fails a change to this repository
that adds a job without `timeout-minutes`.

### Profiles

A profile is a set of inputs: which stages have work, with what tools,
producing what artifact, deployed where, verified how. A repository names
its profile in its caller; `pipeline.yml` holds each profile's defaults,
and the repository's inputs override them.

| Profile | Tooling | Integration and contract | Artifact | Deploy | Verify |
|---|---|---|---|---|---|
| `python-service` | uv, ruff, mypy, pytest | Postgres service container where the repository's tests need it; contract suites it consumes | wheel and sdist, with the Lambda zip when it names a handler | AWS Lambda functions, or Railway services | the function is active, its last update succeeded, and its code is the release's zip |
| `api-service` | uv, ruff, mypy, pytest | Postgres service container; the contract suites it provides and consumes | container image | Railway | the deploy record holds the release's image, `/health` answers, and `/version` reports the release or the version its build declares |
| `python-library` | uv, ruff, mypy, pytest | contract suites against the development API where it ships them | wheel and sdist | published to PyPI by `release`, which also tells the fleet a release is out | the published version resolves on PyPI |
| `astro-site` | Node with npm or pnpm, typecheck, build | the API contract suites the site consumes; end-to-end tests where it has them | site bundle | Cloudflare Pages, uploaded from the pipeline | the site answers, and the upload Pages serves is the release's version and artifact |
| `npm-library` | Node with npm or pnpm, typecheck, lint, tests | contract suites where it ships them | npm package | published to the registry by `release` | the published version resolves |
| `terraform-infra` | Terraform fmt and validate, the repository's consistency checks | the task contract suite | the reviewed plan, made where credentials are (`build` skips and says so) | `terraform apply` of that plan | a fresh plan shows no changes (not yet: `verify` skips and says so) |
| `shared-workflows` | workflow static analysis, the pipeline's fixture repositories | — | — | the release moves the major tag | the fixtures passed before the release (`verify` skips and says so) |

`shared-workflows` is this repository. It works like the rest of the
fleet: changes land on `dev`, where every push runs the self-tests, and
reach `main` through the promotion pull request; a merge to `main`
releases.

### Extension points

A repository may add work only at these points, as inputs or as jobs in
its caller that need the `pipeline` job:

- **Extra checks** in `lint`, `unit` or `integration`, as commands the
  profile runs in that stage (a schema check, `facts check`).
- **Service containers and contract suites** for `integration` and
  `contract`.
- **Build and deploy targets**: the handler, architecture, function or
  service names the profile deploys, read from the repository's inputs.
- **Post-deploy work**: a caller job after `pipeline` for a step that
  belongs after the new code is live (rebuilding generated pages). It runs
  in the same run, so the one view holds.
- **Scheduled runs**: a caller may add a `schedule` trigger for work the
  pipeline already defines (a scheduled evaluation), not new stages.

Anything else is drift, and the conformance rules report it.

### Test stages

`stages-test.yml` holds the stages before `build`: `lint`, `unit`,
`integration`, `contract` and `security`, each a job of its own, and
`test`, the gate over them. A `profile` job first resolves the profile
into the tooling each stage runs, and fails on a profile it does not know.

| Stage | Python profiles | Node profiles | `terraform-infra` | `shared-workflows` |
|---|---|---|---|---|
| `lint` | the `python-checks` action's lint checks: `uv lock --check`, `uv sync --locked`, `ruff check`, `ruff format --check`, the type check, Terraform fmt and validate of `terraform-dir` when set, and `facts check` when there is a `facts.yaml` | install from the lockfile (npm or pnpm), then the `typecheck` and `lint` scripts, each where `package.json` has it | `terraform fmt -check`, `init -backend=false` and `validate` | skipped: its lint is workflow static analysis, which the repository's own self-test runs |
| `unit` | pytest, leaving out the `integration-tests` directory | the `unit-script` script; skipped when `package.json` has none | skipped | skipped |
| `integration` | pytest on the `integration-tests` directory, with the Postgres service container when one is named; skipped when the directory does not exist | the `integration-script` script; skipped when `package.json` has none | skipped | skipped |
| `contract` | the named contract suite against the development API; skipped when none is named | the same | the same | the same |
| `security` | `security.yml`, Python with uv | `security.yml`, TypeScript | `security.yml`, Python with pip, which finds no dependencies and says so; the secret scan and static analysis still run | the same as `terraform-infra` |

A skipped stage still runs: it writes why in its job summary and as a
notice on the run, and passes. A stage that ran writes its result and the
commands it ran to its summary, and `test` writes a table of every stage's
result to its own.

#### Inputs

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The repository's profile, from the Profiles table |
| `working-directory` | `.` | The directory, within the checkout, holding the repository. For this repository's fixtures; consumers leave it |
| `timeout-minutes` | `30` | How long each stage's job may run |
| `python-version` | `3.14` | Python profiles: the runtime the repository deploys to |
| `typecheck` | `uv run mypy src/` | Python profiles: the type check `lint` runs (TEST-012) |
| `unit-pytest-args` | `--cov=src --cov-report=term-missing` | Python profiles: appended to the `unit` pytest |
| `integration-tests` | `tests/integration` | Python profiles: the integration tests' directory |
| `integration-pytest-args` | empty | Python profiles: appended to the `integration` pytest |
| `postgres-image` | empty | The `integration` stage's Postgres service container, by exact tag or digest (the fleet's APIs use `pgvector/pgvector:pg16`). Empty starts none; an image with no tag, or `:latest`, fails the stage |
| `postgres-database` | `pipeline_test` | The container's database. It must end in `_test` |
| `terraform-dir` | empty | A Python repository's Terraform directory, checked in `lint`; for `terraform-infra`, the directory to check (empty: the repository) |
| `terraform-version` | `1.16.2` | Match what applies it from the workstation, so fmt agrees |
| `node-version` | `22` | Node profiles: the Node release line |
| `unit-script` | `test` | Node profiles: the script `unit` runs |
| `integration-script` | `test:integration` | Node profiles: the script `integration` runs |
| `contract-suite` | empty | `common-python-utils` for the fleet's shared contract suite; empty for none |
| `contract-suite-version` | empty | The common-python-utils release whose suite runs. Empty: the one the repository's `uv.lock` holds. A repository with no such entry (a Node repository) sets it |
| `contract-api-url` | `https://dev-api.kaianolevine.com` | The development API. A production host is refused |
| `sbom` | `true` | Have `security` generate and retain a CycloneDX SBOM |

| Secret | Meaning |
|---|---|
| `CONTRACT_SUITE_API_KEY` | The development API's contract-suite key (`dev_...`). Needed only when `contract-suite` is set; without it the stage fails rather than passing unrun |

#### Integration databases

With `postgres-image` set, `integration` starts that image as a service
container and exports its address as both `TEST_DATABASE_URL` and
`DATABASE_URL`:
`postgresql://postgres:postgres@localhost:5432/<postgres-database>`. Those
are the names the fleet's integration suites read, and the address passes
their guards (local, database named `*_test`). An API whose suite defaults
to its own database name passes that name as `postgres-database`
(`kaianolevine_test`, `deejaytools_test`).

#### The contract suite

`contract-suite: common-python-utils` runs `contract/` from
common-python-utils: every endpoint in the fleet's catalog, called through
the typed client the cogs use, against the development API. The suite is
not part of the library's wheel, but its sdist on PyPI ships it with the
suite's own `uv.lock`, so the stage fetches the sdist of the release the
repository's `uv.lock` holds, checks it against the hash that lock records,
and runs `uv run pytest contract`. The suite is then the one written for
the client this repository runs.

It writes fixed rows to the development API, so it runs only with a
development key, refuses a production host before anything is fetched (and
the suite's own guards refuse one again), and waits in one concurrency
group, `contract-dev-kaiano-api`, which no run cancels partway.

#### uv

Every stage installs the uv release `uv_version` in `pipeline.yaml`
names, and nothing else states it. The `setup-uv` action and the
`python-checks` action (and so `python-test.yml`) read it through
`.github/actions/setup-uv/uv-version.sh`. A repository's
`[tool.uv] required-version` is a range that must hold that release; one
that does not fails at its first uv command, which is the signal to move
one or the other.

#### How pipeline.yml composes them

`pipeline.yml` does not exist yet. When it does, it calls this workflow as
one job, with `$/` so a caller pinned to a tag runs the stages from that
same tag, and `build` (see Build stage) needs it:

```yaml
jobs:
  stages:
    uses: $/.github/workflows/stages-test.yml
    with:
      profile: ${{ inputs.profile }}
      # The profile's defaults, which the repository's inputs override:
      # for api-service, postgres-image: pgvector/pgvector:pg16.
    secrets:
      CONTRACT_SUITE_API_KEY: ${{ secrets.CONTRACT_SUITE_API_KEY }}
  build:
    needs: stages
    uses: $/.github/workflows/stages-build.yml
    with:
      profile: ${{ inputs.profile }}
```

In a repository's run the gate then reports as `pipeline / stages / test`,
the name its ruleset requires. Until then a repository may call
`stages-test.yml` directly, as in the comment at the top of that file.

### Build stage

`stages-build.yml` is the `build` stage: one job, `build`, that makes the
commit's one artifact, seals it with a digest, generates its SBOM and keeps
both with the run. Every stage after it takes the artifact by name and
digest instead of building again, so what is released and deployed is the
thing that was built and tested.

| Profile | Artifact (directory in it) |
|---|---|
| `python-library` | `uv build`: the wheel and sdist (`dist/`) |
| `python-service` | the wheel and sdist (`dist/`), and with `lambda-handler` set, the Lambda zip and `target.json`, what it was built for (`lambda/`) |
| `api-service` | the container image from the `Dockerfile`, saved as a docker-archive tarball with its image ID (`image/`). It is never pushed; a deploy pushes what it takes |
| `astro-site` | the site the `build` script writes to `dist`, as one tarball (`site/`) |
| `npm-library` | `npm pack` (or `pnpm pack`), after the `build` script where there is one (`package/`) |
| `terraform-infra` | none: skipped and says why. The artifact is the reviewed plan, and a plan needs the state backend and the providers' credentials, which the build stage does not hold |
| `shared-workflows` | none: skipped and says why. The release moves the major tag |

The Lambda zip is made by the `lambda-zip` action, which `lambda-deploy.yml`
also runs when it is not given an artifact, so the zip and its three guards
(see Shared Lambda deploy) are one piece of code wherever it is built.

**Version.** The build's version is the one the commit declares, in
`pyproject.toml` or `package.json`, with `+g` and the commit's first 12 hex
digits: `1.4.0+g0123456789ab`. It says what the build is, the commit that
declares 1.4.0, and it orders after that release and before the next. It
labels the artifact; the files are built exactly as the commit has them.
semantic-release's next version is not used: it is known only to a release
run, on `main`, with the tag history and a token, and `build` runs on every
event, pull requests included.

**Digest.** The artifact's directory is sealed with `SHA256SUMS`, the
SHA-256 of every file in it by path, and `artifact-digest` is
`sha256:` and the SHA-256 of that manifest. One digest covers an artifact of
several files as well as one of a single file, and a changed, missing or
added file changes it. The `artifact-digest` action seals and checks; the
work is its `artifact-digest.sh`, which `scripts/test-artifact-digest.sh`
proves against each way an artifact can be wrong.

**Reuse.** Before building, the stage looks in the run for an artifact of
this name, which holds the commit's sha. One that is there (a re-run, or a
second call) is downloaded, checked against its seal and reported with the
same digest, and nothing is rebuilt. An SBOM missing from an earlier attempt
is made again from the artifact's bytes.

**SBOM.** syft, at the release `security.yml` pins, describes the artifact
itself: the image's layers, or the archives unpacked (the Lambda zip holds
every dependency's metadata). It is uploaded as `<artifact-name>-sbom` from
the same job as the build, and kept for every build as ecosystem-standards
SEC-005 asks, with the retention `security.yml` gives its own SBOM.

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The repository's profile |
| `working-directory` | `.` | As for `stages-test.yml` |
| `timeout-minutes` | `30` | How long the build job may run |
| `python-version` | `3.14` | Python profiles: the runtime the repository deploys to |
| `node-version` | `22` | Node profiles: the Node release line |
| `build-script` | `build` | `astro-site`: the script that builds the site. `npm-library`: run before packing when `package.json` has it |
| `site-dir` | `dist` | `astro-site`: where the build script writes the site |
| `dockerfile` | `Dockerfile` | `api-service`: the image's Dockerfile |
| `lambda-handler` | empty | `python-service`: `module.function`, as `handler` in `infra/worker.tf`. Empty, no Lambda zip |
| `lambda-architecture` | `x86_64` | `python-service`: as `architectures` in `infra/worker.tf` |
| `lambda-trigger` | `sqs` | `python-service`: `sqs` or `schedule`, what invokes the function |
| `lambda-strip` | empty | `python-service`: top-level paths left out of the zip |
| `syft-version` | `1.29.1` | The SBOM's syft, as `security.yml` pins it |

| Output | Meaning |
|---|---|
| `artifact-name` | The artifact's name in the run; empty when the profile builds nothing |
| `artifact-digest` | `sha256:<hex>` of its `SHA256SUMS` |
| `sbom-name` | The SBOM artifact's name |
| `version` | The build's version, above |
| `reused` | `true` when the artifact was taken from earlier in the run |

#### Taking the artifact

A stage after `build` takes the artifact with the `fetch-artifact` action,
which downloads it from the run by name and fails unless its digest is the
one `build` reported:

```yaml
      - uses: $/.github/actions/fetch-artifact
        id: artifact
        with:
          name: ${{ needs.build.outputs.artifact-name }}
          digest: ${{ needs.build.outputs.artifact-digest }}
      # the verified artifact is in ${{ steps.artifact.outputs.path }}
```

`release.yml` and `lambda-deploy.yml` take `artifact-name` and
`artifact-digest` inputs and do this themselves. Without them they behave
as they always have. `release.yml` points `PIPELINE_ARTIFACT_DIR` at the
artifact for semantic-release, so a repository's publish step can ship it.
`lambda-deploy.yml` deploys the artifact's `lambda/worker.zip` instead of
building one, and refuses it unless `target.json` names the handler,
architecture, Python and trigger the deploy is for.

### Deploy stage

`stages-deploy.yml` is the `deploy` stage: it takes the build's artifact by
digest and puts it on the profile's target. Once a repository is on the
pipeline its platform's branch auto-deploy is off (see Moving a
repository's deploys onto the pipeline, below), and this stage is the only
thing that changes what runs.

| Profile | Target | How |
|---|---|---|
| `python-service` with `lambda-handler` | AWS Lambda | `lambda-deploy.yml` with the artifact's `lambda/worker.zip` (see Shared Lambda deploy) |
| `api-service` | Railway | the artifact's image pushed to GHCR, and a new deployment of the Railway service that pulls it |
| `astro-site` | Cloudflare Pages | `wrangler pages deploy` of the site bundle |
| `python-library`, `npm-library` | none: skipped and says why | `release` publishes them |
| `terraform-infra` | none yet: skipped and says why | its deploy is the apply of the reviewed plan, which needs the state backend and credentials; the repository's own Terraform workflow applies until the plan is a pipeline artifact |
| `shared-workflows` | none: skipped and says why | the release moves the major tag |
| `python-service` without `lambda-handler` | none yet: skipped and says why | a Railway worker would deploy an image, and this profile's artifact holds none |

**Environments.** `development` deploys from `dev` and takes any version,
usually the build's (`1.4.0+g0123456789ab`). `production` deploys from
`main`, takes only a release's `X.Y.Z`, and runs in the GitHub Environment
named `production`, so that environment's protection rules and secrets
apply. `pipeline.yml` runs it on `main` only when `release` reports
`published`. The stage refuses any other pairing (production from `dev`, a
build version in production, development from a pull request) before it
fetches anything.

**Skip when already deployed.** Before deploying, the stage reads what the
target runs and skips when that is already this version, with the reason in
the job summary and as a notice. The decision is `deploy-decision.sh`, in
the `deploy-decision` action, which `scripts/test-deploy-decision.sh` proves
case by case: the same version is skipped (even from another build of it,
which it says), a target that records no version is compared by the
artifact's identity, and anything else deploys. What each target reports:

| Target | What it runs | Read from |
|---|---|---|
| Lambda | the zip, by its CodeSha256 | `aws lambda get-function`. The deploy role can read it but cannot tag the function, so the function records no version |
| Railway | the image, by its config digest | the GHCR tag `<environment>-deployed`, which the stage moves only after Railway reports the new deployment healthy |
| Cloudflare Pages | the version and the artifact's digest | the deployment's commit message, `pipeline-deploy version=<version> artifact=<digest>`: the production deployment the project serves, or the newest successful deployment of the development branch |

**Re-run on its own.** A failed deploy job is re-run with "Re-run failed
jobs": it fetches the same artifact from the run by digest and rebuilds
nothing, and because it reads the target first, a deploy that landed before
the failure is not done twice.

**Railway.** A Railway service on the pipeline runs an image, not a branch:
its `.railway/railway.ts` declares the source as
`image("ghcr.io/<owner>/<repo>:<environment>")`. The stage pushes the
artifact's image to GHCR under its version (`1.4.0`, or `1.4.0_g0123456789ab`
in development, since a tag cannot hold `+`) and checks the pushed config
digest is the artifact's; moves the `<environment>` tag to it; asks Railway's
public API, with the environment's project token, for a new deployment of
the service; waits until Railway reports it `SUCCESS`; and only then moves
`<environment>-deployed`, the record the next run reads. Why this path:

- `railway up` uploads source for Railway to build, so what ran would not
  be what was built and tested.
- Pointing the service at a new image reference on each deploy would fight
  the IaC: `railway-apply.yml` puts back the source `railway.ts` names on
  its next apply. With one fixed tag per environment, the IaC says where
  the service's image comes from and the pipeline says what that image is.

**Cloudflare Pages.** The stage uploads the site bundle with the wrangler
locked in `.github/actions/wrangler` (an exact version and its
`package-lock.json`, moved by Dependabot), as the project's production
branch (`main`) in production and as `dev` in development. A `dev` upload
serves at `dev.<project>.pages.dev`, where infra points the sites' `dev.`
domains. The upload carries the commit and the message above.

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The repository's profile |
| `environment` | required | `development` or `production` |
| `version` | required | `release`'s `version` in production; `build`'s `version` in development |
| `artifact-name`, `artifact-digest` | empty | The build stage's outputs. Needed by every profile that deploys |
| `target` | `live` | `fake` is the self-test's stand-in: it records in the run and deploys nowhere. Consumers leave it |
| `timeout-minutes` | `30` | How long the deploy job may run |
| `lambda-handler`, `lambda-architecture`, `lambda-trigger`, `python-version`, `lambda-strip` | as `stages-build.yml` | `python-service`: what the zip was built for; `lambda-deploy.yml` refuses an artifact built for anything else |
| `aws-role-arn`, `aws-region`, `lambda-function-name` | empty | `python-service`: the function for this environment, from the cog's `terraform output` |
| `railway-service` | empty | `api-service`: the service's name in the project the token is scoped to |
| `image-repository` | `ghcr.io/<owner>/<repo>` | `api-service`: where the image is pushed and the service pulls from; on `ghcr.io` |
| `railway-deploy-minutes` | `15` | `api-service`: how long to wait for Railway to report the deployment healthy |
| `pages-project`, `cloudflare-account-id` | empty | `astro-site`: the Pages project and its account |
| `pages-production-branch`, `pages-development-branch` | `main`, `dev` | `astro-site`: the branch each environment uploads as |
| `node-version` | `22` | `astro-site`: the Node wrangler runs on |

| Secret | Meaning |
|---|---|
| `railway-token` | `api-service`: a Railway project token scoped to this environment (`RAILWAY_TOKEN` for production, `RAILWAY_TOKEN_DEVELOPMENT` for development), never an account or workspace token |
| `cloudflare-api-token` | `astro-site`: a token with Cloudflare Pages: Edit on the account |

| Output | Meaning |
|---|---|
| `deployed-version` | The version the target runs after the stage, deployed now or already there; empty when the profile deploys nothing |
| `deployed` | `true` when this run changed the target |

The calling job grants `contents: read`, `id-token: write` (the Lambda
deploy's OIDC role) and `packages: write` (the GHCR push) whatever its
profile: GitHub checks a reusable workflow's permissions before any job's
`if`. In `pipeline.yml`:

```yaml
  deploy:
    needs: [build, release]
    if: >-
      always() && needs.build.result == 'success' &&
      ((github.ref == 'refs/heads/dev' && github.event_name == 'push') ||
       (github.ref == 'refs/heads/main' && needs.release.outputs.published == 'true'))
    permissions:
      contents: read
      id-token: write
      packages: write
    uses: $/.github/workflows/stages-deploy.yml
    with:
      profile: ${{ inputs.profile }}
      environment: ${{ github.ref == 'refs/heads/main' && 'production' || 'development' }}
      version: ${{ github.ref == 'refs/heads/main' && needs.release.outputs.version || needs.build.outputs.version }}
      artifact-name: ${{ needs.build.outputs.artifact-name }}
      artifact-digest: ${{ needs.build.outputs.artifact-digest }}
      # and the repository's target inputs
    secrets:
      railway-token: ${{ github.ref == 'refs/heads/main' && secrets.RAILWAY_TOKEN || secrets.RAILWAY_TOKEN_DEVELOPMENT }}
      cloudflare-api-token: ${{ secrets.CLOUDFLARE_PAGES_API_TOKEN }}
```

**What a running service reports.** On `main` the artifact is built from
the commit `release` versions, before the release commit that writes the
new version into the version files, so a service built from it reports the
version that commit declared, not the release. That is why the skip check
reads the target's own record of the artifact (its image, its zip, its
upload) rather than the service's version endpoint, and why `verify` reads
that record too (see Verify stage).

### Verify stage

`stages-verify.yml` is the `verify` stage: after `deploy`, it asks the
target, and only reads it, whether it runs this release. It asks again with
backoff until the answer is yes or the time is up. A timeout fails the job,
posts to the Discord errors channel and records the release as not
verified.

**What "verified" means.** A service built on `main` reports the version
its commit declared, which is the version before this release (see Deploy
stage, "What a running service reports"). On `dev`, every build of a commit
reports the same declared version, and a service that pulls an image has no
Git commit to report. So the stage does not take a service's word for the
release alone. For each target it reads the deploy record, which ties the
release to the exact artifact, and then asks the running target itself:

| Target | Verified when | What it rules out |
|---|---|---|
| Railway (`api-service`) | the GHCR deploy record `<environment>-deployed` holds the image pushed for this version (the deploy stage moves it only after Railway reports that deployment healthy), and then, at `url`, `/health` answers `{"status": "ok"}` and `/version` reports one of: the release, the build's version, or what the build declares (the build's version without its `+g` part) | a record left on another image; a service down or unhealthy at its public address; an older build still answering (on `main`, the previous deploy reports an older declared version) |
| Lambda (`python-service`) | `get-function-configuration` reports the function `Active`, its `LastUpdateStatus` `Successful`, and its `CodeSha256` that of the artifact's zip | an update still in progress or failed; any other code |
| Cloudflare Pages (`astro-site`) | the site at `url` answers, and the deployment Pages serves in the environment carries `pipeline-deploy version=<this version> artifact=<this digest>` | a site that does not answer; a Git build or another upload being served |
| PyPI (`python-library`), npm (`npm-library`) | the published version resolves on the registry, in production. In development nothing is published, and the stage skips and says so | a release whose publish did not land |
| `terraform-infra`, `shared-workflows` | nothing: the stage skips and says why | |

The service check is the one that still leans on what the build declares.
Once a service reports the build it is running (its build's version, with
the `+g` part, or the release itself), the same check matches that exactly
and nothing in this stage changes. `/health` is polled because it is the
fleet's liveness probe: it answers with no auth and no database query, so
the stage touches no dependency of the service.

**Polling.** The decisions are `verify-decision.sh` in the `verify-decision`
action: which versions count, how a report compares, the backoff (from
`poll-initial-seconds`, doubling, capped at `poll-max-seconds`), and the
poll, which gives up once waiting again would pass
`verify-timeout-seconds`. What each target reports is `probe.sh` beside
it. `scripts/test-verify-decision.sh` proves both case by case, the probes
against a local server standing in for each target.

**The record.** Verified or not, the stage writes a commit status on `sha`,
the release's commit in production: context `pipeline/verify (<environment>)`,
`success` or `failure`, with the version and the reason in its description
and the run as its link. It is read by ref, so the release reconciler reads
it from the release tag
(`GET /repos/<owner>/<repo>/commits/<tag>/statuses`, newest of the context
first). A commit status was chosen over a GitHub deployment status, which
would need a deployment the pipeline does not make, and over a check run,
which `GITHUB_TOKEN` can only attach to whatever check suite it lands in.
Re-running the stage writes a newer status, and the newest is the one that
counts.

**The alarm.** On a timeout the stage posts the repository, version,
environment, reason and run to the `discord-webhook-url` secret, the errors
channel's webhook. The fleet keeps that webhook as
`DISCORD_WEBHOOK_URL_ERRORS`, the name the API reads it by; it must also be
a GitHub secret of the organisation for workflows to use it. Without it the
stage warns that it could not post, and still fails.

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The repository's profile |
| `environment` | required | `development` or `production`, where `deploy` ran |
| `version` | required | The deploy stage's `deployed-version` |
| `build-version` | empty | The build stage's `version`; empty: `version` |
| `sha` | the run's commit | The commit the record is written on: `release`'s `sha` in production |
| `target` | `live` | `fake` is the self-test's stand-in. Consumers leave it, and `expect-failure` and `fake-serves`, which only it takes |
| `timeout-minutes` | `20` | How long the verify job may run |
| `verify-timeout-seconds` | `600` | How long to keep asking the target |
| `poll-initial-seconds`, `poll-max-seconds` | `5`, `60` | The backoff between attempts |
| `url` | empty | `api-service`: the service's base URL in the environment (required). `astro-site`: the site's URL; empty, the project's `pages.dev` address for the environment |
| `health-path`, `version-path` | `/health`, `/version` | `api-service`: where it answers |
| `image-repository` | `ghcr.io/<owner>/<repo>` | `api-service`: as the deploy stage's |
| `artifact-name`, `artifact-digest` | empty | `python-service`: the zip to compare. `astro-site`: the digest the served upload must carry |
| `lambda-handler`, `aws-role-arn`, `aws-region`, `lambda-function-name` | empty | `python-service`: as the deploy stage's. The deploy role can read the function's configuration |
| `pages-project`, `cloudflare-account-id`, `pages-development-branch` | empty, empty, `dev` | `astro-site`: as the deploy stage's |
| `package-name` | from `pyproject.toml` or `package.json` | Libraries: the registry name |
| `npm-registry` | `https://registry.npmjs.org` | `npm-library`: where `release` publishes |

| Secret | Meaning |
|---|---|
| `cloudflare-api-token` | `astro-site`: the deploy stage's Cloudflare token will do |
| `discord-webhook-url` | The errors channel's webhook: `DISCORD_WEBHOOK_URL_ERRORS` |

The calling job grants `contents: read`, `statuses: write` (the record),
`packages: read` (the GHCR deploy record) and `id-token: write` (the Lambda's
OIDC role), whatever its profile. In `pipeline.yml`:

```yaml
  verify:
    needs: [build, release, deploy]
    if: always() && needs.deploy.result == 'success'
    permissions:
      contents: read
      statuses: write
      packages: read
      id-token: write
    uses: $/.github/workflows/stages-verify.yml
    with:
      profile: ${{ inputs.profile }}
      environment: ${{ github.ref == 'refs/heads/main' && 'production' || 'development' }}
      version: ${{ needs.deploy.outputs.deployed-version || needs.release.outputs.version }}
      build-version: ${{ needs.build.outputs.version }}
      sha: ${{ github.ref == 'refs/heads/main' && needs.release.outputs.sha || github.sha }}
      artifact-name: ${{ needs.build.outputs.artifact-name }}
      artifact-digest: ${{ needs.build.outputs.artifact-digest }}
      url: ${{ github.ref == 'refs/heads/main' && vars.API_URL_PRODUCTION || vars.API_URL_DEVELOPMENT }}
      # and the repository's target inputs, as for deploy
    secrets:
      cloudflare-api-token: ${{ secrets.CLOUDFLARE_PAGES_API_TOKEN }}
      discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK_URL_ERRORS }}
```

`evaluate-post` needs `verify` and runs only when it reports `verified`
`true` (or `skipped`); see Evaluation stages.

### Evaluation stages

`stages-evaluate.yml` is both evaluation stages, chosen by `phase`. Each asks
api-kaianolevine-com (`POST /v1/evaluations/runs`) for a deterministic
conformance evaluation of one commit, pinned by its full `sha`, and records
the phase on every finding.

- **`evaluate-pre`** (`phase: pre-release`) runs on a push to `main` after
  `build`, on the commit about to be released, and gates `release`. It waits
  for the outcome and passes only when the evaluation is complete and holds
  no blocking finding. It fails as soon as a blocking finding arrives, and
  it fails when no decision comes within `evaluate-timeout-seconds` (fail
  closed): a release goes out only on an evaluation that said yes.
- **`evaluate-post`** (`phase: post-release`) runs after `verify`, on the
  release `release` published in the same run: its `version`, `tag` and
  `sha` come in as inputs from `release`'s outputs, never from another run.
  It asks and reports; it does not wait for the findings and fails only when
  the API does not accept the request, since a dropped request leaves the
  release unevaluated while looking fine. When `published` is anything but
  `true` there is no release, and it skips and says so without asking.

**What blocks a release.** A `CRITICAL` or `ERROR` finding. ecosystem-standards'
`index.yaml` defines `ERROR` as a violation that "requires remediation before
next deploy", which is exactly the decision this stage makes; `CRITICAL` is
emitted when the evaluation itself could not run, which is no evaluation at
all. The evaluator also reports a repository it could not read (its
download failed, or processing raised) as an `ERROR` status row, so that
blocks too. `WARN` ("remediation recommended") and `INFO` are reported in
the job summary and do not block. Severities are what the evaluator posts,
after the repository's exemptions, deferrals and downgrades in its
`evaluator.yaml`, so a rule is waived for a repository there, not here.

**How it waits.** The request is answered before anything is evaluated, so
`evaluate-pre` reads `GET /v1/evaluations/runs/outcome?repo=&sha=&phase=&since=`
with backoff (from `poll-initial-seconds`, doubling, capped at
`poll-max-seconds`). The API answers with the newest evaluation of that
commit and phase that started at or after `since` (the moment the stage
asked): its state (`pending`, `running` or `complete`), its findings counted
by severity, and the findings themselves. Findings are only ever added to a
run, so a blocking one decides at once, finished or not. A pass needs
`complete`: an evaluation holding its `SUCCESS` row (a clean one), or one
whose findings stopped arriving the API's settle period ago. The evaluator
computes every check, then posts a repository's findings together, so a
quiet run has finished. An API without the outcome route (404) fails at once, as `unsupported`.
The decisions are `evaluate-decision.sh` in the `evaluate-decision` action;
`scripts/test-evaluate-decision.sh` proves them against `stand-in.py`, a
stand-in for the two API routes.

**Running it twice.** A re-run asks again. The API has no request-level
idempotency today: a repeated (repo, sha, phase) is enqueued as a second
evaluation under its own run id, and its findings are deduplicated only
within that run. The stage tolerates that: it reads only evaluations that
started after its own request, and of those the newest, so a re-run decides
on the evaluation it asked for, never on a stale one (a transient
"could not download" row included). Pipeline Health shows each repository's
newest run, so the second evaluation replaces the first there.

**The key.** `secrets.api-key` is the `ci-validator` machine key, the
organisation secret `CI_VALIDATOR_API_KEY`, as for `evaluate.yml`. It holds
one scope, `evaluations.runs.create`: it can cause an evaluation, not write a
finding. A cog's key is never passed here. Reading the outcome needs no key:
like `GET /v1/evaluations`, it is public and read-only.

| Input | Default | Meaning |
|---|---|---|
| `phase` | required | `pre-release` or `post-release` |
| `sha` | required | The full commit sha: `github.sha` before release, `release`'s `sha` after |
| `version`, `tag` | empty | `post-release`: `release`'s `version` (required when published) and `tag` (empty: `v<version>`) |
| `published` | empty | `post-release`: `release`'s `published`; anything but `true` skips |
| `repo`, `org` | the calling repository | What to evaluate |
| `api-url` | `https://api.kaianolevine.com` | Base URL of api-kaianolevine-com |
| `timeout-minutes` | `10` | How long the job may run |
| `evaluate-timeout-seconds` | `300` | `pre-release`: how long to wait for a decision before failing closed. A deterministic evaluation finishes within a minute of being picked up |
| `poll-initial-seconds`, `poll-max-seconds` | `5`, `20` | `pre-release`: the backoff between reads |
| `target` | `live` | `fake` is the self-test's stand-in. Consumers leave it, and `fake-scenario` and `expect-failure`, which only it takes |

| Output | Meaning |
|---|---|
| `result` | `pre-release`: `pass`, `blocked`, `timeout`, `unsupported` or `not-requested`. `post-release`: `requested`, `not-requested` or `skipped` |
| `requested` | `true` when the API accepted a request from this run |
| `message-id` | The queue message the request became: the evaluation's id until it has a run |
| `run-id` | `pre-release`: the run the outcome was read from, which its findings are filed under |

Neither job uses the run's token, so each is called with `permissions: {}`.
In `pipeline.yml`:

```yaml
  evaluate-pre:
    needs: [build]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    permissions: {}
    uses: $/.github/workflows/stages-evaluate.yml
    with:
      phase: pre-release
      sha: ${{ github.sha }}
    secrets:
      api-key: ${{ secrets.CI_VALIDATOR_API_KEY }}

  release:
    needs: [evaluate-pre]
    # ...

  evaluate-post:
    needs: [release, verify]
    # Skipped with its reason when nothing was published; otherwise only
    # after verify passed.
    if: always() && needs.release.result == 'success' && (needs.release.outputs.published != 'true' || needs.verify.result == 'success')
    permissions: {}
    uses: $/.github/workflows/stages-evaluate.yml
    with:
      phase: post-release
      published: ${{ needs.release.outputs.published }}
      version: ${{ needs.release.outputs.version }}
      tag: ${{ needs.release.outputs.tag }}
      sha: ${{ needs.release.outputs.sha }}
    secrets:
      api-key: ${{ secrets.CI_VALIDATOR_API_KEY }}
```

**From `evaluate.yml`.** The fleet's `ci.yml` `evaluate` jobs keep calling
`evaluate.yml@v3`, which is unchanged: it asks for an evaluation of `main`
and does not wait, and its callers need do nothing. A repository moves to
the evaluation stages when it moves onto `pipeline.yml`, in the same change
that drops its own `evaluate` job: `evaluate-pre` and `evaluate-post` replace
it, and nothing else in its caller changes. `evaluate.yml` stays for
`scope: fleet` (ecosystem-standards and evaluator-cog) and for
`evaluate-now.yml`.

### Enforced and subscribed

Two layers keep the pipeline whole.

- **Enforced.** infra's organization ruleset `pipeline-main` requires a
  pull request into the default branch of every repository in
  `pipeline.yaml`'s `on_pipeline`, and requires `required.yml` from this
  repository, at the current major's tag, to pass on it. `required.yml`
  runs `security.yml`'s secret scan, dependency audit and static analysis
  in the target repository; the repository does not own that copy and
  cannot remove or edit it. The SBOM is a build artifact, made by the
  pipeline's own `security` stage, not a gate. The promote App is the
  ruleset's one bypass, for the release's commit.

  GitHub runs ruleset workflows only on pull request and merge-queue
  events, never on pushes, so `dev`, which takes direct pushes and
  auto-merges, is not held by the ruleset: every change reaches the
  default branch through the promotion pull request, where it is checked
  once. The deterministic conformance check is not a merge check: it is
  `evaluate-pre`, which gates the release on a push to `main` (see
  Evaluation stages).
- **Subscribed.** Everything else in the stage graph reaches a repository
  through its caller at the current major. Conformance rules require the
  caller to be thin, at the current major, with no inline jobs beyond the
  extension points and no deploy path outside the pipeline.

### The release reconciler

A release that stopped partway is finished inside the pipeline, not by
hand. The release reconciler runs in AWS on the fleet's existing
EventBridge schedule. On each pass, for each repository:

1. It reads the newest release (its tag and commit), what the production
   target reports it runs, and the evaluations recorded for that version.
2. If a stage is missing (not deployed, not verified, not evaluated), it
   finds the original run for that commit and re-runs its failed or
   skipped jobs in that run, so the build stays one flow with one view.
3. Only when the original run can no longer be re-run, it starts a new run
   with `workflow_dispatch` and `ref` set to the release tag. That run's
   summary links the original.
4. A release that stays stuck unchanged alerts once, not on every pass.

The reconciler never builds, releases or deploys anything itself: it only
asks the pipeline to resume. A run started for `ref` skips the stages
before `build`, reuses the tag in `release`, and continues from there.

### Changing the pipeline

The pipeline changes on this repository's `dev` branch and reaches `main`
through the promotion pull request. Every push to `dev` and every pull
request runs workflow static analysis and the pipeline against one fixture
repository per profile (see Testing the pipeline below). A failing fixture
blocks the release. Callers pin a tag cut from `main`, so nothing on `dev`
reaches them before it is released.

- **Protection.** `main` takes a change only by pull request, with this
  repository's security checks and the self-test's `test / gate` passing:
  the `main` ruleset, declared in infra. No review is required, since the organisation has one member who
  cannot approve their own pull request. `CODEOWNERS` names the owner of
  the workflow and action paths and `pipeline.yaml`. The release pushes
  its version commit and moves the major tag as the promote App, the
  ruleset's one bypass: GitHub does not accept GitHub Actions itself as a
  bypass actor.
- **Releases.** This repository releases with semantic-release on every
  merge to `main` that has a releasable commit, as every other repository
  does (see Versioning below).

- **Canary first.** A new major runs on the canary repository named in
  `pipeline.yaml` first. It moves to the rest of the fleet after the soak
  period in `pipeline.yaml` has passed with every stage exercised on `dev`
  and `main`, including one reconciler recovery, and no failure caused by
  the pipeline.
- **Versions.** semantic-release cuts `vX.Y.Z` from the commit messages and
  moves the major tag (see Versioning below). Callers pin the major. A
  breaking change ships only in a new major; the previous major keeps
  working through a deprecation window that ends when the whole fleet has
  moved.
- **Rollback.** Re-point the major tag at the previous release of that
  major. Callers pick it up on their next run with no change of their own.

#### Moving a repository's deploys onto the pipeline

Until a repository is on the pipeline, its platform deploys it from a
branch as today. Every switch below defaults to that, so nothing changes
until a repository opts in, and a repository's auto-deploy goes off in the
same change that moves its deploys onto the pipeline: the canary in
`pipeline.yaml` first, then the rest after its soak. For one repository:

1. **Environment and secrets.** In the repository, a `production`
   environment, with `main` as its only deployment branch and any
   protection rules wanted, and the target's secrets: `RAILWAY_TOKEN` and
   `RAILWAY_TOKEN_DEVELOPMENT` for a Railway service,
   `CLOUDFLARE_PAGES_API_TOKEN` for a Pages site, and for a Lambda the
   deploy role it already has.
2. **The caller.** Its `ci.yml` calls the pipeline with its profile and its
   target inputs (`railway-service`; `pages-project` and
   `cloudflare-account-id`; or the Lambda's), and drops its own deploy jobs.
   `pipeline.yaml` lists it in `on_pipeline` in the same change. Its
   release then pushes as the promote App (`secrets: inherit` passes the
   org's `PROMOTE_APP_CLIENT_ID` and `PROMOTE_APP_PRIVATE_KEY`), and its
   `.releaserc.json` turns off `@semantic-release/github`'s
   `successComment`, `failComment` and `releasedLabels`, which need Issues
   access the App does not have. Once this lands on `main`, an infra apply
   puts the repository under the organization ruleset (see Enforced and
   subscribed).
3. **Branch auto-deploy off, in IaC.**
   - *Railway*: in `.railway/railway.ts`, the service's source moves from
     `github("<org>/<repo>", { branch: "main", checkSuites: false })` to
     `image("ghcr.io/<org>/<repo>:production", { autoUpdates: { type: "disabled" } })`,
     and its `build` settings go (Railway no longer builds it). A service
     with no `github()` source has no branch to deploy from, and
     `autoUpdates` off means Railway never moves it to a newer tag on its
     own. Development, which `railway.ts` does not manage yet (Railway
     refuses a development-scoped plan), moves to
     `image("ghcr.io/<org>/<repo>:development")` the same way once it can;
     until then the development service is changed once on its dashboard,
     recorded in the pull request. Railway must be able to pull the GHCR
     package: public, or with registry credentials on the service.
   - *Cloudflare Pages*: in mini-app-polis/infra, set the project's
     `git_deployments = false` (see that repository's README, "Turning a
     Pages project's Git builds off"). Its Git connection, domains and
     variables stay; only the builds on push stop.
   - *Lambda*: nothing to turn off. The cogs already deploy from CI, not
     from a branch.
4. **Order.** Merge the IaC changes before the caller change reaches
   `main`. If the caller lands first, a release is deployed twice, by the
   platform and by the pipeline: harmless, but not one deploy. After that a
   push to `dev` deploys development from the pipeline, and the next
   release deploys production behind `production`.
5. **Back out.** Revert the caller and the IaC changes; the platform deploys
   from the branch again.

### Testing the pipeline

`ci.yml`'s `test` job calls `self-test.yml`, on every pull request and every
push to `main`. `release` needs `test`, so anything that fails there blocks
the release. Nothing in it is path-filtered: a required check that never
reports holds a pull request open for good.

- **Static analysis.** `workflow-checks.yml` runs actionlint (with a pinned
  shellcheck), zizmor and `scripts/check-workflow-timeouts.py` over
  `.github`. Each tool is pinned to one release and checked against its
  SHA-256 before it runs. zizmor runs offline and fails on any
  high-severity finding; the medium and low findings already present are
  printed and do not fail. actionlint fails on any error. The places it
  misreads, and why, are in `.github/actionlint.yaml`; shellcheck's style
  notes are left out.
- **Fixtures.** `fixtures/<profile>/` holds one minimal repository per
  profile in the Profiles table, with only what that profile's existing
  stages need to run green. The `stages` job runs `stages-test.yml`
  against each: every stage before `build`, ending in its `test` gate,
  with the stages the profile has nothing for skipped in sight. Between
  them the fixtures take every branch a stage has: `api-service` has an
  integration test that needs the Postgres service container and fails
  without it, `npm-library` has `lint` and `test` scripts and `astro-site`
  has neither, `python-service` and `python-library` have no integration
  tests. The `build` job runs `stages-build.yml` twice against each fixture
  and takes the artifact by digest with `fetch-artifact`
  (`self-test-build.yml`), and `artifact-digest check` runs
  `scripts/test-artifact-digest.sh`, which plants a digest mismatch and
  every other way an artifact can be wrong. The same `build` job then runs
  `stages-deploy.yml` against the fixture's stand-in target, to development
  and to production, twice each, and `deploy decision check` runs
  `scripts/test-deploy-decision.sh`. Then it runs `stages-verify.yml`
  against a stand-in service serving what the deploy stand-in recorded: it
  must verify in each environment, twice in production, and, with the
  stand-in serving another version, time out, fail its job, post to the
  stand-in Discord and record the release as not verified. `verify decision
  check` runs `scripts/test-verify-decision.sh`. The `fixture` job runs the release stage twice on one commit,
  re-runs it after each way it can stop partway, and, for the Python fixtures, the local `python-checks` action with
  every check in one job as `python-test.yml` runs it (not
  `python-test.yml` itself, which runs the published action and so would
  test what is already released). The `shared-workflows` fixture also
  runs the static analysis above on its own workflows. The evaluate jobs
  run `stages-evaluate.yml` against a stand-in API once, not per fixture,
  since an evaluation asks about a commit rather than a profile's build:
  `evaluate-pre` must pass a clean evaluation, pass again when re-run on the
  same commit, and fail (its release would not run) on an `ERROR` and on an
  evaluation that never finishes; `evaluate-post` must ask for a release
  wired from release outputs, and skip without asking when nothing was
  published. `evaluate decision check` runs
  `scripts/test-evaluate-decision.sh`. Every stage in the stage graph now
  runs against the fixtures, so there is no `not run yet` job; a stage
  added before it can run here brings one back.
- **No side effects.** A fixture never publishes a package, tags a fleet
  repository, deploys or posts an evaluation. The release stage runs only
  as a dry run, in a scratch repository whose one remote is a bare
  repository beside it, with a `.releaserc.json` that lists no publishing
  plugin. Python fixtures carry the `Private :: Do Not Upload` classifier
  and Node fixtures are `private`, so a registry refuses them even if
  something tried. No fixture names a contract suite, so `contract`, which
  calls the development API, skips against every one, and a fixture needs
  no secret and reaches no network beyond package and container registries.
  The build stage uploads only to the run, and the `api-service` image is
  saved to a tarball, never pushed. The deploy stage runs with
  `target: fake`: it takes the artifact by digest and makes every decision a
  live deploy makes, but its target is a record kept in the run as an
  artifact, so it reads and changes nothing outside the run and needs no
  secret. The verify stage runs with `target: fake` too: it polls a
  stand-in service on the job's own loopback, posts its alarm there, and
  keeps its record as an artifact of the run instead of a commit status.
  The evaluation stages run with `target: fake`: the API they ask is a
  stand-in on the job's loopback with a key of its own, so they read no
  secret and post no evaluation.
- **One gate.** The `gate` job in `self-test.yml` passes only if every
  other job there passed. It is the check `main` requires, and its name
  does not change as fixtures or stages are added.

`stages-test.yml`, `security.yml`, `workflow-checks.yml` and the
`python-checks` action take a `working-directory` input for this: the directory, inside the checkout,
holding the repository to check. Consumers leave it at its default, the
checkout itself.

#### Running a stage twice

Every stage contract above says why a second run on the same commit
changes nothing. Today the fixtures prove it for `release`:
`scripts/check-release-rerun.sh` runs the release on a fixture's
unreleased commit and sees the version it would cut, records that release
as a tag, runs the release again on the same commit, and fails unless the
second run finds nothing to release and the remote still holds one tag.
The first run is what keeps the second from passing vacuously; alongside
each run, the action's `release-state.sh` must say `release` on the
unreleased commit and `finish` with that tag on the released one.
`scripts/check-release-resume.sh` proves the re-run of a release that
stopped partway, in the same kind of scratch repository: a release commit
pushed with no tag (and a later release refusing until it is tagged), a tag
with no GitHub release, a major tag never moved, an older release finished
without dragging the major tag back, and the reconciler's `ref`, from any
branch, as a release tag on `main` only. Each re-run must leave exactly one
tag and one release commit per version, and a second re-run must change
nothing. The GitHub release is made through the API, which cannot run
there, so the proof stops at `release-state.sh` asking for it. `lint`,
`unit` and `integration` change nothing outside the run, so running them
twice is safe by construction. `contract` writes only fixed rows that the
development API upserts; it is not run twice here because no fixture may
reach that API.

As each later stage lands it adds its own proof here, run twice against
the fixtures in the same job:

- `build` reuses the artifact already in the run for this commit, and the
  second run reports the same digest. The `build` job in `self-test.yml`
  proves it for every fixture.
- `deploy` reads what the target runs first; against a fixture its target
  is a stand-in that only records, and the second run must skip with the
  version already there. The `build` job in `self-test.yml` proves it for
  every fixture and both environments; a profile with nothing to deploy
  must report nothing deployed.
- `verify` only reads, so it needs no more than to pass twice. The `build`
  job in `self-test.yml` runs it twice in production for every fixture,
  after a run to development, and then once against a version that is not
  the release, which must fail.
- `evaluate-pre` and `evaluate-post` only ask and read. A re-run asks
  again and decides on the evaluation it asked for (see Evaluation stages);
  the `evaluate-pre-again` job in `self-test.yml` runs it a second time on
  the same commit, which must pass again. Once the API answers a repeated
  (repo, sha, phase) with the evaluation it already has, the same job
  proves that, with no change to the stage.

#### Pointing it at pipeline.yml

Once `pipeline.yml` exists, the `stages`, `build`, `fixture` and evaluate jobs in
`self-test.yml` become one matrix job over the profiles that calls it:

```yaml
  fixture:
    name: fixture (${{ matrix.profile }})
    strategy:
      fail-fast: false
      matrix:
        profile: [python-service, api-service, python-library, astro-site, npm-library, terraform-infra, shared-workflows]
    uses: ./.github/workflows/pipeline.yml
    with:
      profile: ${{ matrix.profile }}
      working-directory: fixtures/${{ matrix.profile }}
```

For that, `pipeline.yml` needs a `working-directory` input that every stage
honours, as `stages-test.yml` does now (with the `postgres-image` the
`stages` job passes `api-service` today becoming that profile's default), and every stage that
reaches outside the run (release, deploy, verify, evaluate) needs a mode the
fixtures run it in that has no effect outside the run (deploy, verify and
evaluate have one, `target: fake`). A stage the profile
has no use for is skipped with its reason, as the stages before `build`
already are. `gate` keeps its name and needs the new job.
A new profile adds a directory under `fixtures/` and an entry in the
matrix.

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
| `self-test` | `false` | Also prove the GitHub advisory pass against known advisories. This repo's own CI turns it on; consumers leave it off |
| `working-directory` | `.` | The directory, within the checkout, holding the repository to check. For this repo's fixtures; consumers leave it. The secret scan reads the whole checkout's history whatever it says |

### Advisory sources

The dependency audit reads two sources, and a finding in either fails it:

| Language | First source | Second source |
|---|---|---|
| Python | pip-audit, on PyPI's vulnerability service (PyPA advisories) | GitHub's reviewed advisory database |
| TypeScript | osv-scanner, on OSV.dev | GitHub's reviewed advisory database |

The second source is what Dependabot alerts read. PyPA and OSV mirror it
but can lag: on 2026-10-24 GHSA-cx6f-vjhg-g3cc (virtualenv, high) was in
GitHub's database and in a Dependabot alert while both audits passed the
same lock. The GitHub pass asks `GET /advisories` about every locked
package, fails on **high** or **critical**, and lists lower severities
without failing. A finding names the package, the locked version, the
advisory id and the first patched version.

- It authenticates with the job's own `GITHUB_TOKEN`, for the rate limit
  only; no secret is added and the endpoint needs no permission.
- GitHub matches package names exactly, and stores some Python projects
  under more than one spelling (`PyYAML` and `pyyaml` carry different
  advisories), so a Python package is asked about under its lock name, its
  normalized name and its PyPI display name.
- The packages the first source leaves out (the project itself, git
  dependencies, and the fleet's own published libraries) are left out of
  this one too. A Python line that is not pinned with `==` is printed as
  unchecked.
- It fails rather than passes when it has nothing to check, or when GitHub
  or PyPI cannot be read after three attempts.
- `dependency-fix.yml` still fixes what pip-audit or osv-scanner finds; a
  finding only the GitHub pass makes is fixed by hand.

### Exceptions

An advisory with no fixed release can be excepted for one lockfile, for a
while, in an `osv-scanner.toml` beside that lockfile:

```toml
[[IgnoredVulns]]
id = "GHSA-xxxx-xxxx-xxxx"
ignoreUntil = 2027-01-27
reason = "Why it cannot be fixed now, and why it is not reachable."
```

osv-scanner honours the file for that lockfile, and the GitHub advisory pass
honours each entry that has an `ignoreUntil` date, reporting the finding as a
warning instead of failing. An exception covers a package only where every
lockfile holding it carries the same entry. On the date the finding gates
again, so an exception is renewed with a reason or removed, never forgotten.
The Node audit reads these files; the Python audit does not yet.

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

On the canonical pipeline, the evaluation stages replace this job (see
Evaluation stages). Until a repository moves, add one job that runs after
your release job:

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
`ruff format --check`, the type check, Terraform fmt and validate when
asked, pytest, and `facts check` when the repo has a `facts.yaml`. It is the
union of what the cogs ran inline, so adopting it removes no check a caller
had. The checks live in the composite action
`.github/actions/python-checks`, which the shared agent also runs on an
agent's change before it opens a pull request. Its uv is the release
`pipeline.yaml` pins (see Test stages).

```yaml
jobs:
  test:
    uses: mini-app-polis/.github/.github/workflows/python-test.yml@v3
```

In the canonical pipeline, `stages-test.yml` takes this job's place. It
runs the same checks through the same action, whose `stage` input splits
them into `lint`, `unit` and `integration` jobs; `python-test.yml` runs
them all in one job, as it always has.

| Input | Default | Meaning |
|---|---|---|
| `python-version` | `3.11` | Match the runtime the repo deploys to |
| `pytest-args` | `--cov=src --cov-report=term-missing` | Appended to pytest |
| `timeout-minutes` | `30` | How long the test job may run; raise it for a longer suite |

## Shared release

`.github/workflows/release.yml` runs semantic-release for the calling
repository. It wraps the composite action `.github/actions/semantic-release`,
which installs semantic-release and its plugins with `npm ci` from the
lockfile committed beside it, then runs semantic-release in the caller's
checkout. Every release in the fleet installs the same reviewed versions,
transitive dependencies included, and Dependabot moves them forward
(ecosystem-standards VER-006). The action's README says what is locked and
why `@semantic-release/npm` is not used.

### Using it

A release job that is only checkout and release calls the workflow:

```yaml
jobs:
  release:
    needs: [test, security]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    permissions:
      contents: write
      issues: write
      pull-requests: write
    uses: mini-app-polis/.github/.github/workflows/release.yml@v3
```

A repository whose `main` ruleset refuses direct pushes passes the promote
App's credentials, and the release checks out and pushes as the App, which
the ruleset lets through:

```yaml
    secrets:
      app-client-id: ${{ secrets.PROMOTE_APP_CLIENT_ID }}
      app-private-key: ${{ secrets.PROMOTE_APP_PRIVATE_KEY }}
```

A release job with steps of its own around the release (a dependency
install before it, a dispatch after it) keeps its job and replaces its
semantic-release install and run with the action:

```yaml
      - uses: mini-app-polis/.github/.github/actions/semantic-release@v3
        id: release
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Both expose the release stage's outputs:

| Output | Meaning |
|---|---|
| `published` | `true` when the commit has a release on the remote after the run: cut by it, or cut by an earlier run and finished by this one. `false` when there is nothing to release, and on every dry run |
| `version` | `X.Y.Z`, or empty |
| `tag` | `vX.Y.Z`, or empty when the commit has no release, as before. Now also set on a run that finished an earlier release, so a job that runs on it (a deploy) runs on the re-run too |
| `sha` | The commit the tag is on: the release commit, where `@semantic-release/git` makes one |
| `resumed` | Action only: `true` when an earlier run cut the release and this one finished it |

### Main only, one at a time

The release cuts a release on `main` only. On any other ref it refuses
before semantic-release runs, unless it is a dry run, or `ref` names a
`vX.Y.Z` tag on `main`, which it finishes and never cuts again.
`release.yml`'s job runs in the concurrency group
`release-<owner>/<repo>`, which never cancels a release in progress; a
repository that calls the action from its own job gives that job the same
group.

### Re-running a release

Running the release again on a released commit cuts nothing, and running
it again after it failed partway finishes it. Before semantic-release, the
action's `release-state.sh` looks for this commit's release: a `vX.Y.Z`
tag on it, or the release commit `@semantic-release/git` pushed on top of
it (`chore(release): X.Y.Z [skip ci]`). When there is one, semantic-release
does not run, and the action finishes what that release is missing:

| Stopped after | A re-run |
|---|---|
| the release commit, before the tag | tags the release commit and pushes the tag, makes the GitHub release, moves the major tag |
| the tag, before the GitHub release | makes the GitHub release from the release commit's notes, moves the major tag |
| the GitHub release, before the major tag | moves the major tag |

The tag is never moved once pushed, and the major tag moves only onto the
newest release of its major, in a repository that already keeps major tags,
so finishing an old release never drags it back. While a release commit has
no tag, a release of a later commit refuses rather than cut that version a
second time; re-running the stopped run finishes it. A dry run says what it
would finish and does nothing.

`release-state.sh` decides what is missing and changes nothing;
`finish-release.sh` does the git half; the GitHub release is one `gh release
create`. `scripts/check-release-resume.sh` proves the first two against a
scratch repository (see Running a stage twice).

### Publishing and notices after the release

A package publish or a fleet notice that semantic-release itself runs (an
`@semantic-release/exec` `publishCmd` or `successCmd`) does not run again on
a re-run, because semantic-release does not. A repository whose release
publishes something puts that publish, and any notice after it, in steps of
its own after the release step, on `published`:

```yaml
      - uses: mini-app-polis/.github/.github/actions/semantic-release@v3
        id: release
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - name: Publish to PyPI
        if: steps.release.outputs.published == 'true'
        env:
          VERSION: ${{ steps.release.outputs.version }}
          TAG: ${{ steps.release.outputs.tag }}
        run: |
          # Already there: an earlier run published it.
          if curl -sf "https://pypi.org/pypi/miniapppolis-common-utils/${VERSION}/json" >/dev/null; then
            echo "miniapppolis-common-utils ${VERSION} is already on PyPI."
            exit 0
          fi
          git checkout "${TAG}"
          uv build && uv publish --trusted-publishing always
```

Each such step makes itself safe to repeat, since `published` is `true` on
every re-run of a released commit: a publish skips a version the registry
already has (or uses the registry's own skip, such as `uv publish
--check-url https://pypi.org/simple/`), and a notice is one its receiver takes twice without harm (a
`repository_dispatch` that re-locks onto a version already locked changes
nothing). A caller of `release.yml` does the same in a job that needs the
release job and runs `if: needs.release.outputs.published == 'true'`,
checking out `needs.release.outputs.tag`.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `dry-run` | `false` | Work out the next version and the notes, and change nothing |
| `node-version` | `22` | Node.js version semantic-release runs under |
| `git-author-name` | empty | Author and committer name of the release commit; empty keeps semantic-release-bot |
| `git-author-email` | empty | Author and committer email, used with `git-author-name` |
| `artifact-name`, `artifact-digest` | empty | Workflow only: the build stage's outputs. The release takes that artifact, refuses it on a digest mismatch, and sets `PIPELINE_ARTIFACT_DIR` to it for semantic-release (see Build stage) |
| `github-token` | the job's token | Action only: the token semantic-release pushes and creates the release with |
| `ref` | empty | A `vX.Y.Z` tag on `main` to finish rather than the run's commit: the release reconciler's `ref`. `release.yml` checks it out. Never cut again |

Run by hand from the Actions tab, `release.yml` is a dry run of this
repository's own next release.

## Shared Lambda deploy

`.github/workflows/lambda-deploy.yml` uploads a cog's function zip and
fails unless the checksum AWS reports is the zip's. Given the build stage's
`artifact-name` and `artifact-digest`, it deploys that artifact's zip;
given `ref`, it builds the zip from the lockfile and proves it starts in
Lambda's own runtime with the `lambda-zip` action, the one the build stage
runs. Each cog's `infra/`
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
| `ref` | empty | The release tag to build. Not used with `artifact-name` |
| `artifact-name`, `artifact-digest` | empty | The build stage's outputs: deploy that artifact's zip instead of building. Both or neither |
| `handler` | *(required)* | `module.function`, as `handler` in the cog's `infra/worker.tf` |
| `architecture` | *(required)* | `x86_64` or `arm64`, as `architectures` in `infra/worker.tf`. The deploy refuses a function whose architecture differs, and an artifact built for another |
| `python-version` | `3.11` | As `runtime` in `infra/worker.tf` |
| `strip` | *(none)* | Top-level paths to drop from the zip because the cog never imports them. boto3 is always dropped |
| `role-arn`, `region`, `function-name` | *(required)* | From the cog's `terraform output` |
| `version` | empty | The version being deployed, for the summary and the deploy decision |
| `environment` | empty | The GitHub Environment the job runs in; the deploy stage passes `production` for a production deploy |
| `skip-if-deployed` | `false` | Read the function's CodeSha256 first and skip when it is already this zip. The deploy stage sets it |

Its outputs are `deployed-version` and `deployed`, as the deploy stage's.

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

## Shared Railway plan and apply

`.github/workflows/railway-plan.yml` and `railway-apply.yml` drive a
repository's Railway Infrastructure as Code (`.railway/railway.ts`) the way
mini-app-polis/infra drives Terraform: plan on the pull request into
`main`, plan again and apply on the push to `main`, and refuse destructive
changes unless the pull request is labelled **`allow-destroy`**. Nothing is
applied from a workstation. db-ops carried the first pair (MINI-67); they
moved here when three more repositories took up the pattern (MINI-70).

```yaml
# .github/workflows/railway-plan.yml
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened, labeled, unlabeled]
    paths: [".railway/**", ".github/workflows/railway-plan.yml"]
permissions:
  contents: read
jobs:
  plan:
    uses: mini-app-polis/.github/.github/workflows/railway-plan.yml@v3
    secrets:
      railway-token: ${{ secrets.RAILWAY_TOKEN }}

# .github/workflows/railway-apply.yml
on:
  push:
    branches: [main]
    paths: [".railway/**", ".github/workflows/railway-apply.yml"]
  workflow_dispatch:
permissions:
  contents: read
  pull-requests: read
jobs:
  apply:
    if: github.ref_name == 'main'
    uses: mini-app-polis/.github/.github/workflows/railway-apply.yml@v3
    secrets:
      railway-token: ${{ secrets.RAILWAY_TOKEN }}
```

The plan is `railway config plan`, written to the job summary (values are
redacted by the CLI). The apply plans again and runs `railway config apply
--yes`: as in infra, what lands is `main` as it is when it lands, not a
pinned artifact, and nothing is applied when the plan is empty.

A plan that destroys anything — a `  - Delete …` line, counted in
`N to destroy` — fails the pull request's `plan` check unless the pull
request is labelled **`allow-destroy`**; the check re-runs on `labeled` /
`unlabeled`, lists exactly what goes, and passes. The apply checks the same
label on the pull request the merge came from before passing the CLI's
`--confirm-destructive`, without which it refuses destructive changes
anyway.

**The token picks the environment.** A Railway project token is scoped to
one environment, and each repository keeps its own as a secret — never an
account, workspace or org-wide token. A service that also runs in
development adds a job to its apply on the `dev` branch, passing a
development-scoped token (`RAILWAY_TOKEN_DEVELOPMENT`),
`environment: development` and `allow-destroy: always`: work is committed
straight to `dev`, so there is no pull request to label, and development is
where a mistake in the file should show up first.

| Input | Workflow | Default | Meaning |
|---|---|---|---|
| `environment` | both | `production` | Names the run and its concurrency group. It does not choose the environment; the token does |
| `allow-destroy` | apply | `label` | `label`: destructive changes need the `allow-destroy` label. `always`: they always apply |
| `blocked-window` | apply | *(none)* | `<DD> <HH>-<HH>` UTC, hours inclusive, in which the apply refuses to run. db-ops passes `"02 09-10"`, its drill window |
| `blocked-window-reason` | apply | *(generic)* | Printed when the apply refuses |

**Branch deploys are a setting in `railway.ts`.** A service whose source is
`github("<org>/<repo>", { branch: "main", checkSuites: false })` is
deployed by Railway on every push to that branch, which is how the fleet
deploys today. A service on the canonical pipeline declares
`image("ghcr.io/<org>/<repo>:<environment>", { autoUpdates: { type: "disabled" } })`
instead: Railway then deploys only when the pipeline's deploy stage asks,
and only the image the stage put under that tag (see Deploy stage, and
Moving a repository's deploys onto the pipeline). The change is planned and
applied like any other.

Pinned here, so a bump is one change for the fleet: Railway CLI 5.68.0.
Both install the IaC SDK from `.railway/package.json`
(`npm ci --prefix .railway`), because a Python repository has no root
`package.json`. Fork pull requests get no plan: they get no secrets.

## Shared dev → main promotion

`.github/workflows/promote.yml` runs on every push to `dev`. When `dev` has
commits `main` lacks (merge commits aside), it opens a `chore: promote dev
to main` pull request, or rewrites the open one's description to list what
the next release will contain. It never merges.

```yaml
name: promote
on:
  push:
    branches: [dev]
permissions:
  contents: read
jobs:
  promote:
    uses: mini-app-polis/.github/.github/workflows/promote.yml@v3
    secrets: inherit
```

It opens the pull request as a GitHub App rather than as
`github-actions[bot]`, because GitHub holds every `pull_request` run on a
bot-opened pull request for manual approval. The App needs Pull requests:
write and Contents: read, is installed on the org, and is configured
through two org secrets, `PROMOTE_APP_CLIENT_ID` and
`PROMOTE_APP_PRIVATE_KEY`. Their values live in Doppler, and Doppler's
GitHub sync writes them to the org's Actions and Dependabot secrets; they
are never set by hand in GitHub. Without them the job fails and names
them.

## Shared auto-merge into dev

`.github/workflows/automerge.yml` merges a pull request into `dev` when
every check on its head commit has passed. Merging into `main` stays
manual, through the promotion pull request.

```yaml
name: automerge
on:
  workflow_run:
    workflows: [CI]   # every workflow that runs on pull_request
    types: [completed]
permissions:
  contents: read
  pull-requests: read
  checks: read
  statuses: read
jobs:
  automerge:
    uses: mini-app-polis/.github/.github/workflows/automerge.yml@v3
    secrets: inherit
```

- **Majors included.** `dev` is where changes get exercised; the manual
  merge to `main` is the gate. Drafts and anything not based on `dev` are
  not merged, and a repository can hold back branches by pattern with the
  `skip-branch-pattern` input (e.g. `"/majors-"`).
- **Waits for checks from outside Actions.** Cloudflare Pages reports a
  check that triggers no workflow when it finishes, so a pending check is
  polled for up to `pending-wait-seconds` (default 600) before the run
  gives up.
- **Merges as the promote App**, so the push to `dev` runs CI and refreshes
  the promotion pull request. The App needs Contents: read and write for
  this; `promote.yml` still mints a read-only token.
- **Secrets** go in the org's Dependabot secrets as well as its Actions
  secrets, since a Dependabot-triggered run sees only Dependabot secrets.
  Doppler's GitHub sync writes both.
- **Runs from `main`'s copy** of the consumer's file, like every
  `workflow_run` workflow, so it starts working after the first promotion.

## Shared agent

`.github/workflows/agent.yml` runs headless Claude Code on one board task in
the calling repository and opens a **draft** pull request into the branch
it was started on: `dev`, or `main` in this repository, its own caller.
task-manager-cog dispatches it for a Ready task and applies the result it
reports; see that repository's README for which tasks it takes. Each
repository the agent may change has a thin `workflow_dispatch` caller (the
usage is in the workflow's header), and having that caller is what makes a
repository a target.

- **The model holds no GitHub write credential.** The checkout keeps none
  and the agent's step has only the Anthropic key. It edits and runs the
  repository's checks; later fixed steps push `agent/<task>-<run>` and open
  the draft as the agent App.
- **Drafts only**, so `automerge.yml` never merges what an agent wrote.
- **Nothing is retried.** A run that reaches its budget, errors, changes
  nothing or touches a workflow file opens no pull request.
- **CI's test stage gates the pull request.** In a uv repository the
  `python-checks` action runs on the agent's change, with the inputs the
  repository's own `ci.yml` passes to `python-test.yml`, and the prompt
  lists those same commands. A failure gets one repair attempt under its
  own budget (`repair-budget-usd`, default 0.50 USD); if the stage still
  fails, the branch is pushed for a person to look at, no pull request is
  opened, and the run reports failed.
- **Unclear tasks go back to refining.** An agent that finds its task
  unclear or undetermined changes nothing and ends with `QUESTION:` lines.
  The run reports `needs_refining` with those questions and pushes nothing,
  even if it changed files; task-manager-cog moves the task back to
  refining.
- **Answers the Done when.** An agent that finishes its task ends with one
  `ANSWER:` line per Done when item, in the task's order, each naming its
  evidence (tests, files, checks); a repair's answers, when it gives them,
  replace the first run's.
- **Always reports** its outcome, cost and pull request with its Done when
  answers (or its questions) to api-kaianolevine-com with the task-agent
  key, which may post a result and nothing else. task-manager-cog posts a
  succeeded run's result on its task as the `Handed off:` comment, the
  answers as a numbered list, one item per Done when item, which is what
  its Review check reads, and moves the task to Review. The
  task closes when a `Landed:` comment confirms green CI on dev, from
  whoever confirms it.
- **Toolchains** follow the repository's lock file: uv, pnpm, npm or
  Terraform, plus PyYAML for Python scripts under `scripts/` in a
  repository without `uv.lock`. Each sets up the dependencies before the
  agent starts and allows its check commands (`uv run`, `pnpm run`,
  `npm run`, `terraform fmt` and `validate`, `python3 scripts/`).
- **Postgres, when the caller asks.** `postgres: true` starts a pgvector
  Postgres 16 on `localhost:5432` (database `postgres-db`, which must end
  in `_test`) before the agent runs, as a `ci.yml` runs it as a service,
  and sets `TEST_DATABASE_URL` for the agent and CI's test stage. It is a
  `docker run` step, since `services:` cannot depend on an input.
- **Coverage data is never committed.** `.coverage` and `.coverage.*` are
  left out of what counts as a change and of the commit, whatever the
  repository's `.gitignore` says.
- **`dry_run`** proves the checkout, toolchain, CI's test stage on the
  unchanged branch, App and API key without calling the model, pushing or
  posting.
- **Secrets:** `AGENT_ANTHROPIC_API_KEY`, `AGENT_APP_CLIENT_ID`,
  `AGENT_APP_PRIVATE_KEY` and `TASK_AGENT_API_KEY`, as organisation
  secrets written by Doppler's GitHub sync. The sync scopes an org secret
  to all repositories, not chosen ones, so what limits the agent is the
  App: it needs Contents, Pull requests and Actions read and write, and is
  installed on the target repositories only.
- **Runs only from the default branch's caller**: `workflow_dispatch`
  needs the caller on `main`, so a new target starts working after its
  first promotion.

## Fleet-wide re-locks

Two workflows here are not called by anything. They run in this repository,
find every repository the promote App is installed on that has a `uv.lock`
on `dev` (for `dependency-fix.yml`, or a `pnpm-lock.yaml`), and re-lock
each one, opening one `fix(deps)` pull request into `dev` per repository.
`automerge.yml` merges it once CI is green, and it reaches `main` through
the promotion pull request like anything else.
Both open or refresh their pull request with `scripts/open-lock-pr.sh`: the
branch is one commit on top of `dev`, and is left alone, not re-pushed, when
it already carries the same lock on the current `dev`.

| Workflow | Trigger | Re-locks | Branch |
|---|---|---|---|
| `dependency-fix.yml` | once a day (10:23 UTC), or by hand | each package the dependency audit (SEC-003) flags, to the smallest version that clears it | `security-fix/deps` |
| `commons-update.yml` | a `commons-released` repository_dispatch from a library's release job, or by hand | one fleet library, to the version just released | `commons-update/<package>` |

### dependency-fix in a pnpm repository

pnpm cannot re-lock one package to a chosen version, so the fix is written
into `package.json` and the lock re-resolved from it
(`scripts/fix-vulnerable-pnpm-deps.py`), against the same osv-scanner audit
security.yml runs:

- **A direct dependency** at the flagged version has its declared range
  raised to the fixed version, keeping its `^`, `~` or exact form.
- **A transitive one** gets a `pnpm.overrides` entry for its release line,
  `"name@7": "^7.29.0"`, or `"name@>=0.24.0 <0.25.0": "^0.25.0"` when the fix
  is past the line. pnpm applies a keyed override only where the range a
  dependent asks for falls inside the key, which is why the key is the whole
  line rather than the vulnerable range. An override already under the same
  key, or the bare name, is raised instead.
- An edit that does not resolve, or does not clear its advisory, is dropped,
  and the advisory is reported as not cleared.

The pull request carries `package.json` and `pnpm-lock.yaml`.

### commons-update

common-python-utils (`miniapppolis-common-utils`) and identity
(`miniapppolis-identity`) dispatch `commons-released` from their release jobs
once semantic-release has published a new version in that run — a
semantic-release tag on the release commit, after a release step that only
succeeds once `uv publish` has. The payload is the package, the version, the
releasing repository and its run URL. There is no schedule: Dependabot's
daily check for these two packages is what this replaces.

For that package and version it:

1. **Waits for PyPI.** `uv publish` returns when the upload is accepted;
   the simple index uv reads can lag it. The run polls the index until it
   lists a file for the version, for up to 15 minutes, and fails if it never
   does. Without a version (by hand), it takes PyPI's latest.
2. **Finds the consumers**: repositories whose `dev` uv.lock resolves the
   package from PyPI. A library locks itself as an editable source, so it is
   never its own consumer.
3. **Bumps each one** with `uv lock --upgrade-package <package>==<version>`
   — that package only — then `uv lock --check`. The pull request is
   `fix(deps): bump <package> to <version>`, so the consumer cuts a patch
   release, as it did under Dependabot.

What it will not do, by design:

- **Propose a lock uv rewrote beyond the package.** Packages the new release
  adds, drops or moves within its own ranges are expected and listed in the
  pull request. A change to the lock's header, or to another package's
  markers or sources at an unchanged version, fails the job instead. That is
  a different uv writing the lock differently, and belongs in its own
  commit, not inside a dependency bump.
- **Cross a declared range.** A release a consumer's ranges exclude — a new
  major against `<6` — does not resolve. The job warns and opens nothing;
  widening the range is a person's change.
- **Go backwards.** A repository already at the version or past it gets
  nothing, and a leftover pull request from an older release is closed. A
  run for an older release never overwrites a branch that already carries a
  newer one, and one concurrency group per package and repository keeps two
  quick releases from racing on the same branch.

By hand, from the Actions tab: pick the package, and optionally a version
and one repository. This is also how a release whose dispatch failed is
finished — the library's release job says so, with the version, when it
cannot send the dispatch.

### What both need

- The **promote App**, installed on every fleet repository with Contents
  and Pull requests read and write. The pull requests are opened and
  pushed as the App because a push made with `GITHUB_TOKEN` starts no
  workflows, so the pull request would never get the CI automerge waits on.
- For `commons-update`, the App also installed on **this** repository with
  Contents: write: the libraries' release jobs mint a token for `.github`
  to send the dispatch, and `repository_dispatch` requires Contents: write.
- The org secrets `PROMOTE_APP_CLIENT_ID` and `PROMOTE_APP_PRIVATE_KEY`,
  written by Doppler's GitHub sync and visible to every repository.

A new consumer needs nothing added to it: it is covered once the App is
installed on it and its `dev` lock resolves the package.

## Versioning

Consumers pin a major — `evaluate.yml@v3`, `security.yml@v2` — and that tag
moves. semantic-release cuts `v3.0.1` from the commit messages, and
`scripts/move-major-tag.sh` runs as its `successCmd` to force-push `v3` onto
it (the work is the release action's `move-major-tag.sh`, which the action
also runs when a re-run finds a release whose major tag never moved). A run
with no releasable commits never reaches that script, so the major tag
correctly stays put.

| Tag | Contains |
|---|---|
| `v1` | `security.yml` only, before the osv-scanner swap |
| `v2` | `security.yml` before the GitHub advisory pass |
| `v3` | `security.yml` with the GitHub advisory pass, plus `evaluate.yml`, `python-test.yml` and `lambda-deploy.yml`. Moves with each release |

`v2` no longer moves, so its `security.yml` lacks the GitHub advisory pass
(see "Advisory sources"); a repo calling `security.yml` pins `v3`.

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
