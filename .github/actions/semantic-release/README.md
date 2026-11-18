# semantic-release action

The fleet's release step. `action.yml` installs semantic-release and its
plugins from `package-lock.json` with `npm ci`, in this directory, then runs
semantic-release in the caller's checkout. See the header of `action.yml`
for why the tooling is locked, and the repository README ("Shared release")
for how a repository calls it.

## What is locked

`package.json` lists semantic-release and the plugins the fleet's
`.releaserc` files use. Dependabot updates them weekly (`.github/dependabot.yml`).
A repository whose `.releaserc` needs a plugin that is not listed here gets
it added here, in this lockfile, never installed inline in its own job.

## `npm-stub`, and why `@semantic-release/npm` is not used

semantic-release depends on `@semantic-release/npm`, which depends on npm
itself. npm bundles its own copies of its dependencies, and those copies
have carried advisories with no npm release that fixes them. Locking npm
would put those copies in this lockfile, where the security audit grades
them.

No repository publishes to the npm registry, and semantic-release loads only
the plugins a `.releaserc` lists. So the `overrides` entry in `package.json`
replaces npm with `npm-stub`, an empty package, and npm drops out of the
lockfile. A repository that bumps the version in its own `package.json` does
it with `@semantic-release/exec`:

```json
["@semantic-release/exec", { "prepareCmd": "npm version ${nextRelease.version} --no-git-tag-version --allow-same-version" }]
```

listed where `@semantic-release/npm` would have been, before
`@semantic-release/git`. That `npm` is the one setup-node installs, not this
lockfile's. A `.releaserc` that still lists `@semantic-release/npm` fails at
release time, because the npm it would run is the stub.

## Exceptions

`osv-scanner.toml` here holds the audit exceptions for this lockfile only,
each with a reason and an expiry date. See "Exceptions" in the repository
README.

## `bin/git`, and why pushes are retried

GitHub sometimes answers a push with `! [remote rejected] <ref> (failed)`, a
server-side failure rather than a refusal. semantic-release pushes the
release tag and then a notes ref, and a failure there stops it before the
publish step: no GitHub release, no package upload, no major-tag move, while
the tag is already pushed, so a re-run finds nothing new to release.
`action.yml` puts `bin/` first on `PATH` for semantic-release, and `bin/git`
retries a `git push` that failed with a transient error, waiting longer each
time. Every other git command, and every real refusal (non-fast-forward, a
protected branch, a hook), goes through unchanged.

## Re-runs: `release-state.sh`, `finish-release.sh`, `move-major-tag.sh`

Before semantic-release, `release-state.sh` works out whether this commit
already has a release (a `vX.Y.Z` tag on it, or the release commit pushed on
top of it) and, if so, what that release is missing. It reads git and
changes nothing. When there is a release, semantic-release does not run:
`finish-release.sh` pushes a missing tag and moves the major tag with
`move-major-tag.sh`, and the action makes a missing GitHub release with
`gh release create`. It also refuses to cut a release anywhere but `main`.
The repository README ("Shared release") has the cases, and
`scripts/check-release-resume.sh` proves them against a scratch repository.

`move-major-tag.sh` lives here, not in `scripts/`, so a re-run has it at
the ref the caller pinned; this repository's `.releaserc.json` still calls
it as its `successCmd`, through `scripts/move-major-tag.sh`.
