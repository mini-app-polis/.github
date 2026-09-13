#!/usr/bin/env bash
#
# Move the major tag onto the release semantic-release just cut.
#
# Consumers pin a major — `uses: mini-app-polis/.github/.../evaluate.yml@v3` —
# because pinning an exact patch would mean a pull request in thirteen repos
# for every fix. semantic-release does not maintain that tag: it creates
# v3.0.1 and stops. Somebody then has to force-push v3 onto it.
#
# On 2026-09-13 that somebody forgot three times in one afternoon. Each time
# the callers kept resolving the previous file, and each time the symptom was
# a CI failure that looked like a bug in the workflow rather than a tag that
# had not moved. This script is that step, done by the release rather than
# remembered after it.
#
# Runs as semantic-release's successCmd, so it only runs when a release was
# actually published. A run with no releasable commits never reaches here and
# the major tag correctly stays where it is.
#
# Usage: move-major-tag.sh <x.y.z>

set -euo pipefail

version="${1:?usage: move-major-tag.sh <x.y.z>}"
major="v${version%%.*}"
release="v${version}"

# Refuse to move a major tag backwards past one that already exists.
#
# This guards the one way this script can do real damage. semantic-release
# determines the next version from the newest semver tag reachable on the
# branch; if none exists it starts at 1.0.0. So a repo that carries `v1`,
# `v2` and `v3` as bare major tags — none of which parse as semver — but no
# `vX.Y.Z` tag would release 1.0.0, and this script would then force `v1`
# onto it. Every consumer still pinned to `@v1` would silently jump to the
# newest code, which is the opposite of what pinning a major is for.
#
# A failed release is a cheap way to find that out. Being wrong in the other
# direction is not.
highest=$(git tag --list 'v[0-9]*' | grep -E '^v[0-9]+$' | sed 's/^v//' | sort -n | tail -1 || true)
if [ -n "${highest:-}" ] && [ "${version%%.*}" -lt "$highest" ]; then
  echo "refusing to move ${major}: v${highest} already exists, so releasing" >&2
  echo "${release} would move a major tag backwards onto newer code. This" >&2
  echo "usually means no vX.Y.Z tag was seeded and semantic-release started" >&2
  echo "from 1.0.0. Seed the tag rather than overriding this." >&2
  exit 1
fi

# --force on both: the whole point is that the tag already exists and points
# somewhere older. Fetching first would be pointless — the release tag was
# created locally moments ago by semantic-release, and the major tag is being
# replaced rather than read.
git tag --force "$major" "$release"
git push --force origin "refs/tags/${major}"

echo "moved ${major} -> ${release}"
