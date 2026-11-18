#!/usr/bin/env bash
# Finish the git half of a release that stopped partway: the tag a pushed
# release commit never got, and the major tag a release never moved.
# release-state.sh says which is missing; this does exactly that, and
# nothing when nothing is.
#
# The GitHub release, the other thing a stopped release can be missing, is
# made by the action's next step through the GitHub API, which cannot run
# against a scratch repository. Everything here can, and
# scripts/check-release-resume.sh runs it there.
#
# Every step is safe to repeat. The release tag is created only where
# release-state.sh found none and pushed without --force, so an existing tag
# is never moved: a push of the same tag onto the same commit is up to date,
# and one onto another commit is refused. The major tag move is
# move-major-tag.sh, which repeats as a no-op.
#
# Environment (release-state.sh's outputs):
#   TAG, VERSION, SHA   The release.
#   CREATE_TAG          "true": tag SHA as TAG and push the tag.
#   MOVE_MAJOR_TAG      "true": move the major tag onto TAG.
#   REMOTE              Where to push. Default origin.
set -euo pipefail

: "${TAG:?TAG names the release tag}"
: "${VERSION:?VERSION names the release version}"
: "${SHA:?SHA names the release commit}"
remote="${REMOTE:-origin}"
here="$(cd "$(dirname "$0")" && pwd)"

if [ "${CREATE_TAG:-false}" = "true" ]; then
  existing="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null || true)"
  if [ -z "${existing}" ]; then
    git tag "${TAG}" "${SHA}"
  elif [ "${existing}" != "${SHA}" ]; then
    echo "::error::${TAG} is already on ${existing}, not ${SHA}." >&2
    exit 1
  fi
  git push "${remote}" "refs/tags/${TAG}"
  echo "tagged ${SHA} as ${TAG}"
fi

if [ "${MOVE_MAJOR_TAG:-false}" = "true" ]; then
  bash "${here}/move-major-tag.sh" "${VERSION}"
fi
