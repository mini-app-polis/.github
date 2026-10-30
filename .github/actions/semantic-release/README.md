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
